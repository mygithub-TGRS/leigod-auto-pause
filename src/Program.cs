using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows;
using System.Windows.Markup;

namespace LeigodAutoPause
{
    /// <summary>
    /// 控制台入口。这个进程本身就是产品：进程名是 LeigodAutoPause，
    /// 拥有显式的 AppUserModelID（任务栏固定、跳转列表都依赖它）、
    /// 自己的图标与版本信息，可以正常签名分发；
    /// 后台监控仍然由 app 目录下的 PowerShell 脚本承担，界面只负责调度和呈现。
    /// </summary>
    internal static class Program
    {
        private static readonly string[] PanelNames = { "Overview", "Settings", "Logs", "Diag" };

        [STAThread]
        private static int Main(string[] args)
        {

            PanelOptions options;
            string argumentError;
            if (!TryParseArguments(args, out options, out argumentError))
            {
                ShowError(argumentError);
                return 2;
            }

            string applicationRoot = AppDomain.CurrentDomain.BaseDirectory;
            AppPaths paths;
            try
            {
                paths = new AppPaths(applicationRoot);
            }
            catch (Exception exception)
            {
                ShowError("无法确定程序目录。\n\n" + exception.Message);
                return 1;
            }

            string[] missing = paths.MissingRuntimeFiles();
            if (missing.Length > 0)
            {
                ShowError(
                    "应用文件不完整，缺少：\n" +
                    string.Join("\n", missing) +
                    "\n\n请从完整发布包重新解压，不要把 EXE 单独复制出去。");
                return 1;
            }

            SetAppUserModelId();

            string mutexName = string.IsNullOrEmpty(options.SnapshotPath)
                ? AppPaths.UiMutexName
                : AppPaths.UiMutexName + "-Snapshot-" + Process.GetCurrentProcess().Id;

            using (Mutex instanceMutex = new Mutex(false, mutexName))
            {
                bool ownsMutex = false;
                try
                {
                    try
                    {
                        ownsMutex = instanceMutex.WaitOne(0, false);
                    }
                    catch (AbandonedMutexException)
                    {
                        ownsMutex = true;
                    }

                    if (!ownsMutex)
                    {
                        RequestActivation(options.InitialPanel);
                        return 0;
                    }

                    return RunApplication(paths, options);
                }
                finally
                {
                    if (ownsMutex)
                    {
                        try
                        {
                            instanceMutex.ReleaseMutex();
                        }
                        catch (Exception)
                        {
                        }
                    }
                }
            }
        }

        private static int RunApplication(AppPaths paths, PanelOptions options)
        {
            try
            {
                Window window = LoadWindow(paths);

                Application application = new Application();
                application.ShutdownMode = ShutdownMode.OnMainWindowClose;
                application.MainWindow = window;

                ControlPanel panel = new ControlPanel(paths, window, options);
                panel.Initialize();

                JumpListInstaller.Apply(paths, application);
                RegisterActivationListener(panel);

                application.Run(window);
                return panel.SnapshotFailed ? 1 : 0;
            }
            catch (Exception exception)
            {
                Diagnostics.LogException(paths, "启动失败", exception);
                if (string.IsNullOrEmpty(options.SnapshotPath))
                {
                    ShowError("控制台启动失败。\n\n" + exception.Message +
                        "\n\n可运行 tools\\Test.ps1 做本机自检。");
                }
                return 1;
            }
        }

        private static Window LoadWindow(AppPaths paths)
        {
            // XAML 保持为 app\ui\MainWindow.xaml 这一份文件：界面样式是纯资源，
            // 不编译进程序集，改样式不需要重新构建 EXE。
            try
            {
                using (FileStream stream = new FileStream(
                    paths.XamlPath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read))
                {
                    Window window = XamlReader.Load(stream) as Window;
                    if (window == null)
                    {
                        throw new InvalidOperationException("界面文件根元素不是 Window: " + paths.XamlPath);
                    }
                    return window;
                }
            }
            catch (Exception exception)
            {
                throw new InvalidOperationException("界面资源无法解析: " + paths.XamlPath, exception);
            }
        }

