[CmdletBinding()]
param(
    [string]$OutputDirectory = "",
    # 传入证书指纹时，打包前会给 EXE 签名（自签名或 CA 证书都可以）。
    [string]$CertificateThumbprint = "",
    [switch]$SkipTests,
    # 保留暂存目录，便于检查打进包里的到底是哪些文件。
    [switch]$KeepStaging
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 生成可发布的二进制包：dist\LeigodAutoPause-<版本>-win-x64.zip
#
# 包里只有“能直接跑”的运行时文件，不包含本机配置、日志、截图，也不包含 C# 源码：
#   LeigodAutoPause.exe + app\（业务脚本与界面资源）+ 许可与说明文档
# 源码始终以仓库为唯一来源，避免"Release 里的代码和 tag 对不上"。

$projectRoot = Split-Path -Parent $PSScriptRoot
$powerShellPath = Join-Path $PSHOME "powershell.exe"
$assemblyInfoPath = Join-Path $projectRoot "src\AssemblyInfo.cs"
$buildScript = Join-Path $PSScriptRoot "Build.ps1"
$testScript = Join-Path $PSScriptRoot "Test.ps1"
$signScript = Join-Path $PSScriptRoot "Sign.ps1"
$executablePath = Join-Path $projectRoot "LeigodAutoPause.exe"

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $distDirectory = Join-Path $projectRoot "dist"
}
else {
    $distDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
}

$versionMatch = [regex]::Match(
    (Get-Content -LiteralPath $assemblyInfoPath -Raw -Encoding UTF8),
    'AssemblyVersion\("([0-9]+(?:\.[0-9]+){3})"\)'
)
if (-not $versionMatch.Success) {
    throw "无法从 src\AssemblyInfo.cs 解析 AssemblyVersion。"
}
$version = $versionMatch.Groups[1].Value
$shortVersion = ($version -split '\.')[0..2] -join '.'
$packageName = "LeigodAutoPause-$version-win-x64"
$zipPath = Join-Path $distDirectory ($packageName + ".zip")

Write-Output ("PACKAGE {0} ({1})" -f $packageName, $version)

# ---------------------------------------------------------------- 构建与测试

if ($SkipTests) {
    & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $buildScript | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "构建失败，未生成发布包。"
    }
}
else {
    # Test.ps1 内部会重新构建一次，并在本机具备条件时跑界面快照冒烟测试。
    & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $testScript
    if ($LASTEXITCODE -ne 0) {
        throw "发布测试未通过，未生成发布包。"
    }
}

if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw "构建产物不存在: $executablePath"
}
if ((Get-Item -LiteralPath $executablePath).VersionInfo.FileVersion -ne $version) {
    throw ("构建产物的文件版本 {0} 与 AssemblyInfo 的 {1} 不一致。" -f (Get-Item -LiteralPath $executablePath).VersionInfo.FileVersion, $version)
}

# ---------------------------------------------------------------- 暂存

if (-not (Test-Path -LiteralPath $distDirectory)) {
    [void](New-Item -ItemType Directory -Path $distDirectory -Force)
}
$stagingRoot = Join-Path $distDirectory ".staging"
$stagingPackage = Join-Path $stagingRoot $packageName
if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}
[void](New-Item -ItemType Directory -Path $stagingPackage -Force)

Copy-Item -LiteralPath $executablePath -Destination $stagingPackage

$stagingApp = Join-Path $stagingPackage "app"
[void](New-Item -ItemType Directory -Path $stagingApp -Force)
Get-ChildItem -LiteralPath (Join-Path $projectRoot "app") -Filter "*.ps1" -File |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $stagingApp }
Copy-Item -LiteralPath (Join-Path $projectRoot "app\config.example.json") -Destination $stagingApp

