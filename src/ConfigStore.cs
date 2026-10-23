using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace LeigodAutoPause
{
    internal enum SettingKind
    {
        Bool,
        Int
    }

    /// <summary>
    /// 设置项的唯一清单：加载、保存、脏标记、事件订阅都遍历它。
    /// 新增一个设置项只需要三处：XAML 控件、这张表的一行、监控脚本 Read-MonitorConfig 的一行。
    /// </summary>
    internal sealed class SettingDescriptor
    {
        public SettingDescriptor(string key, string controlName, SettingKind kind, object defaultValue)
        {
            Key = key;
            ControlName = controlName;
            Kind = kind;
            DefaultValue = defaultValue;
        }

        public string Key { get; private set; }

        public string ControlName { get; private set; }

        public SettingKind Kind { get; private set; }

        public object DefaultValue { get; private set; }

        public static SettingDescriptor[] CreateDefault()
        {
            return new[]
            {
                new SettingDescriptor("auto_detect_launched_games", "AutoDetectGamesToggle", SettingKind.Bool, true),
                new SettingDescriptor("pause_if_client_closes", "PauseOnClientCloseToggle", SettingKind.Bool, true),
                new SettingDescriptor("notifications", "NotificationsToggle", SettingKind.Bool, true),
                new SettingDescriptor("pause_if_game_never_starts", "NeverStartedToggle", SettingKind.Bool, false),
                new SettingDescriptor("pause_stale_session_on_start", "StaleSessionToggle", SettingKind.Bool, false),
                new SettingDescriptor("exit_grace_seconds", "ExitGraceInput", SettingKind.Int, 120),
                new SettingDescriptor("startup_grace_seconds", "StartupGraceInput", SettingKind.Int, 300)
            };
        }
    }

    /// <summary>
    /// app\config.json 的读写。写回时以现有文档为底、只覆写界面负责的键，
    /// 这样用户手写的键或未来新增的键不会在点一次“保存”后被静默删掉。
    /// </summary>
    internal sealed class ConfigStore
    {
        private readonly string _configPath;
        private readonly string _examplePath;
        private readonly string _appDirectory;

        public ConfigStore(string configPath, string examplePath, string appDirectory)
        {
            _configPath = configPath;
            _examplePath = examplePath;
            _appDirectory = appDirectory;
            Document = null;
            GameNames = new List<string>();
        }

        public JsonObject Document { get; private set; }

        public List<string> GameNames { get; private set; }

        public string ConfigPath
        {
            get { return _configPath; }
        }

        /// <summary>首次运行时从示例配置创建本机专用配置，行为与 ConfigBootstrap.ps1 一致。</summary>
        public void EnsureExists()
        {
            if (File.Exists(_configPath))
            {
                return;
            }
            if (Directory.Exists(_configPath))
            {
                throw new InvalidOperationException("配置路径不是文件: " + _configPath);
            }

            string requested = Path.GetFullPath(_configPath);
            string expected = Path.GetFullPath(Path.Combine(_appDirectory, "config.json"));
            if (!string.Equals(requested, expected, StringComparison.OrdinalIgnoreCase))
            {
                throw new FileNotFoundException("找不到配置文件: " + _configPath);
            }
            if (!File.Exists(_examplePath))
            {
                throw new FileNotFoundException("找不到示例配置文件: " + _examplePath);
            }

            File.Copy(_examplePath, _configPath, false);
        }

        public void Load()
        {
            string text = RuntimeState.ReadAllText(_configPath);
            JsonObject parsed = Json.Parse(text) as JsonObject;
            if (parsed == null)
            {
                throw new FormatException("配置文件内容不是 JSON 对象: " + _configPath);
            }

            Document = parsed;
            GameNames.Clear();
            string[] configured = Json.StringArray(parsed.Get("game_processes"));
            for (int index = 0; index < configured.Length; index++)
            {
                string name = configured[index];
                if (!name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                {
                    name += ".exe";
                }
                GameNames.Add(name);
            }
        }

        public string GetString(string name, string defaultValue)
        {
            if (Document == null)
            {
                return defaultValue;
            }
            return Json.String(Document.Get(name), defaultValue);
        }

        public bool GetBool(string name, bool defaultValue)
        {
            if (Document == null)
            {
                return defaultValue;
            }
            return Json.Bool(Document.Get(name), defaultValue);
        }

        public int GetInt(string name, int defaultValue)
        {
            if (Document == null)
            {
                return defaultValue;
            }
            return Json.Int(Document.Get(name), defaultValue);
        }

        /// <summary>
        /// 生成待写入的配置文档：先原样复制现有键值，再覆写界面负责的键。
        /// 返回的顺序与 PowerShell 的 ordered 字典一致（已有键保持原位置，新键追加到末尾）。
        /// </summary>
        public JsonObject BuildSaveDocument(IList<KeyValuePair<string, object>> overrides)
        {
            JsonObject result = new JsonObject();
            if (Document != null)
            {
                for (int index = 0; index < Document.Keys.Count; index++)
                {
                    string key = Document.Keys[index];
                    result.Set(key, Document.Get(key));
                }
            }
            for (int index = 0; index < overrides.Count; index++)
            {
                result.Set(overrides[index].Key, overrides[index].Value);
            }
            return result;
        }

        public static void WriteJsonFile(string path, JsonObject document)
        {
            // Set-Content -Encoding UTF8 在 PowerShell 5.1 下写 BOM，这里保持一致，
            // 避免同一台机器上的配置在两种写路径间来回变化。
            string json = Json.Serialize(document, true);
            byte[] payload = new UTF8Encoding(true).GetBytes(json + Environment.NewLine);
            File.WriteAllBytes(path, payload);
        }
    }
}
