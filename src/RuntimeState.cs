using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;

namespace LeigodAutoPause
{
    /// <summary>
    /// 后台监控写入的短期状态快照（app\logs\runtime-state.json）。
    /// 与 PowerShell 版 Get-CurrentRuntimeState 一样：文件过期、进程已退出或
    /// 不属于当前登录会话时，一律视为“没有状态”，界面不能拿旧值假装正常。
    /// </summary>
    internal sealed class RuntimeState
    {
        private RuntimeState()
        {
        }

        public JsonObject Raw { get; private set; }

        public DateTime UpdatedAt { get; private set; }

        public string State { get; private set; }

        public string AccountState { get; private set; }

        public string AccountMessage { get; private set; }

        public string LastDecision { get; private set; }

        public string LastDecisionAt { get; private set; }

        public string PauseDeadlineAt { get; private set; }

        public bool LaunchPending { get; private set; }

        public bool UnresolvedLaunch { get; private set; }

        public bool SessionConfirmed { get; private set; }

        public string[] RunningGames { get; private set; }

        public string[] TargetProcesses { get; private set; }

        public static RuntimeState Load(string path, int pollSeconds)
        {
            if (!File.Exists(path))
            {
                return null;
            }

            try
            {
                string text = ReadAllText(path);
                JsonObject root = Json.Parse(text) as JsonObject;
                if (root == null)
                {
                    return null;
                }

                int maximumAgeSeconds = Math.Max(20, pollSeconds + 15);
                string updatedAtText = Json.String(root.Get("updated_at"), "");
                DateTime updatedAt;
                if (!TryParseRoundtrip(updatedAtText, out updatedAt) ||
                    (DateTime.Now - updatedAt.ToLocalTime()).TotalSeconds > maximumAgeSeconds)
                {
                    return null;
                }

                int monitorPid = Json.Int(root.Get("monitor_pid"), 0);
                if (monitorPid <= 0 ||
                    !ProcessSnapshot.ProcessExistsInSession(monitorPid, Process.GetCurrentProcess().SessionId))
                {
                    return null;
                }

                RuntimeState state = new RuntimeState();
                state.Raw = root;
                state.UpdatedAt = updatedAt;
                state.State = Json.String(root.Get("state"), "");
                state.AccountState = Json.String(root.Get("account_state"), "");
                state.AccountMessage = Json.String(root.Get("account_message"), "");
                state.LastDecision = Json.String(root.Get("last_decision"), "");
                state.LastDecisionAt = Json.String(root.Get("last_decision_at"), "");
                state.PauseDeadlineAt = Json.String(root.Get("pause_deadline_at"), "");
                state.LaunchPending = Json.Bool(root.Get("launch_pending"), false);
                state.UnresolvedLaunch = Json.Bool(root.Get("unresolved_launch"), false);
                state.SessionConfirmed = Json.Bool(
                    root.Get("session_confirmed"),
                    Json.Bool(root.Get("association_confirmed"), false));
                state.RunningGames = Json.StringArray(root.Get("running_games"));
                state.TargetProcesses = Json.StringArray(root.Get("target_processes"));
                return state;
            }
            catch (Exception)
            {
                return null;
            }
        }

        public static bool TryParseRoundtrip(string text, out DateTime value)
        {
            return DateTime.TryParse(
                text,
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out value);
        }

        /// <summary>
        /// 监控脚本用 Set-Content -Encoding UTF8 原子替换，可能带 BOM；
        /// 这里统一按 UTF-8 读取并允许存在 BOM。
        /// </summary>
        internal static string ReadAllText(string path)
        {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                using (StreamReader reader = new StreamReader(stream, new UTF8Encoding(true), true))
                {
                    return reader.ReadToEnd();
                }
            }
        }
    }
}