        private static bool TryParseArguments(string[] args, out PanelOptions options, out string error)
        {
            options = new PanelOptions();
            error = "";

            for (int index = 0; index < args.Length; index++)
            {
                string argument = args[index] ?? "";
                if (string.Equals(argument, "--panel", StringComparison.OrdinalIgnoreCase))
                {
                    string requested = index + 1 < args.Length ? args[++index] : "";
                    string normalized;
                    if (!TryNormalizePanel(requested, out normalized))
                    {
                        error = "未知面板: " + requested + "。可用值: Overview / Settings / Logs / Diag。";
                        return false;
                    }
                    options.InitialPanel = normalized;
                    continue;
                }

                if (string.Equals(argument, "--snapshot", StringComparison.OrdinalIgnoreCase))
                {
                    string value = index + 1 < args.Length ? args[++index] : "";
                    if (string.IsNullOrWhiteSpace(value) ||
                        !value.EndsWith(".snapshot.png", StringComparison.OrdinalIgnoreCase))
                    {
                        error = "快照路径必须以 .snapshot.png 结尾（产物已被 .gitignore 排除）。";
                        return false;
                    }
                    options.SnapshotPath = Path.GetFullPath(value);
                    continue;
                }

                if (string.Equals(argument, "--auto-close", StringComparison.OrdinalIgnoreCase))
                {
                    string value = index + 1 < args.Length ? args[++index] : "";
                    int seconds;
                    if (!int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out seconds) ||
                        seconds < 0 || seconds > 300)
                    {
                        error = "--auto-close 必须是 0 到 300 之间的整数秒。";
                        return false;
                    }
                    options.AutoCloseSeconds = seconds;
                    continue;
                }

                error = "未知参数: " + argument + "。支持的参数: --panel / --snapshot / --auto-close。";
                return false;
            }

            return true;
        }

        private static bool TryNormalizePanel(string value, out string normalized)
        {
            normalized = "";
            for (int index = 0; index < PanelNames.Length; index++)
            {
                if (string.Equals(PanelNames[index], value, StringComparison.OrdinalIgnoreCase))
                {
                    normalized = PanelNames[index];
                    return true;
                }
            }
            return false;
        }

        /// <summary>
        /// 第二个实例的处理：把要打开的面板写进共享内存并通知已运行的实例，
        /// 让它切到对应面板并把窗口带到前台；MSIX 之外这是跳转列表能真正生效的前提。
        /// 共享内存不可用时退回旧行为——弹一句“控制台已经打开”。
        /// </summary>
        private static void RequestActivation(string panelName)
        {
            try
            {
                using (MemoryMappedFile map = MemoryMappedFile.OpenExisting(AppPaths.UiActivateMapName))
                {
                    WritePanelRequest(map, panelName);
                }
                using (EventWaitHandle signal = EventWaitHandle.OpenExisting(AppPaths.UiActivateEventName))
                {
                    signal.Set();
                }
            }
            catch (Exception)
            {
                MessageBox.Show(
                    "控制台已经打开。",
                    AppPaths.ApplicationName,
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            }
        }

        private static void RegisterActivationListener(ControlPanel panel)
        {
            try
            {
                MemoryMappedFile map = MemoryMappedFile.CreateOrOpen(AppPaths.UiActivateMapName, 256);
                EventWaitHandle signal = new EventWaitHandle(
                    false,
                    EventResetMode.AutoReset,
                    AppPaths.UiActivateEventName);

                WaitOrTimerCallback callback = delegate
                {
                    string panelName = ReadPanelRequest(map);
                    Application.Current.Dispatcher.BeginInvoke(
                        new Action(delegate { panel.Activate(panelName); }));
                };

                ThreadPool.RegisterWaitForSingleObject(signal, callback, null, Timeout.Infinite, false);
            }
            catch (Exception)
            {
                // 激活通道不可用只影响“重复启动时切前台”，不影响主功能。
            }
        }

        private static void WritePanelRequest(MemoryMappedFile map, string panelName)
        {
            byte[] payload = new byte[256];
            byte[] text = new UTF8Encoding(false).GetBytes(panelName ?? "");
            int count = Math.Min(text.Length, payload.Length - 1);
            Array.Copy(text, payload, count);
            using (MemoryMappedViewAccessor view = map.CreateViewAccessor(0, payload.Length))
            {
                view.WriteArray(0, payload, 0, payload.Length);
            }
        }

        private static string ReadPanelRequest(MemoryMappedFile map)
        {
            byte[] payload = new byte[256];
            using (MemoryMappedViewAccessor view = map.CreateViewAccessor(0, payload.Length))
            {
                view.ReadArray(0, payload, 0, payload.Length);
            }
            int length = Array.IndexOf(payload, (byte)0);
            if (length < 0)
            {
                length = payload.Length;
            }
            return new UTF8Encoding(false).GetString(payload, 0, length).Trim();
        }

        private static void SetAppUserModelId()
        {
            try
            {
                SetCurrentProcessExplicitAppUserModelID(AppPaths.AppUserModelId);
            }
            catch (Exception)
            {
                // 没有显式 AppUserModelID 时任务栏仍可用，只是固定项分组会退化成按路径分组。
            }
        }

        private static void ShowError(string message)
        {
            MessageBox.Show(
                message,
                AppPaths.ApplicationName,
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SetCurrentProcessExplicitAppUserModelID(string appUserModelId);
    }
}
