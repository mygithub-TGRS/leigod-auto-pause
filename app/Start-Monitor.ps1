[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [switch]$ControlLockHeld,
    [switch]$SkipValidation
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
$stopMarker = Join-Path $PSScriptRoot ".stop"
$mutexName = "Local\LeigodAutoPauseMonitor"
$controlMutexName = "Local\LeigodAutoPauseControl"

if (-not (Test-Path -LiteralPath $monitorScript -PathType Leaf)) {
    throw "找不到监控脚本: $monitorScript"
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "找不到配置文件: $ConfigPath"
}

function Test-MonitorRunning {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(0, $false)
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        return (-not $acquired)
    }
    finally {
        if ($acquired) {
            try { $mutex.ReleaseMutex() } catch { }
        }
        $mutex.Dispose()
    }
}

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

    if (Test-MonitorRunning) {
        Write-Output "MONITOR_ALREADY_RUNNING"
        return
    }

    if (-not $SkipValidation) {
        & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $monitorScript -ConfigPath $ConfigPath -ValidateConfig | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "配置验证失败，未启动监控。"
        }
    }

    if (Test-Path -LiteralPath $stopMarker) {
        Remove-Item -LiteralPath $stopMarker -Force
    }

    $process = Start-Process -FilePath $powerShellPath -ArgumentList @(
        "-NoProfile",
        "-NonInteractive",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$monitorScript`"",
        "-ConfigPath", "`"$ConfigPath`""
    ) -WindowStyle Hidden -PassThru

    $started = $false
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        Start-Sleep -Milliseconds 100
        if (Test-MonitorRunning) {
            $started = $true
            break
        }
        if ($process.HasExited) {
            break
        }
    }

    if (-not $started) {
        throw "监控进程未能取得单实例锁，请查看 logs 目录。"
    }

    Write-Output "MONITOR_STARTED"
}
finally {
    if ($ownsControlMutex) {
        try { $controlMutex.ReleaseMutex() } catch { }
    }
    if ($null -ne $controlMutex) {
        $controlMutex.Dispose()
    }
}
