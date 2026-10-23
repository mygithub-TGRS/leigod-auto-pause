using System;

namespace LeigodAutoPause
{
    internal enum ProbeOutcome
    {
        Idle,
        Running,
        TimedOut,
        Completed
    }

    /// <summary>
    /// 账号状态探测：调用 app\LeigodAutoPause.ps1 -CheckJson，读取脱敏后的本机事实。
    /// 后台监控正常运行时界面直接读 runtime-state.json，只有状态文件过期
    /// （监控卡住或刚重启）才会走到这里兜底，避免每 20 秒起一个 PowerShell 进程。
    /// </summary>
    internal sealed class StatusProbeService : IDisposable
    {
        private const int TimeoutSeconds = 20;
        private const int MinimumIntervalSeconds = 30;

        private ProcessJob _job;

        public StatusProbeService()
        {
            NextProbeAt = DateTime.MinValue;
            LastProbe = null;
        }

        public DateTime NextProbeAt { get; set; }

        public JsonObject LastProbe { get; private set; }

        public bool IsRunning
        {
            get { return _job != null; }
        }

        public bool CanStart(bool force)
        {
            if (_job != null)
            {
                return false;
            }
            if (!force && DateTime.Now < NextProbeAt)
            {
                return false;
            }
            return true;
        }

        public void Start(AppPaths paths)
        {
            _job = ProcessJob.Start(paths, paths.MonitorScript, paths.ConfigPath, "-ConfigPath $env:LAP_CONFIG -CheckJson");
            NextProbeAt = DateTime.Now.AddSeconds(MinimumIntervalSeconds);
        }

        /// <summary>
        /// 轮询探测结果。返回 Completed 表示本次探测已结束（无论成功与否），
        /// 调用方需要随后刷新界面。
        /// </summary>
        public ProbeOutcome Poll(out bool succeeded)
        {
            succeeded = false;
            if (_job == null)
            {
                return ProbeOutcome.Idle;
            }

            if (!_job.HasExited)
            {
                if ((DateTime.Now - _job.StartedAt).TotalSeconds > TimeoutSeconds)
                {
                    _job.Kill();
                    LastProbe = null;
                    _job.Dispose();
                    _job = null;
                    return ProbeOutcome.TimedOut;
                }
                return ProbeOutcome.Running;
            }

            string output = _job.Output.Trim();
            int exitCode = _job.ExitCode;
            _job.Dispose();
            _job = null;

            if (exitCode == 0 && !string.IsNullOrEmpty(output))
            {
                try
                {
                    LastProbe = Json.Parse(output) as JsonObject;
                }
                catch (FormatException)
                {
                    LastProbe = null;
                }
            }
            else
            {
                LastProbe = null;
            }

            succeeded = LastProbe != null;
            return ProbeOutcome.Completed;
        }

        public void Reset()
        {
            NextProbeAt = DateTime.MinValue;
        }

        public void Dispose()
        {
            if (_job != null)
            {
                _job.Kill();
                _job.Dispose();
                _job = null;
            }
        }
    }
}
