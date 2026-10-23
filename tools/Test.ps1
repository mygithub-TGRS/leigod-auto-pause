[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$monitorScript = Join-Path $projectRoot "app\LeigodAutoPause.ps1"
$configExample = Join-Path $projectRoot "app\config.example.json"
$xamlPath = Join-Path $projectRoot "app\ui\MainWindow.xaml"
$buildScript = Join-Path $PSScriptRoot "Build.ps1"
$securityHelpers = Join-Path $projectRoot "app\SecurityHelpers.ps1"
$powerShellPath = Join-Path $PSHOME "powershell.exe"

if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
    throw "本测试必须由 Windows PowerShell 5.1 运行。"
}

$restCommand = Get-Command -Name Invoke-RestMethod -CommandType Cmdlet
foreach ($requiredParameter in @("UseBasicParsing", "MaximumRedirection")) {
    if (-not $restCommand.Parameters.ContainsKey($requiredParameter)) {
        throw "当前 Windows PowerShell 的 Invoke-RestMethod 不支持必需参数: $requiredParameter"
    }
}
. $securityHelpers

$parseErrors = @()
Get-ChildItem -LiteralPath $projectRoot -Recurse -Filter "*.ps1" -File | Where-Object { $_.FullName -notmatch '\\\.git\\' } | ForEach-Object {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $parseErrors += $errors
    }
}
if ($parseErrors.Count -gt 0) {
    throw ("PowerShell 语法验证失败: " + (($parseErrors | ForEach-Object { $_.Message }) -join "; "))
}

# Windows PowerShell 5.1 依赖 UTF-8 BOM 才能正确读取脚本里的中文；缺 BOM 会让提示文案变成乱码，
# 严重时还会连字符串引号一起吃掉导致语法错误。这里把它变成硬性检查，防止编辑器保存时丢 BOM。
$missingBom = @()
Get-ChildItem -LiteralPath $projectRoot -Recurse -Filter "*.ps1" -File | Where-Object { $_.FullName -notmatch '\\\.git\\' } | ForEach-Object {
    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
        $missingBom += $_.Name
    }
}
if ($missingBom.Count -gt 0) {
    throw ("以下 PowerShell 脚本缺少 UTF-8 BOM: " + ($missingBom -join ", "))
}

Get-Content -LiteralPath $configExample -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
[xml](Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8) | Out-Null

