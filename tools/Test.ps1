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
Get-ChildItem -LiteralPath (Join-Path $projectRoot "app"), (Join-Path $projectRoot "tools") -Filter "*.ps1" -File | ForEach-Object {
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

Get-Content -LiteralPath $configExample -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
[xml](Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8) | Out-Null

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

& $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $buildScript | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $projectRoot "LeigodAutoPause.exe") -PathType Leaf)) {
    throw "启动器构建验证失败。"
}

Write-Output "RELEASE_TESTS_OK"
