function Get-WindowsPowerShellPath {
    $candidates = @(
        (Join-Path $PSHOME "powershell.exe"),
        (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Get-Item -LiteralPath $candidate -Force).FullName
        }
    }
    throw "找不到 Windows PowerShell 5.1。"
}

function Test-LocalFileSystemPath {
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathRooted($Path)) {
        return $false
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        if ($fullPath.StartsWith("\\", [System.StringComparison]::Ordinal)) {
            return $false
        }

        $root = [System.IO.Path]::GetPathRoot($fullPath)
        if ([string]::IsNullOrWhiteSpace($root)) {
            return $false
        }
        $drive = New-Object System.IO.DriveInfo -ArgumentList $root
        if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) {
            return $false
        }

        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        while ($null -ne $item) {
            if (-not ($item -is [System.IO.FileSystemInfo]) -or
                ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                return $false
            }
            $item = $(if ($item -is [System.IO.DirectoryInfo]) { $item.Parent } else { $item.Directory })
        }
        return $true
    }
    catch {
        return $false
    }
}

function Resolve-SafeLeigodExecutablePath {
    param([AllowEmptyString()][string]$Path)

    if (-not (Test-LocalFileSystemPath -Path $Path)) {
        return $null
    }
    if (-not [string]::Equals([System.IO.Path]::GetFileName($Path), "leigod.exe", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or
            $item.PSProvider.Name -ne "FileSystem" -or
            ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            return $null
        }
        if (-not (Test-LocalFileSystemPath -Path $item.FullName)) {
            return $null
        }
        if (-not [string]::Equals($item.Name, "leigod.exe", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        return $item.FullName
    }
    catch {
        return $null
    }
}

function Resolve-LeigodExecutableFromPaths {
    param(
        [AllowEmptyString()][string]$ExecutablePath,
        [AllowEmptyString()][string]$ShortcutPath
    )

    $directPath = Resolve-SafeLeigodExecutablePath -Path $ExecutablePath
    if ($directPath) {
        return $directPath
    }

    if ([string]::IsNullOrWhiteSpace($ShortcutPath) -or
        -not [string]::Equals([System.IO.Path]::GetExtension($ShortcutPath), ".lnk", [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-LocalFileSystemPath -Path $ShortcutPath) -or
        -not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) {
        return $null
    }

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        return Resolve-SafeLeigodExecutablePath -Path ([string]$shortcut.TargetPath)
    }
    finally {
        if ($null -ne $shell) {
            [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

function Assert-PrivateAutoStartSource {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Path)

    $currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $trustedOwnerSids = @(
        $currentUserSid,
        "S-1-5-18",      # LOCAL SYSTEM
        "S-1-5-32-544",  # BUILTIN\Administrators
        "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464" # TrustedInstaller
    )
    $trustedRuleSids = @($trustedOwnerSids) + @(
        "S-1-3-0", # CREATOR OWNER
        "S-1-3-4"  # OWNER RIGHTS
    )
    $sourceWriteMask = [int64]([System.Security.AccessControl.FileSystemRights]::Write -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership)
    $ancestorReplaceMask = [int64]([System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership)

    function Assert-TrustedPathAcl {
        param(
            [Parameter(Mandatory = $true)]$Item,
            [Parameter(Mandatory = $true)][int64]$DangerousRights
        )

        $acl = Get-Acl -LiteralPath $Item.FullName
        try {
            $ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        }
        catch {
            throw "拒绝启用开机自启：无法确认 $($Item.FullName) 的所有者。"
        }
        if ($trustedOwnerSids -notcontains $ownerSid) {
            throw "拒绝启用开机自启：$($Item.FullName) 的所有者不是当前用户或受信任的系统主体。"
        }

        foreach ($rule in $acl.Access) {
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
                continue
            }

            $rights = [int64]$rule.FileSystemRights
            if (($rights -band $DangerousRights) -eq 0) {
                continue
            }
            try {
                $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
            }
            catch {
                throw "拒绝启用开机自启：无法确认 $($Item.FullName) 的写入权限主体。"
            }
            if ($trustedRuleSids -notcontains $sid) {
                throw "拒绝启用开机自启：$($Item.FullName) 可被其他本机用户修改或替换。请将项目放入当前用户专属目录后重试。"
            }
        }
    }

    foreach ($candidate in $Path) {
        if (-not (Test-LocalFileSystemPath -Path $candidate)) {
            throw "拒绝启用开机自启：$candidate 必须位于无重解析点的本地固定磁盘路径。"
        }
        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        Assert-TrustedPathAcl -Item $item -DangerousRights $sourceWriteMask

        $ancestor = $(if ($item -is [System.IO.DirectoryInfo]) { $item.Parent } else { $item.Directory })
        while ($null -ne $ancestor) {
            Assert-TrustedPathAcl -Item $ancestor -DangerousRights $ancestorReplaceMask
            $ancestor = $ancestor.Parent
        }
    }
}
