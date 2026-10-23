using System;
using System.Collections.Generic;
using System.Diagnostics;

namespace LeigodAutoPause
{
    /// <summary>
    /// 进程表快照。界面每 2 秒刷新一次，逐个进程名调用 Process.GetProcessesByName
    /// 会反复枚举整张进程表；这里统一快照一次并缓存 1 秒，和 PowerShell 版本的
    /// Get-UiProcessNameList 行为一致。
    /// </summary>
    internal static class ProcessSnapshot
    {
        private static readonly object SyncRoot = new object();
        private static string[] _names = new string[0];
        private static DateTime _namesAt = DateTime.MinValue;

        public static bool IsRunningExact(string name)
        {
            string baseName = BaseName(name);
            if (string.IsNullOrEmpty(baseName))
            {
                return false;
            }

            string[] names = CurrentNames();
            for (int index = 0; index < names.Length; index++)
            {
                if (string.Equals(names[index], baseName, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
            return false;
        }

        public static string[] CurrentNames()
        {
            lock (SyncRoot)
            {
                DateTime now = DateTime.Now;
                if (_names != null && (now - _namesAt).TotalSeconds < 1)
                {
                    return _names;
                }

                List<string> names = new List<string>();
                int currentSessionId = Process.GetCurrentProcess().SessionId;
                Process[] processes;
                try
                {
                    processes = Process.GetProcesses();
                }
                catch (Exception)
                {
                    return _names ?? new string[0];
                }

                for (int index = 0; index < processes.Length; index++)
                {
                    Process process = processes[index];
                    try
                    {
                        if (process.SessionId == currentSessionId && !string.IsNullOrEmpty(process.ProcessName))
                        {
                            names.Add(process.ProcessName);
                        }
                    }
                    catch (Exception)
                    {
                        // 访问失败的进程（权限/已退出）直接跳过，不能让它中断整次刷新。
                    }
                    finally
                    {
                        process.Dispose();
                    }
                }

                _names = names.ToArray();
                _namesAt = now;
                return _names;
            }
        }

        public static string BaseName(string name)
        {
            string trimmed = (name ?? "").Trim();
            if (trimmed.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            {
                return trimmed.Substring(0, trimmed.Length - 4);
            }
            return trimmed;
        }

        public static bool ProcessExistsInSession(int processId, int sessionId)
        {
            if (processId <= 0)
            {
                return false;
            }

            try
            {
                Process process = Process.GetProcessById(processId);
                try
                {
                    return process.SessionId == sessionId;
                }
                finally
                {
                    process.Dispose();
                }
            }
            catch (Exception)
            {
                return false;
            }
        }
    }
}
