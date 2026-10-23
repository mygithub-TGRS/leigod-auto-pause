using System;
using System.IO;

namespace LeigodAutoPause
{
    /// <summary>
    /// 开机自启开关。写操作交给 app\Set-AutoStart.ps1，因为那里有经过审查的
    /// ACL 闸门（Assert-PrivateAutoStartSource）：它会拒绝把自启指向
    /// 任何可被其他本机用户修改或替换的执行链。在 C# 里重写一遍这段安全逻辑
    /// 只会带来两套需要同步的判定标准，所以这里只做读取和委托。
    /// </summary>
    internal static class AutoStartService
    {
        public static bool IsEnabled(AppPaths paths)
        {
            if (!File.Exists(paths.StartingShortcut))
            {
                return false;
            }

            ShortcutInfo info = ShortcutInterop.Read(paths.StartingShortcut);
            if (info == null)
            {
                return false;
            }

            bool targetsPowerShell = string.Equals(
                info.TargetPath,
                paths.PowerShellPath,
                StringComparison.OrdinalIgnoreCase);
            bool startsMonitor = info.Arguments != null &&
                info.Arguments.IndexOf(paths.StartScript, StringComparison.OrdinalIgnoreCase) >= 0;
            return targetsPowerShell && startsMonitor;
        }

        /// <summary>启用或关闭开机自启；失败时抛出带脚本原文的异常，界面直接展示。</summary>
        public static void SetEnabled(AppPaths paths, bool enabled)
        {
            if (!File.Exists(paths.AutoStartScript))
            {
                throw new FileNotFoundException("找不到开机自启脚本: " + paths.AutoStartScript);
            }

            ShellResult result = ProcessJob.Run(
                paths,
                paths.AutoStartScript,
                paths.ConfigPath,
                "-Action " + (enabled ? "Enable" : "Disable"),
                120000);

            if (result.TimedOut)
            {
                throw new InvalidOperationException("开机自启操作超时，未确认是否生效。");
            }
            if (result.ExitCode != 0)
            {
                string detail = string.IsNullOrWhiteSpace(result.Error) ? result.Output : result.Error;
                if (string.IsNullOrWhiteSpace(detail))
                {
                    detail = "开机自启脚本返回退出码 " + result.ExitCode + "。";
                }
                throw new InvalidOperationException(detail.Trim());
            }
        }
    }
}