$stagingUi = Join-Path $stagingApp "ui"
[void](New-Item -ItemType Directory -Path $stagingUi -Force)
Copy-Item -LiteralPath (Join-Path $projectRoot "app\ui\MainWindow.xaml") -Destination $stagingUi
Copy-Item -LiteralPath (Join-Path $projectRoot "app\ui\app.ico") -Destination $stagingUi

$stagingLogs = Join-Path $stagingApp "logs"
[void](New-Item -ItemType Directory -Path $stagingLogs -Force)
Set-Content -LiteralPath (Join-Path $stagingLogs ".gitkeep") -Value "" -Encoding ASCII

foreach ($document in @('README.md', 'CHANGELOG.md', 'LICENSE', 'NOTICE.md', 'LEGAL.md', 'PRIVACY.md', 'SECURITY.md')) {
    $source = Join-Path $projectRoot $document
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        Copy-Item -LiteralPath $source -Destination $stagingPackage
    }
}

# 发布包必须干净：本机配置、运行日志、停止标记、截图一律不能进去。
$forbidden = @(
    @{ Pattern = 'config\.json$'; Reason = '本机配置' },
    @{ Pattern = '\.log$'; Reason = '运行日志' },
    @{ Pattern = '\.stop$'; Reason = '运行时停止标记' },
    @{ Pattern = '\.snapshot\.png$'; Reason = '本机截图' },
    @{ Pattern = '\.pdb$'; Reason = '调试符号' },
    @{ Pattern = '\.tmp$'; Reason = '临时文件' }
)
$stagedFiles = @(Get-ChildItem -LiteralPath $stagingPackage -Recurse -File)
foreach ($file in $stagedFiles) {
    $relative = $file.FullName.Substring($stagingPackage.Length + 1)
    foreach ($rule in $forbidden) {
        if ($relative -match $rule.Pattern) {
            throw ("发布包里混入了不该出现的文件: {0}（{1}）" -f $relative, $rule.Reason)
        }
    }
}
if (-not ($stagedFiles | Where-Object { $_.Name -eq 'LeigodAutoPause.exe' })) {
    throw "发布包里缺少 LeigodAutoPause.exe。"
}
if (-not ($stagedFiles | Where-Object { $_.Name -eq 'app.ico' })) {
    throw "发布包里缺少界面图标 app\ui\app.ico。"
}

Write-Output ("STAGED {0} files" -f $stagedFiles.Count)

# ---------------------------------------------------------------- 签名

$signed = $false
if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $signScript `
        -Path (Join-Path $stagingPackage "LeigodAutoPause.exe") `
        -CertificateThumbprint $CertificateThumbprint
    if ($LASTEXITCODE -ne 0) {
        throw "发布包签名失败。"
    }
    $signed = $true
}

# ---------------------------------------------------------------- 压缩

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -Path $stagingPackage -DestinationPath $zipPath -CompressionLevel Optimal

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
$hashFile = $zipPath + ".sha256"
Set-Content -LiteralPath $hashFile -Value ($hash + "  " + (Split-Path -Leaf $zipPath)) -Encoding ASCII
$zipItem = Get-Item -LiteralPath $zipPath

# ---------------------------------------------------------------- 报告

Write-Output ""
Write-Output "PACKAGE_OK"
Write-Output ("version : {0}" -f $shortVersion)
Write-Output ("zip     : {0}" -f $zipItem.FullName)
Write-Output ("size    : {0:N0} bytes" -f $zipItem.Length)
Write-Output ("sha256  : {0}" -f $hash)
Write-Output ("signed  : {0}" -f $(if ($signed) { "yes" } else { "no" }))
Write-Output "contents:"
Get-ChildItem -LiteralPath $stagingPackage -Recurse -File |
    Sort-Object FullName |
    ForEach-Object {
        $relative = $_.FullName.Substring($stagingPackage.Length + 1)
        Write-Output ("  {0,-46} {1,8:N0}" -f $relative, $_.Length)
    }

if (-not $KeepStaging) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}
