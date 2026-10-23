using System;
using System.Windows;
using System.Windows.Shell;

namespace LeigodAutoPause
{
    /// <summary>
    /// 任务栏跳转列表。有了它，固定到任务栏之后右键就能直接跳到某个面板，
    /// 这是“由 PowerShell 承载的窗口”做不到的部分。
    /// .NET Framework 的 WPF 只提供 JumpTask/JumpPath（没有 .NET Core 才有的
    /// JumpListItem 与自定义分组），所以这里全部用 JumpTask 表达。
    /// </summary>
    internal static class JumpListInstaller
    {
        public static void Apply(AppPaths paths, Application application)
        {
            try
            {
                JumpList jumpList = new JumpList();
                jumpList.ShowFrequentCategory = false;
                jumpList.ShowRecentCategory = false;

                AddTask(jumpList, paths, "--panel Overview", "概览", "打开概览：我现在安全吗");
                AddTask(jumpList, paths, "--panel Settings", "规则设置", "打开规则设置");
                AddTask(jumpList, paths, "--panel Logs", "运行日志", "打开运行日志");
                AddTask(jumpList, paths, "--panel Diag", "诊断", "运行本机状态诊断");
                AddLogFolderTask(jumpList, paths);

                JumpList.SetJumpList(application, jumpList);
            }
            catch (Exception)
            {
                // 跳转列表不可用（组策略限制、未固定到任务栏）不影响主界面，
                // 这里静默降级，和窗口图标缺失时的处理一致。
            }
        }

        private static void AddTask(JumpList jumpList, AppPaths paths, string arguments, string title, string description)
        {
            JumpTask task = new JumpTask();
            task.ApplicationPath = paths.ExecutablePath;
            task.Arguments = arguments;
            task.Title = title;
            task.Description = description;
            task.WorkingDirectory = paths.ProjectRoot;
            jumpList.JumpItems.Add(task);
        }

        private static void AddLogFolderTask(JumpList jumpList, AppPaths paths)
        {
            JumpTask task = new JumpTask();
            task.ApplicationPath = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "explorer.exe");
            task.Arguments = AppPaths.QuoteArgument(paths.LogDirectory);
            task.Title = "打开日志目录";
            task.Description = "在资源管理器中打开 app\\logs";
            jumpList.JumpItems.Add(task);
        }
    }
}
