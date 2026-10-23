[CmdletBinding()]
param(
    [ValidateSet("Status", "Enable", "Disable")]
    [string]$Action = "Status"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 控制台（C# 外壳）与这个脚本的分工：
#   读取状态：外壳自己读快捷方式，避免每 10 秒启动一次 PowerShell；
#   写入状态：一律走这里，因为只有这里带着 Assert-PrivateAutoStartSource 的 ACL 闸门。
# 两边的“已启用”判定必须保持同一条规则：目标指向 Windows PowerShell，
# 且参数里包含 Start-Monitor.ps1。

$configPath = Join-Path $PSScriptRoot "config.json"
$startScript = Join-Path $PSScriptRoot "Start-Monitor.ps1"
$monitorScript = Join-Path $PSScriptRoot "LeigodAutoPause.ps1"
$configBootstrap = Join-Path $PSScriptRoot "ConfigBootstrap.ps1"
$securityHelpers = Join-Path $PSScriptRoot "SecurityHelpers.ps1"
$configExample = Join-Path $PSScriptRoot "config.example.json"
$startupDirectory = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDirectory "Leigod Auto Pause.lnk"

. $configBootstrap
. $securityHelpers
$powerShellPath = Get-WindowsPowerShellPath

function Test-AutoStartEnabled {
    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        return $false
    }
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        return [string]::Equals($shortcut.TargetPath, $powerShellPath, [System.StringComparison]::OrdinalIgnoreCase) -and
            $shortcut.Arguments.IndexOf($startScript, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $shell) {
            [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

function Disable-AutoStart {
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }
    Write-Output "AUTOSTART_DISABLED"
}

function Enable-AutoStart {
    [void](Initialize-LeigodAutoPauseConfig -ConfigPath $configPath -AppDirectory $PSScriptRoot)

    Assert-PrivateAutoStartSource -Path @(
        $PSScriptRoot,
        $PSCommandPath,
        $startScript,
        $monitorScript,
        $configBootstrap,
        $securityHelpers,
        $configExample,
        $configPath,
        $startupDirectory
    )

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $powerShellPath
        $shortcut.Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startScript`" -ConfigPath `"$configPath`""
        $shortcut.WorkingDirectory = $PSScriptRoot
        $shortcut.Description = "雷神加速器游戏退出自动暂停监控（非官方）"
        $shortcut.Save()
        Assert-PrivateAutoStartSource -Path @($shortcutPath)
    }
    catch {
        if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
            Remove-Item -LiteralPath $shortcutPath -Force
        }
        throw
    }
    finally {
        [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }

    Write-Output "AUTOSTART_ENABLED"
}

switch ($Action) {
    "Status" {
        [ordered]@{
            enabled  = [bool](Test-AutoStartEnabled)
            shortcut = $shortcutPath
        } | ConvertTo-Json -Compress
    }
    "Disable" {
        Disable-AutoStart
    }
    "Enable" {
        Enable-AutoStart
    }
}