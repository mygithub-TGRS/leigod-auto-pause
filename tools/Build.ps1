[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 构建控制台 EXE。
#
# 为什么仍然用系统自带的 csc.exe，而不是 dotnet SDK / MSBuild：
#   1. 目标框架是 .NET Framework 4.8，Windows 10/11 自带，用户不需要另装运行时；
#      用 net8.0-windows 会强制用户安装 .NET 桌面运行时，这与“解压即用”的目标冲突。
#   2. 这台机器与 CI 都只需要系统组件，没有 NuGet 还原、没有 SDK 版本漂移。
# 代价是编译器只支持 C# 5：不要使用 ?. 、$""、nameof、表达式体成员等语法。
#
# XAML 不参与编译（运行时用 XamlReader 从 app\ui\MainWindow.xaml 加载），
# 所以没有 BAML 生成步骤，界面样式改完不需要重新构建 EXE。

$projectRoot = Split-Path -Parent $PSScriptRoot
$sourceDirectory = Join-Path $projectRoot "src"
$manifestPath = Join-Path $sourceDirectory "app.manifest"
$assemblyInfoPath = Join-Path $sourceDirectory "AssemblyInfo.cs"
$iconPath = Join-Path $projectRoot "app\ui\app.ico"
$outputPath = Join-Path $projectRoot "LeigodAutoPause.exe"

$requiredRuntimePaths = @(
    (Join-Path $projectRoot "app\ConfigBootstrap.ps1"),
    (Join-Path $projectRoot "app\SecurityHelpers.ps1"),
    (Join-Path $projectRoot "app\LeigodAutoPause.ps1"),
    (Join-Path $projectRoot "app\Start-Monitor.ps1"),
    (Join-Path $projectRoot "app\Stop-Monitor.ps1"),
    (Join-Path $projectRoot "app\Restart-Monitor.ps1"),
    (Join-Path $projectRoot "app\Set-AutoStart.ps1"),
    (Join-Path $projectRoot "app\config.example.json"),
    (Join-Path $projectRoot "app\ui\MainWindow.xaml"),
    (Join-Path $projectRoot "app\ui\app.ico")
)

$compilerCandidates = @(
    "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($compiler)) {
    throw "找不到 .NET Framework C# 编译器 csc.exe。"
}

$frameworkDirectory = Split-Path -Parent $compiler
# WPF 的程序集不在 framework 根目录里，而在同级的 WPF 子目录（PresentationBuildTasks 也要靠它）。
$wpfDirectory = Join-Path $frameworkDirectory "WPF"

$referencePaths = @(
    (Join-Path $wpfDirectory "PresentationFramework.dll"),
    (Join-Path $wpfDirectory "PresentationCore.dll"),
    (Join-Path $wpfDirectory "WindowsBase.dll"),
    (Join-Path $frameworkDirectory "System.Xaml.dll"),
    (Join-Path $frameworkDirectory "System.dll"),
    (Join-Path $frameworkDirectory "System.Core.dll"),
    (Join-Path $frameworkDirectory "System.Xml.dll"),
    (Join-Path $frameworkDirectory "Microsoft.CSharp.dll")
)

# 版本号只有一个来源：src\AssemblyInfo.cs。发布包名、EXE 文件版本、CI 产物名都从它派生。
$assemblyInfoText = Get-Content -LiteralPath $assemblyInfoPath -Raw -Encoding UTF8
$versionMatch = [regex]::Match($assemblyInfoText, 'AssemblyVersion\("([0-9]+(?:\.[0-9]+){3})"\)')
if (-not $versionMatch.Success) {
    throw "无法从 src\AssemblyInfo.cs 解析 AssemblyVersion。"
}
$productVersion = $versionMatch.Groups[1].Value

foreach ($requiredPath in (@($manifestPath, $assemblyInfoPath, $iconPath) + $requiredRuntimePaths + $referencePaths)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "缺少构建文件: $requiredPath"
    }
}

$sourceFiles = @(Get-ChildItem -LiteralPath $sourceDirectory -Filter "*.cs" -File | Sort-Object Name)
if ($sourceFiles.Count -lt 2) {
    throw "src 目录下的 C# 源文件数量异常: $($sourceFiles.Count)"
}

$compilerArguments = @(
    "/nologo",
    "/target:winexe",
    "/platform:anycpu",
    "/optimize+",
    "/warn:4",
    "/warnaserror+",
    "/codepage:65001",
    "/utf8output",
    "/win32manifest:$manifestPath",
    "/win32icon:$iconPath",
    "/out:$outputPath"
) + @($referencePaths | ForEach-Object { "/reference:$_" }) + @($sourceFiles | ForEach-Object { $_.FullName })

# 正在运行的控制台会锁住目标 EXE，csc 只会报一条 CS0016；这里提前给出能行动的提示。
if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
    try {
        $probe = [System.IO.File]::Open($outputPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $probe.Dispose()
    }
    catch {
        throw "无法覆盖 $outputPath：请先关闭正在运行的控制台（任务管理器里的 LeigodAutoPause.exe），再重新构建。"
    }
}
Write-Output ("COMPILE {0} source files" -f $sourceFiles.Count)
& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0) {
    throw "控制台编译失败，csc.exe 退出码: $LASTEXITCODE"
}

$output = Get-Item -LiteralPath $outputPath
Write-Output "BUILD_OK"
Write-Output $output.FullName
Write-Output ("{0} bytes" -f $output.Length)
Write-Output ("product: {0}" -f $output.VersionInfo.ProductName)
Write-Output ("file version: {0}" -f $output.VersionInfo.FileVersion)
Write-Output ("version: {0}" -f $productVersion)
