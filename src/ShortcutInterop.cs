using System;
using System.Runtime.InteropServices;

namespace LeigodAutoPause
{
    internal sealed class ShortcutInfo
    {
        public string TargetPath { get; set; }

        public string Arguments { get; set; }

        public string WorkingDirectory { get; set; }
    }

    /// <summary>
    /// 读取 .lnk 的惰性封装。用 WScript.Shell 是因为 .NET Framework 没有公开的
    /// 快捷方式读取 API，而解析 .lnk 二进制格式不值得在这里实现一遍。
    /// </summary>
    internal static class ShortcutInterop
    {
        public static ShortcutInfo Read(string shortcutPath)
        {
            object shell = null;
            try
            {
                Type shellType = Type.GetTypeFromProgID("WScript.Shell");
                if (shellType == null)
                {
                    return null;
                }

                shell = Activator.CreateInstance(shellType);
                dynamic comShell = shell;
                dynamic shortcut = comShell.CreateShortcut(shortcutPath);

                ShortcutInfo info = new ShortcutInfo();
                info.TargetPath = (string)shortcut.TargetPath;
                info.Arguments = (string)shortcut.Arguments;
                info.WorkingDirectory = (string)shortcut.WorkingDirectory;
                return info;
            }
            catch (Exception)
            {
                return null;
            }
            finally
            {
                if (shell != null)
                {
                    try
                    {
                        Marshal.FinalReleaseComObject(shell);
                    }
                    catch (Exception)
                    {
                    }
                }
            }
        }
    }
}