# XAML ↔ 脚本契约：界面里的 x:Name 和资源 key 是 PowerShell 的硬依赖（FindName / FindResource），
# 只做 XML 解析检查发现不了改名或删除，必须在提交前静态比对两边。
$xamlDocument = [xml](Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8)
$xmlNamespace = New-Object System.Xml.XmlNamespaceManager($xamlDocument.NameTable)
$xmlNamespace.AddNamespace('p', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
$xmlNamespace.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
$xamlNames = @($xamlDocument.SelectNodes('//*[@x:Name]', $xmlNamespace) |
    ForEach-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') })
$xamlKeys = @($xamlDocument.SelectNodes('//*[@x:Key]', $xmlNamespace) |
    ForEach-Object { $_.GetAttribute('Key', 'http://schemas.microsoft.com/winfx/2006/xaml') })

$uiScriptPath = Join-Path $projectRoot 'app\LeigodAutoPause.UI.ps1'
$uiSource = Get-Content -LiteralPath $uiScriptPath -Raw -Encoding UTF8
$controlBlockMatch = [regex]::Match($uiSource, '\$controlNames = @\(([\s\S]*?)\n\s*\)')
if (-not $controlBlockMatch.Success) {
    throw "无法从 LeigodAutoPause.UI.ps1 解析出 `$controlNames 清单。"
}
$requiredControlNames = @([regex]::Matches($controlBlockMatch.Groups[1].Value, '"([^"]+)"') |
    ForEach-Object { $_.Groups[1].Value })
if ($requiredControlNames.Count -lt 10) {
    throw ("控件清单解析结果异常: {0} 项" -f $requiredControlNames.Count)
}
$missingControlNames = @($requiredControlNames | Where-Object { $xamlNames -notcontains $_ })
if ($missingControlNames.Count -gt 0) {
    throw ("XAML 缺少脚本依赖的控件: " + ($missingControlNames -join ", "))
}
foreach ($requiredKey in @(
        'GreenBrush', 'AmberBrush', 'RedBrush', 'MutedBrush', 'WeakBrush',
        'TextBrush', 'SurfaceStrongBrush', 'PrimaryButtonStyle', 'DangerButtonStyle')) {
    if ($xamlKeys -notcontains $requiredKey) {
        throw ("XAML 缺少脚本依赖的资源: " + $requiredKey)
    }
}

& $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $monitorScript -SelfTest
if ($LASTEXITCODE -ne 0) {
    throw "监控器自检失败。"
}

$testRoot = Join-Path $env:TEMP ("LeigodAutoPauseTest-" + [guid]::NewGuid().ToString("N"))
$resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
$resolvedTempRoot = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd("\") + "\"
try {
    $isolatedAppRoot = Join-Path $resolvedTestRoot "app"
    [void](New-Item -ItemType Directory -Path $isolatedAppRoot -Force)
    Copy-Item -LiteralPath $monitorScript -Destination $isolatedAppRoot
    Copy-Item -LiteralPath $securityHelpers -Destination $isolatedAppRoot
    $isolatedMonitorScript = Join-Path $isolatedAppRoot "LeigodAutoPause.ps1"

    $clientRoot = Join-Path $resolvedTestRoot "client"
    [void](New-Item -ItemType Directory -Path $clientRoot -Force)
    $fakeClientPath = Join-Path $clientRoot "leigod.exe"
    [void](New-Item -ItemType File -Path $fakeClientPath -Force)
    if (-not (Test-LocalFileSystemPath -Path $fakeClientPath) -or
        -not (Resolve-SafeLeigodExecutablePath -Path $fakeClientPath) -or
        (Resolve-SafeLeigodExecutablePath -Path (Join-Path $clientRoot "not-leigod.exe")) -or
        (Test-LocalFileSystemPath -Path "\\server\share\leigod.exe")) {
        throw "客户端路径安全验证失败。"
    }

    $junctionPath = Join-Path $resolvedTestRoot "client-link"
    [void](New-Item -ItemType Junction -Path $junctionPath -Target $clientRoot)
    if (Test-LocalFileSystemPath -Path (Join-Path $junctionPath "leigod.exe")) {
        throw "客户端路径安全验证未拒绝重解析目录。"
    }

    $aclProbePath = Join-Path $resolvedTestRoot "acl-probe.ps1"
    [void](New-Item -ItemType File -Path $aclProbePath -Force)
    $aclProbe = Get-Acl -LiteralPath $aclProbePath
    $everyone = New-Object System.Security.Principal.SecurityIdentifier -ArgumentList "S-1-1-0"
    $unsafeRule = New-Object System.Security.AccessControl.FileSystemAccessRule -ArgumentList @(
        $everyone,
        [System.Security.AccessControl.FileSystemRights]::Write,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    [void]$aclProbe.AddAccessRule($unsafeRule)
    Set-Acl -LiteralPath $aclProbePath -AclObject $aclProbe
    $unsafeAclRejected = $false
    try {
        Assert-PrivateAutoStartSource -Path @($aclProbePath)
    }
    catch {
        $unsafeAclRejected = $true
    }
    if (-not $unsafeAclRejected) {
        throw "开机自启 ACL 验证未拒绝可被其他用户修改的文件。"
    }
    $configPath = Join-Path $resolvedTestRoot "config.json"
    $config = [ordered]@{
        auto_detect_launched_games     = $true
        game_processes                = @("ExampleGame.exe")
        poll_seconds                  = 2
        status_poll_seconds           = 20
        startup_grace_seconds         = 300
        exit_grace_seconds            = 120
        pause_if_client_closes        = $true
        pause_if_game_never_starts    = $false
        pause_stale_session_on_start  = $false
        notifications                 = $false
        leigod_executable             = $fakeClientPath
        leigod_shortcut               = ""
    }
    $config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8

    & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $isolatedMonitorScript -ConfigPath $configPath -ValidateConfig | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "配置验证失败。"
    }

    $rawCheck = & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $isolatedMonitorScript -ConfigPath $configPath -CheckJson
    if ($LASTEXITCODE -ne 0) {
        throw "脱敏诊断验证失败。"
    }
    $check = $rawCheck | ConvertFrom-Json
    if ($check.ConfigPath -ne "config.json" -or
        $check.LeigodExecutable -ne "leigod.exe" -or
        $check.TokenFound -or
        -not $check.AutoDetectionEnabled -or
        $check.ConfiguredGameCount -ne 1 -or
        $check.DetectedGameCount -ne 0 -or
        $check.TargetGameCount -ne 1 -or
        $null -ne $check.ConfiguredProcesses) {
        throw "默认诊断输出包含敏感明细或状态不正确。"
    }

    $autoOnlyConfigPath = Join-Path $resolvedTestRoot "config-auto-only.json"
    $config.auto_detect_launched_games = $true
    $config.game_processes = @()
    $config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $autoOnlyConfigPath -Encoding UTF8
    & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $isolatedMonitorScript -ConfigPath $autoOnlyConfigPath -ValidateConfig | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "自动识别模式未接受空的手动补充列表。"
    }

    $manualOnlyConfigPath = Join-Path $resolvedTestRoot "config-invalid-manual-only.json"
    $config.auto_detect_launched_games = $false
    $config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manualOnlyConfigPath -Encoding UTF8
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "SilentlyContinue"
        & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $isolatedMonitorScript -ConfigPath $manualOnlyConfigPath -ValidateConfig 2>$null | Out-Null
        $invalidConfigExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($invalidConfigExitCode -eq 0) {
        throw "关闭自动识别时错误接受了空的手动补充列表。"
    }
}
finally {
    if ($resolvedTestRoot.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

# 纯函数回归测试：监控脚本支持 dot-source 只加载函数（不启动监控）。
$regressionRoot = Join-Path $env:TEMP ("LeigodRegression-" + [guid]::NewGuid().ToString("N"))
[void](New-Item -ItemType Directory -Path $regressionRoot -Force)
try {
    & {
        . $monitorScript

        if ($null -eq (Get-Command -Name Get-GameActivity -ErrorAction SilentlyContinue)) {
            throw "监控脚本未定义 Get-GameActivity，dot-source 守卫可能失效。"
        }

        # 1) 空进程名必须被跳过：传给 Get-Process 会抛参数绑定异常并终止整个监控。
        $emptyResult = @(Get-RunningConfiguredGames -ProcessNames ([string[]]@("", "   ")))
        if ($emptyResult.Count -ne 0) {
            throw "空进程名未被安全跳过。"
        }

        # 2) 合并工具必须去空、去重、去首尾空格。
        $merged = @(Merge-ProcessNameList -NameList @("GameA", "", $null, "GameA", " GameB "))
        if ($merged.Count -ne 2 -or $merged -notcontains "GameA" -or $merged -notcontains "GameB") {
            throw ("进程名合并结果不正确: [{0}]" -f ($merged -join "|"))
        }

        # 3) 目标进程列表不允许出现空字符串（曾经泄漏进 runtime-state.json）。
        $tracker = [pscustomobject]@{
            StartedAt         = Get-Date
            LogDirectory      = $regressionRoot
            FileOffsets       = @{}
            FileCreationTicks = @{}
            SeenEvents        = @{}
            Sessions          = @{}
        }
        $tracker.Sessions["42"] = [pscustomobject]@{
            GameId         = [long]42
            ProcessNames   = [string[]]@()
            LastEventAt    = Get-Date
            PendingUntil   = (Get-Date).AddSeconds(60)
            StopObservedAt = $null
            Unresolved     = $true
        }
        $regressionConfig = [pscustomobject]@{
            GameProcesses           = [string[]]@("GameA")
            AutoDetectLaunchedGames = $false
        }
        $activity = Get-GameActivity -Config $regressionConfig -LogDirectory $regressionRoot -Tracker $tracker
        foreach ($targetName in @($activity.TargetProcesses)) {
            if ([string]::IsNullOrWhiteSpace([string]$targetName)) {
                throw "目标进程列表仍包含空字符串。"
            }
        }
        if (@($activity.TargetProcesses).Count -ne 1) {
            throw ("目标进程数量不正确: {0}" -f @($activity.TargetProcesses).Count)
        }

        # 4) 日志保留策略只删过期文件。
        $script:LogDirectory = $regressionRoot
        $oldLog = Join-Path $regressionRoot "monitor-2020-01-01.log"
        $newLog = Join-Path $regressionRoot "monitor-2999-01-01.log"
        Set-Content -LiteralPath $oldLog -Value "old" -Encoding UTF8
        Set-Content -LiteralPath $newLog -Value "new" -Encoding UTF8
        (Get-Item -LiteralPath $oldLog).LastWriteTime = (Get-Date).AddDays(-60)
        Remove-ExpiredMonitorLogs -RetentionDays 30
        if (Test-Path -LiteralPath $oldLog) {
            throw "过期日志未被清理。"
        }
        if (-not (Test-Path -LiteralPath $newLog)) {
            throw "未过期日志被错误删除。"
        }

        # 5) 越界的 log_retention_days 必须被配置校验拒绝。
        $badConfigPath = Join-Path $regressionRoot "bad-retention.json"
        [ordered]@{
            auto_detect_launched_games    = $true
            game_processes                = @()
            poll_seconds                  = 2
            status_poll_seconds           = 20
            startup_grace_seconds         = 300
            exit_grace_seconds            = 120
            pause_if_client_closes        = $true
            pause_if_game_never_starts    = $false
            pause_stale_session_on_start  = $false
            notifications                 = $false
            log_retention_days            = 99999
            leigod_executable             = ""
            leigod_shortcut               = ""
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $badConfigPath -Encoding UTF8
        $rejected = $false
        try {
            [void](Read-MonitorConfig -Path $badConfigPath)
        }
        catch {
            $rejected = $true
        }
        if (-not $rejected) {
            throw "越界的 log_retention_days 未被拒绝。"
        }
    }
    Write-Output "REGRESSION_TESTS_OK"
}
finally {
    if (Test-Path -LiteralPath $regressionRoot) {
        Remove-Item -LiteralPath $regressionRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

& $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $buildScript | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $projectRoot "LeigodAutoPause.exe") -PathType Leaf)) {
    throw "启动器构建验证失败。"
}

Write-Output "RELEASE_TESTS_OK"
