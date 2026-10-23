using System;
using System.IO;

namespace LeigodAutoPause
{
    /// <summary>
    /// 应用目录契约。EXE 位于项目根目录，业务脚本与界面资源都在 app 子目录里，
    /// 与迁移前的 PowerShell 版本完全一致，所以配置、日志、快捷方式都能直接复用。
    /// </summary>
    internal sealed class AppPaths
    {
        public const string ApplicationName = "雷神自动暂停（非官方）";
        public const string MonitorMutexName = @"Local\LeigodAutoPauseMonitor";
        public const string ControlMutexName = @"Local\LeigodAutoPauseControl";
        public const string UiMutexName = @"Local\LeigodAutoPauseUI";
        public const string UiActivateEventName = @"Local\LeigodAutoPauseUIActivate";
        public const string UiActivateMapName = @"Local\LeigodAutoPauseUIActivateData";
        public const string AppUserModelId = "LeigodAutoPause.ControlPanel";

        public AppPaths(string projectRoot)
        {
            ProjectRoot = Path.GetFullPath(projectRoot);
            AppDirectory = Path.Combine(ProjectRoot, "app");

            ConfigPath = Path.Combine(AppDirectory, "config.json");
            ConfigExamplePath = Path.Combine(AppDirectory, "config.example.json");
            ConfigBootstrapScript = Path.Combine(AppDirectory, "ConfigBootstrap.ps1");
            SecurityHelpersScript = Path.Combine(AppDirectory, "SecurityHelpers.ps1");
            MonitorScript = Path.Combine(AppDirectory, "LeigodAutoPause.ps1");
            StartScript = Path.Combine(AppDirectory, "Start-Monitor.ps1");
            StopScript = Path.Combine(AppDirectory, "Stop-Monitor.ps1");
            RestartScript = Path.Combine(AppDirectory, "Restart-Monitor.ps1");
            AutoStartScript = Path.Combine(AppDirectory, "Set-AutoStart.ps1");
            XamlPath = Path.Combine(AppDirectory, "ui", "MainWindow.xaml");
            IconPath = Path.Combine(AppDirectory, "ui", "app.ico");
            LogDirectory = Path.Combine(AppDirectory, "logs");
            RuntimeStatePath = Path.Combine(LogDirectory, "runtime-state.json");
            ExecutablePath = Path.Combine(ProjectRoot, "LeigodAutoPause.exe");

            StartingShortcut = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Startup),
                "Leigod Auto Pause.lnk");

            PowerShellPath = ResolveWindowsPowerShell();
        }

        public string ProjectRoot { get; private set; }

        public string AppDirectory { get; private set; }

        public string ConfigPath { get; private set; }

        public string ConfigExamplePath { get; private set; }

        public string ConfigBootstrapScript { get; private set; }

        public string SecurityHelpersScript { get; private set; }

        public string MonitorScript { get; private set; }

        public string StartScript { get; private set; }

        public string StopScript { get; private set; }

        public string RestartScript { get; private set; }

        public string AutoStartScript { get; private set; }

        public string XamlPath { get; private set; }

        public string IconPath { get; private set; }

        public string LogDirectory { get; private set; }

        public string RuntimeStatePath { get; private set; }

        public string ExecutablePath { get; private set; }

        public string StartingShortcut { get; private set; }

        public string PowerShellPath { get; private set; }

        /// <summary>
        /// 启动前检查运行所需的业务脚本。EXE 自己就是控制台，脚本缺失时
        /// 不能再像旧启动器那样静默退出，而要给出能直接读懂的提示。
        /// </summary>
        public string[] MissingRuntimeFiles()
        {
            string[] required =
            {
                ConfigBootstrapScript,
                SecurityHelpersScript,
                MonitorScript,
                StartScript,
                StopScript,
                RestartScript,
                AutoStartScript,
                ConfigExamplePath,
                XamlPath
            };

            System.Collections.Generic.List<string> missing = new System.Collections.Generic.List<string>();
            for (int index = 0; index < required.Length; index++)
            {
                if (!File.Exists(required[index]))
                {
                    missing.Add(required[index]);
                }
            }
            return missing.ToArray();
        }

        private static string ResolveWindowsPowerShell()
        {
            string[] candidates =
            {
                Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "SysWOW64", "WindowsPowerShell", "v1.0", "powershell.exe")
            };

            for (int index = 0; index < candidates.Length; index++)
            {
                if (File.Exists(candidates[index]))
                {
                    return candidates[index];
                }
            }

            // 找不到时仍然返回首选路径：调用点会以“后台脚本启动失败”的形式暴露出来，
            // 而不是在界面初始化阶段直接抛异常。
            return candidates[0];
        }

        public static string QuoteArgument(string value)
        {
            return "\"" + (value ?? "").Replace("\"", "\\\"") + "\"";
        }
    }
}
