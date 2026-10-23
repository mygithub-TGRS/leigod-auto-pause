[CmdletBinding()]
param(
    [switch]$IncludeHistory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 上传前自检：确认 Git 索引里只有应该公开的文件，且这些文件的内容里没有凭据、本机路径等隐私。
# 内容一律从 **索引**（git grep --cached）读取，而不是工作区——否则“暂存后改工作区”会给出假通过。
# 脚本只读，不修改任何东西。

$projectRoot = Split-Path -Parent $PSScriptRoot
$problems = @()
$warnings = @()

Push-Location $projectRoot
try {
    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot ".git") -PathType Container)) {
        throw "当前目录不是 Git 仓库，无法校验上传集合: $projectRoot"
    }

    # 1) 索引里的路径。关闭 quotePath，避免中文/空格路径被转义成反斜杠转义形式导致规则失配。
    $rawList = [string]((git -c core.quotePath=false ls-files -z) | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-files 执行失败。"
    }
    $tracked = @($rawList -split "`0" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($tracked.Count -eq 0) {
        throw "Git 索引为空，请先 git add 需要发布的文件。"
    }

    $forbiddenRules = @(
        @{ Pattern = '^app/config\.json$';                        Reason = '本机配置，可能包含安装路径和游戏名' },
        @{ Pattern = '^app/config\.json\.';                       Reason = '本机配置临时文件' },
        @{ Pattern = '^app/config\.local\.json$';                 Reason = '本机配置覆盖文件' },
        @{ Pattern = '^app/logs/(?!\.gitkeep$)';                  Reason = '运行日志，含本机使用时间线' },
        @{ Pattern = '^app/\.stop$';                              Reason = '运行时停止标记' },
        @{ Pattern = '\.log$';                                    Reason = '日志文件' },
        @{ Pattern = '\.exe$';                                    Reason = '本地构建产物（未签名）' },
        @{ Pattern = '\.pdb$';                                    Reason = '调试符号' },
        @{ Pattern = '\.dmp$';                                    Reason = '内存转储' },
        @{ Pattern = '\.snapshot\.png$';                          Reason = '本地界面截图' },
        @{ Pattern = '^docs/_audit/';                             Reason = '本地审计测量产物' },
        @{ Pattern = '\.(pfx|p12|pem|key|ppk|pk8|jks|keystore)$'; Reason = '证书或私钥' },
        @{ Pattern = '\.(zip|7z|rar)$';                           Reason = '打包产物' }
    )
    foreach ($path in $tracked) {
        foreach ($rule in $forbiddenRules) {
            if ($path -match $rule.Pattern) {
                $problems += "禁止入库: $path（$($rule.Reason)）"
            }
        }
    }

    function Find-IndexMatches {
        <#
        .SYNOPSIS
            在 Git 索引里搜索内容。
        .DESCRIPTION
            模式通过文件传给 git grep（-f），而不是命令行参数：正则里常含引号，经
            PowerShell 到原生命令的参数拼接会被二次解释，导致模式被破坏。
        #>
        param(
            [Parameter(Mandatory = $true)][string]$Pattern,
            [switch]$FixedStrings,
            [switch]$IgnoreCase
        )

        $patternFile = Join-Path $env:TEMP ("vu-pattern-" + [guid]::NewGuid().ToString("N") + ".txt")
        try {
            [System.IO.File]::WriteAllText($patternFile, $Pattern, (New-Object System.Text.UTF8Encoding($false)))
            $grepArgs = @("grep", "--cached", "-I", "-n", "-E")
            if ($FixedStrings) {
                $grepArgs = @("grep", "--cached", "-I", "-n", "-F")
            }
            if ($IgnoreCase) {
                $grepArgs += "-i"
            }
            $grepArgs += @("-f", $patternFile)
            $output = @(& git @grepArgs 2>$null)
            if ($LASTEXITCODE -gt 1) {
                throw ("git grep 执行失败: {0}" -f $Pattern)
            }
            return $output
        }
        finally {
            Remove-Item -LiteralPath $patternFile -Force -ErrorAction SilentlyContinue
        }
    }

    # 2) 内容层敏感信息。
    #    git grep 用 POSIX ERE：不支持 (?!...) 断言、不保证支持 \s，所以统一用 [[:space:]]。
    #    占位符 TEST_ACCOUNT_TOKEN 的下划线不在 [A-Za-z0-9] 内，天然达不到 12 位阈值。
    $tokenWord = 'account' + '_token'
    $secretRules = @(
        @{ Regex = ($tokenWord + '["'']?[[:space:]]*[:=][[:space:]]*["'']?[A-Za-z0-9]{12,}'); Label = '疑似真实账号令牌' },
        @{ Regex = 'AKIA[0-9A-Z]{16}';                                                          Label = '疑似 AWS Access Key' },
        @{ Regex = 'gh[pousr]_[A-Za-z0-9]{20,}';                                                Label = '疑似 GitHub Token' },
        @{ Regex = '-----BEGIN [A-Z ]*PRIVATE KEY-----';                                        Label = '私钥内容' },
        @{ Regex = '[A-Za-z0-9_-]*(secret|password|passwd|api[_-]?key)[A-Za-z0-9_-]*["'']?[[:space:]]*[:=][[:space:]]*["''][^"'']{8,}'; Label = '疑似硬编码凭据'; IgnoreCase = $true }
    )
    foreach ($rule in $secretRules) {
        $ignoreCase = $rule.ContainsKey('IgnoreCase') -and [bool]$rule['IgnoreCase']
        foreach ($hit in @(Find-IndexMatches -Pattern $rule.Regex -IgnoreCase:$ignoreCase)) {
            if ([string]$hit -match 'TEST_ACCOUNT_TOKEN') {
                continue
            }
            $problems += ("内容命中{0}: {1}" -f $rule.Label, $hit)
        }
    }

    # 3) 本机绝对路径：同样只扫索引。
    $literalPaths = @([string]$env:USERPROFILE, [string]$projectRoot) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($literal in $literalPaths) {
        foreach ($hit in @(Find-IndexMatches -Pattern $literal -FixedStrings)) {
            $problems += ("包含本机绝对路径（{0}）: {1}" -f $literal, $hit)
        }
    }

    # 4) 提交作者邮箱（只提示，不阻断；CI 里是机器人账号）。空仓库上 git log 会把 fatal 写到
    #    stderr，在 Stop 策略下会变成终止错误，所以这里临时降级。
    $authors = @()
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $authors = @(& git log --format='%ae' 2>$null)
    }
    catch {
        $authors = @()
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($authors.Count -eq 0) {
        $warnings += "还没有任何提交（git log 为空），作者邮箱检查跳过。"
    }
    else {
        foreach ($author in ($authors | Sort-Object -Unique)) {
            if (-not [string]::IsNullOrWhiteSpace($author) -and $author -notmatch '@users\.noreply\.github\.com$') {
                $warnings += ("提交作者邮箱不是 GitHub noreply 地址: {0}" -f $author)
            }
        }
    }

    # 5) 可选：检查整个历史中出现过的路径。
    if ($IncludeHistory) {
        $historyRaw = ""
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $historyRaw = [string]((git -c core.quotePath=false rev-list --objects --all 2>$null) | Out-String)
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        foreach ($line in ($historyRaw -split "`n")) {
            $parts = [string]$line -split ' ', 2
            if ($parts.Count -lt 2) {
                continue
            }
            $historyPath = $parts[1].Trim()
            if (-not $historyPath) {
                continue
            }
            foreach ($rule in $forbiddenRules) {
                if ($historyPath -match $rule.Pattern) {
                    $problems += ("历史提交中出现过: {0}（{1}）" -f $historyPath, $rule.Reason)
                }
            }
        }
    }

    $totalBytes = 0
    foreach ($path in $tracked) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $totalBytes += (Get-Item -LiteralPath $path).Length
        }
    }
    Write-Host ("将上传 {0} 个文件，合计 {1:N1} KB" -f $tracked.Count, ($totalBytes / 1KB))

    foreach ($warning in ($warnings | Sort-Object -Unique)) {
        Write-Host ("WARN  " + $warning)
    }
    if ($problems.Count -gt 0) {
        $uniqueProblems = @($problems | Sort-Object -Unique)
        foreach ($problem in $uniqueProblems) {
            Write-Host ("FAIL  " + $problem)
        }
        throw ("上传集合校验失败，共 {0} 项问题。" -f $uniqueProblems.Count)
    }

    Write-Host "UPLOAD_READY"
}
finally {
    Pop-Location
}