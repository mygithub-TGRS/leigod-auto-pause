[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $projectRoot "src\Launcher.cs"
$manifestPath = Join-Path $projectRoot "src\app.manifest"
$iconPath = Join-Path $projectRoot "app\ui\app.ico"
$outputPath = Join-Path $projectRoot "LeigodAutoPause.exe"
$requiredRuntimePaths = @(
    (Join-Path $projectRoot "app\ConfigBootstrap.ps1"),
    (Join-Path $projectRoot "app\SecurityHelpers.ps1"),
    (Join-Path $projectRoot "app\LeigodAutoPause.UI.ps1"),
    (Join-Path $projectRoot "app\LeigodAutoPause.ps1"),
    (Join-Path $projectRoot "app\Start-Monitor.ps1"),
    (Join-Path $projectRoot "app\Stop-Monitor.ps1"),
    (Join-Path $projectRoot "app\Restart-Monitor.ps1"),
    (Join-Path $projectRoot "app\config.example.json"),
    (Join-Path $projectRoot "app\ui\MainWindow.xaml")
)

$compilerCandidates = @(
    "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

if ([string]::IsNullOrWhiteSpace($compiler)) {
    throw "找不到 .NET Framework C# 编译器 csc.exe。"
}

foreach ($requiredPath in @($sourcePath, $manifestPath, $iconPath) + $requiredRuntimePaths) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "缺少构建文件: $requiredPath"
    }
}

$compilerArguments = @(
    "/nologo",
    "/target:winexe",
    "/platform:anycpu",
    "/optimize+",
    "/warn:4",
    "/warnaserror+",
    "/reference:System.dll",
    "/reference:System.Windows.Forms.dll",
    "/win32manifest:$manifestPath",
    "/win32icon:$iconPath",
    "/out:$outputPath"
)

& $compiler @compilerArguments $sourcePath
if ($LASTEXITCODE -ne 0) {
    throw "启动器编译失败，csc.exe 退出码: $LASTEXITCODE"
}

$output = Get-Item -LiteralPath $outputPath
Write-Output "BUILD_OK"
Write-Output $output.FullName
Write-Output ("{0} bytes" -f $output.Length)
