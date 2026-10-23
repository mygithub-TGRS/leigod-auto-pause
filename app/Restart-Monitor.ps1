[CmdletBinding()]
param(
    [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot "config.json"
}

. (Join-Path $PSScriptRoot "ConfigBootstrap.ps1")
. (Join-Path $PSScriptRoot "SecurityHelpers.ps1")
$powerShellPath = Get-WindowsPowerShellPath
[void](Initialize-LeigodAutoPauseConfig -ConfigPath $ConfigPath -AppDirectory $PSScriptRoot)

$monitorScript = Join-Path $PSScriptRoot "LeigodAutoPause.ps1"
$controlMutex = New-Object System.Threading.Mutex($false, "Local\LeigodAutoPauseControl")
$ownsControlMutex = $false
try {
    try {
        $ownsControlMutex = $controlMutex.WaitOne(90000, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $ownsControlMutex = $true
    }
    if (-not $ownsControlMutex) {
        throw "等待其他启停操作完成超时。"
    }

    & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $monitorScript -ConfigPath $ConfigPath -ValidateConfig | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "配置验证失败，保留当前监控实例。"
    }

    & (Join-Path $PSScriptRoot "Stop-Monitor.ps1") -ControlLockHeld
    & (Join-Path $PSScriptRoot "Start-Monitor.ps1") -ConfigPath $ConfigPath -ControlLockHeld -SkipValidation
}
finally {
    if ($ownsControlMutex) {
        try { $controlMutex.ReleaseMutex() } catch { }
    }
    $controlMutex.Dispose()
}

Write-Output "MONITOR_RESTARTED"
