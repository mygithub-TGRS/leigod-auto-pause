[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Path,
    # 不传时自动在 CurrentUser\My 里找一张代码签名证书（优先 Leigod Auto Pause 的自签名证书）。
    [string]$CertificateThumbprint = "",
    # CA 证书签名时建议保留时间戳，否则证书过期后旧签名会失效。
    [string]$TimestampUrl = "http://timestamp.digicert.com",
    [switch]$NoTimestamp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 给 EXE/DLL/PS1 做 Authenticode 签名并验证结果。
#
# 关于“要不要签名”：
#   - 本机自用：自签名证书 + 装进“受信任的根证书”与“受信任的发布者”即可消除
#     “无法验证发布者”的提示；证书只对这台机器有效。
#   - 对外分发：必须使用公共 CA 签发的代码签名证书，自签名在别人的机器上依旧显示未知发布者。
#
# 本脚本只做签名与验证，不创建证书、不改信任存储——那两步属于机器级改动，应当显式执行。

function Get-CertificateEkuOids {
    param([Parameter(Mandatory = $true)]$Certificate)

    $oids = @()
    foreach ($extension in $Certificate.Extensions) {
        if ($extension -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]) {
            foreach ($eku in $extension.EnhancedKeyUsages) {
                $oids += $eku.Value
            }
        }
    }
    return $oids
}

function Resolve-CodeSigningCertificate {
    param([string]$Thumbprint)

    if (-not [string]::IsNullOrWhiteSpace($Thumbprint)) {
        foreach ($store in @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')) {
            $candidate = Get-ChildItem -Path $store -ErrorAction SilentlyContinue |
                Where-Object { $_.Thumbprint -eq $Thumbprint } |
                Select-Object -First 1
            if ($null -ne $candidate) {
                if (-not $candidate.HasPrivateKey) {
                    throw "证书 $Thumbprint 没有私钥，无法签名。"
                }
                return $candidate
            }
        }
        throw "找不到指纹为 $Thumbprint 的证书（已查找 CurrentUser\My 与 LocalMachine\My）。"
    }

    $codeSigningOid = '1.3.6.1.5.5.7.3.3'
    # EnhancedKeyUsageList 在 Windows PowerShell 5.1 下的元素类型随证书而异，
    # 直接取 .ObjectId.Value 会在 StrictMode 下抛错；统一从扩展里读 OID。
    $candidates = @(Get-ChildItem -Path 'Cert:\CurrentUser\My' -ErrorAction SilentlyContinue | Where-Object {
            $_.HasPrivateKey -and (@(Get-CertificateEkuOids -Certificate $_) -contains $codeSigningOid)
        } | Sort-Object NotAfter -Descending)

    if ($candidates.Count -eq 0) {
        throw "CurrentUser\My 里没有可用的代码签名证书。请先创建自签名证书，或用 -CertificateThumbprint 指定。"
    }

    $preferred = $candidates | Where-Object { $_.Subject -like '*Leigod Auto Pause*' } | Select-Object -First 1
    if ($null -ne $preferred) {
        return $preferred
    }
    if ($candidates.Count -eq 1) {
        return $candidates[0]
    }

    $listed = ($candidates | ForEach-Object { "  " + $_.Thumbprint + "  " + $_.Subject }) -join [Environment]::NewLine
    throw ("存在多张代码签名证书，请用 -CertificateThumbprint 指定：" + [Environment]::NewLine + $listed)
}

$certificate = Resolve-CodeSigningCertificate -Thumbprint $CertificateThumbprint
Write-Output ("SIGNER {0} [{1}] 有效期至 {2:yyyy-MM-dd}" -f $certificate.Subject, $certificate.Thumbprint, $certificate.NotAfter)

$failures = @()
foreach ($target in $Path) {
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        $failures += "文件不存在: $target"
        continue
    }

    $fullPath = (Get-Item -LiteralPath $target).FullName
    $signature = $null

    if (-not $NoTimestamp) {
        try {
            $signature = Set-AuthenticodeSignature -FilePath $fullPath -Certificate $certificate `
                -HashAlgorithm SHA256 -TimestampServer $TimestampUrl -ErrorAction Stop
        }
        catch {
            Write-Warning ("时间戳服务不可用，改为不带时间戳签名: {0}" -f $_.Exception.Message)
            $signature = $null
        }
    }

    if ($null -eq $signature) {
        $signature = Set-AuthenticodeSignature -FilePath $fullPath -Certificate $certificate `
            -HashAlgorithm SHA256 -ErrorAction Stop
    }

    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        $failures += ("签名未通过验证: {0} -> {1} {2}" -f $fullPath, $signature.Status, $signature.StatusMessage)
        continue
    }

    Write-Output ("SIGNED {0} ({1:N0} bytes) 状态={2}" -f $fullPath, (Get-Item -LiteralPath $fullPath).Length, $signature.Status)
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Output ("SIGN_FAILED " + $_) }
    throw "有文件签名失败。"
}

Write-Output "SIGN_OK"
