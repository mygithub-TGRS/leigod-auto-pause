using System;
using System.IO;

namespace LeigodAutoPause
{
    /// <summary>
    /// 从配置里解析雷神客户端可执行文件。
    /// 这里是安全边界：只接受位于本地固定磁盘、整条路径不含重解析点、且文件名
    /// 恰好是 leigod.exe 的文件，避免配置被改成指向 UNC 共享、可移动盘或
    /// 符号链接之后再让界面把它启动起来。
    /// </summary>
    internal static class LeigodLocator
    {
        public static string Resolve(string executablePath, string shortcutPath)
        {
            string direct = ResolveSafeExecutable(executablePath);
            if (!string.IsNullOrEmpty(direct))
            {
                return direct;
            }

            if (string.IsNullOrWhiteSpace(shortcutPath) ||
                !string.Equals(Path.GetExtension(shortcutPath), ".lnk", StringComparison.OrdinalIgnoreCase) ||
                !IsLocalFileSystemPath(shortcutPath) ||
                !File.Exists(shortcutPath))
            {
                return null;
            }

            ShortcutInfo info = ShortcutInterop.Read(shortcutPath);
            if (info == null)
            {
                return null;
            }
            return ResolveSafeExecutable(info.TargetPath);
        }

        public static string ResolveSafeExecutable(string path)
        {
            if (!IsLocalFileSystemPath(path))
            {
                return null;
            }
            if (!string.Equals(Path.GetFileName(path), "leigod.exe", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            try
            {
                FileInfo file = new FileInfo(path);
                if (!file.Exists || (file.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    return null;
                }
                if (!IsLocalFileSystemPath(file.FullName))
                {
                    return null;
                }
                if (!string.Equals(file.Name, "leigod.exe", StringComparison.OrdinalIgnoreCase))
                {
                    return null;
                }
                return file.FullName;
            }
            catch (Exception)
            {
                return null;
            }
        }

        /// <summary>
        /// 路径必须是绝对路径、非 UNC、所在卷为固定磁盘，且自身与全部祖先目录
        /// 都不是重解析点（junction / symlink）。
        /// </summary>
        public static bool IsLocalFileSystemPath(string path)
        {
            if (string.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path))
            {
                return false;
            }

            try
            {
                string fullPath = Path.GetFullPath(path);
                if (fullPath.StartsWith("\\\\", StringComparison.Ordinal))
                {
                    return false;
                }

                string root = Path.GetPathRoot(fullPath);
                if (string.IsNullOrEmpty(root))
                {
                    return false;
                }

                DriveInfo drive = new DriveInfo(root);
                if (drive.DriveType != DriveType.Fixed)
                {
                    return false;
                }

                FileSystemInfo item = Describe(fullPath);
                if (item == null)
                {
                    return false;
                }

                while (item != null)
                {
                    if ((item.Attributes & FileAttributes.ReparsePoint) != 0)
                    {
                        return false;
                    }

                    DirectoryInfo directory = item as DirectoryInfo;
                    if (directory != null)
                    {
                        item = directory.Parent;
                        continue;
                    }

                    FileInfo file = item as FileInfo;
                    item = file == null ? null : file.Directory;
                }

                return true;
            }
            catch (Exception)
            {
                return false;
            }
        }

        private static FileSystemInfo Describe(string fullPath)
        {
            try
            {
                if (Directory.Exists(fullPath))
                {
                    DirectoryInfo directory = new DirectoryInfo(fullPath);
                    if (!directory.Exists)
                    {
                        return null;
                    }
                    return directory;
                }

                FileInfo file = new FileInfo(fullPath);
                if (!file.Exists)
                {
                    return null;
                }
                return file;
            }
            catch (Exception)
            {
                return null;
            }
        }
    }
}
