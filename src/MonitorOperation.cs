using System;
using System.Collections.Generic;

namespace LeigodAutoPause
{
    internal enum MonitorAction
    {
        Start,
        Stop,
        Restart
    }

    /// <summary>
    /// 后台监控的启停与重启。业务逻辑仍在 PowerShell 脚本里（它们持有控制锁、
    /// 校验配置、维护单实例互斥量），这里只负责异步执行并把结果翻译成界面文案。
    /// </summary>
    internal sealed class MonitorOperation : IDisposable
    {
        private ProcessJob _job;

        private MonitorOperation(MonitorAction action, ProcessJob job)
        {
            Action = action;
            _job = job;
        }

        public MonitorAction Action { get; private set; }

        public bool IsFinished
        {
            get { return _job == null || _job.HasExited; }
        }

        public static MonitorOperation Start(AppPaths paths, MonitorAction action)
        {
            string script;
            string switches;
            switch (action)
            {
                case MonitorAction.Stop:
                    script = paths.StopScript;
                    switches = "";
                    break;
                case MonitorAction.Restart:
                    script = paths.RestartScript;
                    switches = "-ConfigPath $env:LAP_CONFIG";
                    break;
                default:
                    script = paths.StartScript;
                    switches = "-ConfigPath $env:LAP_CONFIG";
                    break;
            }

            ProcessJob job = ProcessJob.Start(
                paths,
                script,
                action == MonitorAction.Stop ? null : paths.ConfigPath,
                switches);
            return new MonitorOperation(action, job);
        }

        public static string PendingMessage(MonitorAction action)
        {
            switch (action)
            {
                case MonitorAction.Stop:
                    return "正在安全停止后台监控...";
                case MonitorAction.Restart:
                    return "正在应用设置并重启监控...";
                default:
                    return "正在启动后台监控...";
            }
        }

        public static string SuccessMessage(MonitorAction action)
        {
            switch (action)
            {
                case MonitorAction.Stop:
                    return "后台监控已停止；控制台仍保持打开。";
                case MonitorAction.Restart:
                    return "设置已应用，后台监控已重启。";
                default:
                    return "后台监控已启动。";
            }
        }

        /// <summary>
        /// 取错误详情的最后 3 行。只取最后一行会把真正的原因吞掉
        /// （例如“配置验证失败，未启动监控。”盖住了“game_processes 必须使用不含路径或通配符的完整进程名。”）。
        /// </summary>
        public string FailureDetail()
        {
            List<string> lines = new List<string>();
            if (_job != null)
            {
                CollectLines(_job.Error, lines);
                CollectLines(_job.Output, lines);
            }

            int start = Math.Max(0, lines.Count - 3);
            List<string> tail = new List<string>();
            for (int index = start; index < lines.Count; index++)
            {
                tail.Add(lines[index]);
            }

            string detail = tail.Count > 0 ? string.Join(" / ", tail.ToArray()) : "未知错误";
            if (detail.IndexOf("MONITOR_ALREADY_RUNNING", StringComparison.Ordinal) >= 0)
            {
                detail = "后台监控已在运行。";
            }
            return detail;
        }

        public int ExitCode
        {
            get { return _job == null ? -1 : _job.ExitCode; }
        }

        public void Dispose()
        {
            if (_job != null)
            {
                _job.Dispose();
                _job = null;
            }
        }

        private static void CollectLines(string source, List<string> lines)
        {
            if (string.IsNullOrEmpty(source))
            {
                return;
            }
            string[] split = source.Split(new[] { "\r\n", "\n", "\r" }, StringSplitOptions.None);
            for (int index = 0; index < split.Length; index++)
            {
                if (!string.IsNullOrWhiteSpace(split[index]))
                {
                    lines.Add(split[index].Trim());
                }
            }
        }
    }
}
