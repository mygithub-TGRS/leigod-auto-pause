using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Leigod Auto Pause Launcher (Unofficial)")]
[assembly: AssemblyDescription("Launches the unofficial local Leigod Auto Pause control panel")]
[assembly: AssemblyCompany("Leigod Auto Pause contributors")]
[assembly: AssemblyProduct("Leigod Auto Pause")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace LeigodAutoPauseLauncher
{
    internal static class Program
    {
        [STAThread]
        private static int Main()
        {
            try
            {
                string projectRoot = AppDomain.CurrentDomain.BaseDirectory;
                string appDirectory = Path.Combine(projectRoot, "app");
                string uiScript = Path.Combine(appDirectory, "LeigodAutoPause.UI.ps1");
                string[] requiredFiles =
                {
                    uiScript,
                    Path.Combine(appDirectory, "ConfigBootstrap.ps1"),
                    Path.Combine(appDirectory, "SecurityHelpers.ps1"),
                    Path.Combine(appDirectory, "LeigodAutoPause.ps1"),
                    Path.Combine(appDirectory, "Start-Monitor.ps1"),
                    Path.Combine(appDirectory, "Stop-Monitor.ps1"),
                    Path.Combine(appDirectory, "Restart-Monitor.ps1"),
                    Path.Combine(appDirectory, "config.example.json"),
                    Path.Combine(appDirectory, "ui", "MainWindow.xaml")
                };

                foreach (string requiredFile in requiredFiles)
                {
                    if (!File.Exists(requiredFile))
                    {
                        return ShowError("A required application file is missing:\n" + requiredFile);
                    }
                }

                string powershell = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    "WindowsPowerShell",
                    "v1.0",
                    "powershell.exe");

                if (!File.Exists(powershell))
                {
                    return ShowError("Windows PowerShell could not be found.");
                }

                var startInfo = new ProcessStartInfo
                {
                    FileName = powershell,
                    Arguments = "-STA -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " + Quote(uiScript),
                    WorkingDirectory = appDirectory,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden,
                    ErrorDialog = false
                };

                Process process = Process.Start(startInfo);
                if (process == null)
                {
                    return ShowError("The control panel process could not be started.");
                }
                using (process)
                {
                    if (process.WaitForExit(3000) && process.ExitCode != 0)
                    {
                        return ShowError(
                            "The control panel failed during startup.\n\n" +
                            "Check app\\config.json or run tools\\Test.ps1 for diagnostics.");
                    }
                }
                return 0;
            }
            catch (Exception exception)
            {
                return ShowError("Unable to open the control panel.\n\n" + exception.Message);
            }
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static int ShowError(string message)
        {
            MessageBox.Show(
                message,
                "Leigod Auto Pause (Unofficial)",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
    }
}
