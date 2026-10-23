[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 安装/刷新开机自启与桌面入口。
#
# 这个脚本在两种目录布局下都要能跑：
#   1. 源码仓库：根目录有 LeigodAutoPause.exe、src\、tools\
#   2. 发布包：只有 LeigodAutoPause.exe + app\（没有源码与构建脚本）
# 所以构建只在“EXE 缺失且有构建脚本”时才尝试。

$monitorScript = Join-Path $PSScriptRoot "LeigodAutoPause.ps1"
$autoStartScript = Join-Path $PSScriptRoot "Set-AutoStart.ps1"
$startScript = Join-Path $PSScriptRoot "Start-Monitor.ps1"
$stopScript = Join-Path $PSScriptRoot "Stop-Monitor.ps1"
$restartScript = Join-Path $PSScriptRoot "Restart-Monitor.ps1"
$configPath = Join-Path $PSScriptRoot "config.json"
$configExample = Join-Path $PSScriptRoot "config.example.json"
$configBootstrap = Join-Path $PSScriptRoot "ConfigBootstrap.ps1"
$securityHelpers = Join-Path $PSScriptRoot "SecurityHelpers.ps1"
$xamlPath = Join-Path $PSScriptRoot "ui\MainWindow.xaml"
$iconPath = Join-Path $PSScriptRoot "ui\app.ico"
$projectRoot = Split-Path -Parent $PSScriptRoot
$launcherPath = Join-Path $projectRoot "LeigodAutoPause.exe"
$startupDirectory = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDirectory "Leigod Auto Pause.lnk"
$desktopShortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "雷神自动暂停（非官方）.lnk"

if (-not (Test-Path -LiteralPath $configBootstrap -PathType Leaf)) {
    throw "找不到配置初始化脚本: $configBootstrap"
}
. $configBootstrap
if (-not (Test-Path -LiteralPath $securityHelpers -PathType Leaf)) {
    throw "找不到安全辅助脚本: $securityHelpers"
}
. $securityHelpers
$powerShellPath = Get-WindowsPowerShellPath

$requiredSourcePaths = @(
    $projectRoot, $PSScriptRoot, $monitorScript, $autoStartScript, $startScript,
    $stopScript, $restartScript, $configExample, $configBootstrap,
    $securityHelpers, $xamlPath, $iconPath
)
foreach ($requiredPath in $requiredSourcePaths) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "找不到必需文件: $requiredPath"
    }
}
Assert-PrivateAutoStartSource -Path $requiredSourcePaths

[void](Initialize-LeigodAutoPauseConfig -ConfigPath $configPath -AppDirectory $PSScriptRoot)
Assert-PrivateAutoStartSource -Path @($configPath)
Assert-PrivateAutoStartSource -Path @($startupDirectory)

& $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $monitorScript -ConfigPath $configPath -SelfTest
if ($LASTEXITCODE -ne 0) {
    throw "监控脚本自检未通过，未安装开机自启。"
}

& $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $monitorScript -ConfigPath $configPath -ValidateConfig | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "配置验证失败，未安装快捷方式。"
}

if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
    $buildScript = Join-Path $projectRoot "tools\Build.ps1"
    $sourceDirectory = Join-Path $projectRoot "src"
    if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf) -or
        -not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
        throw "找不到控制台 $launcherPath，且当前目录不含源码（src\）与构建脚本（tools\Build.ps1）。请使用完整发布包，或先在源码目录执行 tools\Build.ps1。"
    }
    & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $buildScript | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        throw "控制台构建失败。"
    }
}

Assert-PrivateAutoStartSource -Path @($launcherPath)

& $startScript -ConfigPath $configPath -SkipValidation | Out-Null

$shell = New-Object -ComObject WScript.Shell
try {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powerShellPath
    $shortcut.Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startScript`" -ConfigPath `"$configPath`""
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.Description = "雷神加速器游戏退出自动暂停监控（非官方）"
    $shortcut.Save()
    Assert-PrivateAutoStartSource -Path @($shortcutPath)

    $desktopShortcut = $shell.CreateShortcut($desktopShortcutPath)
    $desktopShortcut.TargetPath = $launcherPath
    $desktopShortcut.Arguments = ""
    $desktopShortcut.WorkingDirectory = $projectRoot
    $desktopShortcut.IconLocation = "$launcherPath,0"
    $desktopShortcut.Description = "打开雷神自动暂停控制台（非官方）"
    $desktopShortcut.Save()
}
catch {
    if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }
    throw
}
finally {
    if ($null -ne $shell) {
        [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }
}

Write-Host "已安装并启动雷神自动暂停（非官方）监控与控制台入口。"
Write-Host "开机自启快捷方式: $shortcutPath"
Write-Host "桌面控制台快捷方式: $desktopShortcutPath"
