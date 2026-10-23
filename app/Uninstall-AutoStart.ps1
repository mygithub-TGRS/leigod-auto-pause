[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$startupDirectory = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDirectory "Leigod Auto Pause.lnk"
$stopScript = Join-Path $PSScriptRoot "Stop-Monitor.ps1"

& $stopScript | Out-Null
if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
}

Write-Host "已确认监控停止并移除开机自启。桌面控制台入口和配置仍保留。"
