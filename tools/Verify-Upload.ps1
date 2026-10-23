[CmdletBinding()]
param(
    [switch]$IncludeHistory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 上传前自检：确认 Git 索引里只有应该公开的文件，且内容里没有凭据、本机路径等隐私。
# 它在仓库根目录运行，只读取 Git 元数据和文件内容，不会修改任何东西。

$projectRoot = Split-Path -Parent $PSScriptRoot
$problems = @()
$warnings = @()

Push-Location $projectRoot
try {
    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot ".git") -PathType Container)) {
        throw "当前目录不是 Git 仓库，无法校验上传集合: $projectRoot"
    }

    $tracked = @(git ls-files)
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-files 执行失败。"
    }
    if ($tracked.Count -eq 0) {
        throw "Git 索引为空，请先 git add 需要发布的文件。"
    }

    # 1) 绝不能进入仓库的路径
    $forbiddenRules = @(
        @{ Pattern = '^app/config\.json$';                        Reason = '本机配置，可能包含安装路径和游戏名' },
        @{ Pattern = '^app/config\.json\.';                       Reason = '本机配置临时文件' },
        @{ Pattern = '^app/logs/(?!\.gitkeep$)';                  Reason = '运行日志，含本机使用时间线' },
        @{ Pattern = '^app/\.stop$';                              Reason = '运行时停止标记' },
        @{ Pattern = '\.exe$';                                    Reason = '本地构建产物（未签名）' },
        @{ Pattern = '\.pdb$';                                    Reason = '调试符号' },
        @{ Pattern = '\.dmp$';                                    Reason = '内存转储' },
        @{ Pattern = '\.snapshot\.png$';                          Reason = '本地界面截图' },
        @{ Pattern = '\.(pfx|p12|pem|key|ppk|pk8|jks|keystore)$'; Reason = '证书或私钥' }
    )
    foreach ($path in $tracked) {
        foreach ($rule in $forbiddenRules) {
            if ($path -match $rule.Pattern) {
                $problems += "禁止入库: $path（$($rule.Reason)）"
            }
        }
    }

    # 2) 内容层敏感信息
    $secretRules = @(
        @{ Regex = 'account_token=(?!TEST_ACCOUNT_TOKEN)[A-Za-z0-9]{12,}';                  Label = '疑似真实 account_token' },
        @{ Regex = 'AKIA[0-9A-Z]{16}';                                                      Label = '疑似 AWS Access Key' },
        @{ Regex = 'gh[pousr]_[A-Za-z0-9]{20,}';                                            Label = '疑似 GitHub Token' },
        @{ Regex = '-----BEGIN [A-Z ]*PRIVATE KEY-----';                                    Label = '私钥内容' },
        @{ Regex = '(?i)\b(secret|password|passwd|api[_-]?key)\b\s*[:=]\s*["''][^"'']{8,}';  Label = '疑似硬编码凭据' }
    )
    # 本文件本身就包含上面这些模式的定义，扫描时必须跳过自己。
    $scanSkip = @('tools/Verify-Upload.ps1')
    $userProfile = [string]$env:USERPROFILE

    foreach ($path in $tracked) {
        if ($scanSkip -contains $path) { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $isBinary = $false
        for ($index = 0; $index -lt $bytes.Length; $index++) {
            if ($bytes[$index] -eq 0) { $isBinary = $true; break }
        }
        if ($isBinary) { continue }

        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        foreach ($rule in $secretRules) {
            if ($text -match $rule.Regex) {
                $problems += "内容命中$($rule.Label): $path"
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($userProfile) -and
            $text.IndexOf($userProfile, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $problems += "包含当前用户的绝对路径: $path"
        }
        if ($text -match '[A-Za-z]:\\Users\\[^\\]+') {
            $problems += "包含 C:\Users\<用户名> 形式的绝对路径: $path"
        }
    }

    # 3) 提交作者邮箱（只提示，不阻断：CI 里是机器人账号）
    $authors = @(git log --format='%ae' | Sort-Object -Unique)
    foreach ($author in $authors) {
        if (-not [string]::IsNullOrWhiteSpace($author) -and $author -notmatch '@users\.noreply\.github\.com$') {
            $warnings += "提交作者邮箱不是 GitHub noreply 地址: $author"
        }
    }

    # 4) 可选：检查整个历史中出现过的路径
    if ($IncludeHistory) {
        # git rev-list --objects 对提交对象只输出 SHA、没有路径字段，解析时必须先判断。
        $historyPaths = @(git rev-list --objects --all |
            ForEach-Object {
                $parts = [string]$_ -split ' ', 2
                if ($parts.Count -ge 2) { $parts[1] }
            } |
            Where-Object { $_ } |
            Sort-Object -Unique)
        foreach ($path in $historyPaths) {
            foreach ($rule in $forbiddenRules) {
                if ($path -match $rule.Pattern) {
                    $problems += "历史提交中出现过: $path（$($rule.Reason)）"
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

    foreach ($warning in $warnings) {
        Write-Host ("WARN  " + $warning)
    }
    if ($problems.Count -gt 0) {
        foreach ($problem in $problems) {
            Write-Host ("FAIL  " + $problem)
        }
        throw ("上传集合校验失败，共 {0} 项问题。" -f $problems.Count)
    }

    Write-Host "UPLOAD_READY"
}
finally {
    Pop-Location
}