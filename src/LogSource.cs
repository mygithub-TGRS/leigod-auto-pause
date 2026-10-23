using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;

namespace LeigodAutoPause
{
    internal sealed class LogSnapshot
    {
        public string FileName { get; set; }

        public string[] Lines { get; set; }
    }

    /// <summary>
    /// 读取 app\logs 下最新的 monitor-*.log。
    /// 日志本身由监控脚本写，界面只做“最近 200 行 + 过滤 + 关键事件提取”。
    /// </summary>
    internal static class LogSource
    {
        private static readonly Regex LevelPattern = new Regex(@"\[(WARN|ERROR)\]", RegexOptions.CultureInvariant);
        private static readonly Regex StampPattern = new Regex(@"^\[([^\]]+)\]", RegexOptions.CultureInvariant);
        private static readonly Regex PrefixPattern = new Regex(@"^\[[^\]]+\]\s*\[(INFO|WARN|ERROR)\]\s*", RegexOptions.CultureInvariant);
        private static readonly Regex HighlightPattern = new Regex(
            "检测到游戏运行|游戏进程已退出|检测到游戏退出|暂停成功|暂停失败|客户端已关闭|收到停止标记|账号状态更新|账号状态无法确认|已按保留策略",
            RegexOptions.CultureInvariant);

        public static LogSnapshot Snapshot(string logDirectory, int count)
        {
            LogSnapshot snapshot = new LogSnapshot();
            snapshot.FileName = "";
            snapshot.Lines = new string[0];

            if (!Directory.Exists(logDirectory))
            {
                return snapshot;
            }

            string newest = null;
            DateTime newestAt = DateTime.MinValue;
            try
            {
                string[] files = Directory.GetFiles(logDirectory, "monitor-*.log");
                for (int index = 0; index < files.Length; index++)
                {
                    DateTime written = File.GetLastWriteTime(files[index]);
                    if (newest == null || written > newestAt)
                    {
                        newest = files[index];
                        newestAt = written;
                    }
                }
            }
            catch (Exception)
            {
                return snapshot;
            }

            if (newest == null)
            {
                return snapshot;
            }

            snapshot.FileName = Path.GetFileName(newest);

            string[] raw;
            try
            {
                using (FileStream stream = new FileStream(newest, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    using (StreamReader reader = new StreamReader(stream, new System.Text.UTF8Encoding(true), true))
                    {
                        List<string> all = new List<string>();
                        string line;
                        while ((line = reader.ReadLine()) != null)
                        {
                            all.Add(line);
                        }
                        raw = all.ToArray();
                    }
                }
            }
            catch (Exception)
            {
                return snapshot;
            }

            // 与 Get-Content -Tail 200 一致：先取最后 200 个物理行，再丢弃空白行。
            int start = Math.Max(0, raw.Length - count);
            List<string> lines = new List<string>();
            for (int index = start; index < raw.Length; index++)
            {
                if (!string.IsNullOrWhiteSpace(raw[index]))
                {
                    lines.Add(raw[index]);
                }
            }

            snapshot.Lines = lines.ToArray();
            return snapshot;
        }

        public static bool Matches(string line, string keyword, string levelFilter)
        {
            line = line ?? "";
            string level = "INFO";
            Match match = LevelPattern.Match(line);
            if (match.Success)
            {
                level = match.Groups[1].Value;
            }

            if (levelFilter == "仅提醒" && level != "WARN")
            {
                return false;
            }
            if (levelFilter == "仅错误" && level != "ERROR")
            {
                return false;
            }
            if (levelFilter == "仅决策" && line.IndexOf("[DECISION:", StringComparison.Ordinal) < 0)
            {
                return false;
            }

            if (!string.IsNullOrWhiteSpace(keyword) &&
                line.IndexOf(keyword, StringComparison.OrdinalIgnoreCase) < 0)
            {
                return false;
            }

            return true;
        }

        /// <summary>
        /// 从日志里挑出关键事件，去掉级别前缀只留时间和内容，比原样复读最后几行有用。
        /// </summary>
        public static string[] Highlights(string[] lines, int count)
        {
            List<string> picked = new List<string>();
            if (lines == null)
            {
                return picked.ToArray();
            }

            for (int index = lines.Length - 1; index >= 0 && picked.Count < count; index--)
            {
                string line = lines[index] ?? "";
                if (!HighlightPattern.IsMatch(line))
                {
                    continue;
                }

                string time = "";
                Match stamp = StampPattern.Match(line);
                if (stamp.Success)
                {
                    string value = stamp.Groups[1].Value;
                    if (value.Length >= 8)
                    {
                        time = value.Substring(value.Length - 8) + " ";
                    }
                }

                string body = PrefixPattern.Replace(line, "");
                picked.Add("· " + time + body);
            }

            return picked.ToArray();
        }

        /// <summary>
        /// 与 PowerShell 的 "{0:mm\:ss}" 对齐：取分钟/秒分量而不是总分钟数，
        /// 超过 1 小时时显示的是 1:05 这样的分秒，而不是 65 分钟。
        /// </summary>
        public static string FormatCountdown(TimeSpan remaining)
        {
            return string.Format(
                CultureInfo.InvariantCulture,
                "剩余 {0:00}:{1:00}",
                remaining.Minutes,
                remaining.Seconds);
        }
    }
}
