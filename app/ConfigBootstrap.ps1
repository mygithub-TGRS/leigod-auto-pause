function Initialize-LeigodAutoPauseConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$AppDirectory
    )

    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        return $false
    }
    if (Test-Path -LiteralPath $ConfigPath) {
        throw "配置路径不是文件: $ConfigPath"
    }

    $requestedPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $defaultPath = [System.IO.Path]::GetFullPath((Join-Path $AppDirectory "config.json"))
    if (-not [string]::Equals($requestedPath, $defaultPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "找不到配置文件: $ConfigPath"
    }

    $examplePath = Join-Path $AppDirectory "config.example.json"
    if (-not (Test-Path -LiteralPath $examplePath -PathType Leaf)) {
        throw "找不到示例配置文件: $examplePath"
    }

    try {
        [System.IO.File]::Copy($examplePath, $defaultPath, $false)
    }
    catch [System.IO.IOException] {
        if (-not (Test-Path -LiteralPath $defaultPath -PathType Leaf)) {
            throw
        }
    }
    return $true
}
