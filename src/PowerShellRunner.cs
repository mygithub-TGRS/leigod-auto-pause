using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace LeigodAutoPause
{
    internal sealed class ShellResult
    {
        public int ExitCode { get; set; }

        public string Output { get; set; }

        public string Error { get; set; }

        public bool TimedOut { get; set; }
    }

    /// <summary>
    /// 一个正在运行的子进程，输出异步收集。
    /// 后台脚本会输出中文（例如配置校验的报错原文），所以必须在启动时
    /// 把子进程的 [Console]::OutputEncoding 固定为 UTF-8，再按 UTF-8 解码；
    /// 否则在非中文系统上会变成问号，在本机则取决于控制台代码页。
    /// </summary>
    internal sealed class ProcessJob : IDisposable
    {
        private const string EncodingPrologue = "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;";

        private readonly object _sync = new object();
        private readonly StringBuilder _output = new StringBuilder();
        private readonly StringBuilder _error = new StringBuilder();
        private Process _process;
        private bool _disposed;

        private ProcessJob(Process process)
        {
            _process = process;
            StartedAt = DateTime.Now;
        }

        public DateTime StartedAt { get; private set; }

        public bool HasExited
        {
            get
            {
                Process process = _process;
                if (process == null)
                {
                    return true;
                }
                try
                {
                    return process.HasExited;
                }
                catch (InvalidOperationException)
                {
                    return true;
                }
            }
        }

        public int ExitCode
        {
            get
            {
                Process process = _process;
                if (process == null)
                {
                    return -1;
                }
                try
                {
                    return process.HasExited ? process.ExitCode : -1;
                }
                catch (InvalidOperationException)
                {
                    return -1;
                }
            }
        }

        public string Output
        {
            get
            {
                lock (_sync)
                {
                    return _output.ToString();
                }
            }
        }

        public string Error
        {
            get
            {
                lock (_sync)
                {
                    return _error.ToString();
                }
            }
        }

        public static ProcessJob Start(AppPaths paths, string scriptPath, string configPath, string switchArguments)
        {
            ProcessStartInfo info = BuildStartInfo(paths, scriptPath, configPath, switchArguments);
            Process process = new Process();
            process.StartInfo = info;
            ProcessJob job = new ProcessJob(process);
            process.OutputDataReceived += job.OnOutputDataReceived;
            process.ErrorDataReceived += job.OnErrorDataReceived;
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            return job;
        }

        /// <summary>同步执行并等待结束；超时会结束子进程并标记 TimedOut。</summary>
        public static ShellResult Run(AppPaths paths, string scriptPath, string configPath, string switchArguments, int timeoutMilliseconds)
        {
            using (ProcessJob job = Start(paths, scriptPath, configPath, switchArguments))
            {
                bool exited;
                try
                {
                    exited = job._process.WaitForExit(timeoutMilliseconds);
                }
                catch (Exception)
                {
                    exited = false;
                }

                ShellResult result = new ShellResult();
                if (!exited)
                {
                    job.Kill();
                    result.TimedOut = true;
                }

                // 让 BeginOutputReadLine 的异步回调把尾部输出收进缓冲区，再取快照。
                try
                {
                    job._process.WaitForExit(2000);
                }
                catch (Exception)
                {
                }

                result.ExitCode = job.ExitCode;
                result.Output = job.Output.Trim();
                result.Error = job.Error.Trim();
                return result;
            }
        }

        public void Kill()
        {
            Process process = _process;
            if (process == null)
            {
                return;
            }
            try
            {
                if (!process.HasExited)
                {
                    process.Kill();
                }
            }
            catch (Exception)
            {
            }
        }

        public bool WaitForExit(int milliseconds)
        {
            Process process = _process;
            if (process == null)
            {
                return true;
            }
            try
            {
                return process.WaitForExit(milliseconds);
            }
            catch (Exception)
            {
                return true;
            }
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            Process process = _process;
            _process = null;
            if (process != null)
            {
                try
                {
                    process.OutputDataReceived -= OnOutputDataReceived;
                    process.ErrorDataReceived -= OnErrorDataReceived;
                    process.Dispose();
                }
                catch (Exception)
                {
                }
            }
        }

        private void OnOutputDataReceived(object sender, DataReceivedEventArgs args)
        {
            if (args.Data == null)
            {
                return;
            }
            lock (_sync)
            {
                _output.AppendLine(args.Data);
            }
        }

        private void OnErrorDataReceived(object sender, DataReceivedEventArgs args)
        {
            if (args.Data == null)
            {
                return;
            }
            lock (_sync)
            {
                _error.AppendLine(args.Data);
            }
        }

        /// <summary>
        /// 脚本路径与配置路径通过环境变量传入，命令行里只出现开关名称。
        /// 这样安装目录包含空格、单引号或中文时都不需要转义，也不会被拆成多个参数。
        /// </summary>
        private static ProcessStartInfo BuildStartInfo(AppPaths paths, string scriptPath, string configPath, string switchArguments)
        {
            // 不在这里改 $ErrorActionPreference：每个业务脚本自己会设置，
            // 由 C# 侧再压一层会让脚本里被捕获/忽略的非终止错误变成致命错误。
            string command = EncodingPrologue +
                " & $env:LAP_SCRIPT" +
                (string.IsNullOrEmpty(switchArguments) ? "" : " " + switchArguments);

            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = paths.PowerShellPath;
            info.Arguments =
                "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"" + command + "\"";
            info.WorkingDirectory = paths.AppDirectory;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WindowStyle = ProcessWindowStyle.Hidden;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            info.StandardOutputEncoding = new UTF8Encoding(false);
            info.StandardErrorEncoding = new UTF8Encoding(false);
            info.EnvironmentVariables["LAP_SCRIPT"] = scriptPath;
            if (!string.IsNullOrEmpty(configPath))
            {
                info.EnvironmentVariables["LAP_CONFIG"] = configPath;
            }
            return info;
        }
    }
}
