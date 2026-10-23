[CmdletBinding()]
param(
    [ValidateRange(5, 120)][int]$TimeoutSeconds = 75,
    [switch]$ControlLockHeld
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$stopMarker = Join-Path $PSScriptRoot ".stop"
$mutexName = "Local\LeigodAutoPauseMonitor"
$controlMutexName = "Local\LeigodAutoPauseControl"

$controlMutex = $null
$ownsControlMutex = $false
try {
    if (-not $ControlLockHeld) {
        $controlMutex = New-Object System.Threading.Mutex($false, $controlMutexName)
        try {
            $ownsControlMutex = $controlMutex.WaitOne(90000, $false)
        }
        catch [System.Threading.AbandonedMutexException] {
            $ownsControlMutex = $true
        }
        if (-not $ownsControlMutex) {
            throw "等待其他启停操作完成超时。"
        }
    }

    Set-Content -LiteralPath $stopMarker -Value (Get-Date -Format "o") -Encoding ASCII

    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne($TimeoutSeconds * 1000, $false)
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }

        if (-not $acquired) {
            throw "等待后台监控停止超时。停止标记已保留，监控将在下一次安全检查时退出。"
        }
    }
    finally {
        if ($acquired) {
            try { $mutex.ReleaseMutex() } catch { }
        }
        $mutex.Dispose()
    }

    Write-Output "MONITOR_STOPPED"
}
finally {
    if ($ownsControlMutex) {
        try { $controlMutex.ReleaseMutex() } catch { }
    }
    if ($null -ne $controlMutex) {
        $controlMutex.Dispose()
    }
}
