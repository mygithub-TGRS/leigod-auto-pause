using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Path = System.IO.Path;

namespace LeigodAutoPause
{
    internal sealed class GameListItem
    {
        public string Process { get; set; }

        public string Status { get; set; }
    }

    internal sealed class PanelOptions
    {
        public PanelOptions()
        {
            InitialPanel = "Overview";
            SnapshotPath = "";
            AutoCloseSeconds = 0;
        }

        public string InitialPanel { get; set; }

        public string SnapshotPath { get; set; }

        public int AutoCloseSeconds { get; set; }
    }

    /// <summary>
    /// 控制台窗口的全部绑定与刷新逻辑。
    /// 这是 app\LeigodAutoPause.UI.ps1 的逐条移植版：XAML 仍是同一份文件，
    /// 控件名、资源 key、状态文案、刷新节奏、失败处理都必须与原实现一致；
    /// 业务判定（进程、账号、暂停）继续由 app 目录下的 PowerShell 脚本负责。
    /// </summary>
    internal sealed class ControlPanel
    {
        private const string NewLine = "\r\n";

        private static readonly char[] InvalidNameChars = Path.GetInvalidFileNameChars();
        private static readonly Regex WildcardPattern = new Regex("[*?\\[\\]]", RegexOptions.CultureInvariant);

        private readonly AppPaths _paths;
        private readonly PanelOptions _options;
        private readonly StatusProbeService _probe = new StatusProbeService();

        private Window _window;
        private ConfigStore _config;
        private SettingDescriptor[] _descriptors;

        // ---- 概览 ----
        private Ellipse _headerStatusDot;
        private TextBlock _headerStatusText;
        private Button _refreshButton;
        private Button _openLeigodButton;
        private Ellipse _sidebarStatusDot;
        private TextBlock _sidebarStatusText;
        private CheckBox _autoStartToggle;
        private Ellipse _mainStatusDot;
        private TextBlock _mainStatusText;
        private TextBlock _mainStatusDetail;
        private TextBlock _verdictIcon;
        private TextBlock _verdictText;
        private TextBlock _freshnessText;
        private TextBlock _countdownText;
        private TextBlock _lastEventText;
        private TextBlock _lastDecisionText;
        private Button _monitorActionButton;
        private TextBlock _monitorActionIcon;
        private TextBlock _monitorActionText;
        private TextBlock _clientStatusText;
        private TextBlock _accountStatusText;
        private TextBlock _gameStatusText;
        private TextBlock _activityText;
        private TextBlock _graceSummaryText;
        private TextBlock _clientCloseRuleText;
        private TextBlock _gameCountText;
        private TextBlock _neverStartRuleText;
        private TextBlock _staleSessionRuleText;

        // ---- 规则设置 ----
        private TextBox _processInput;
        private Button _addProcessButton;
        private ListView _gameList;
        private TextBlock _gameEmptyText;
        private Button _removeProcessButton;
        private CheckBox _autoDetectGamesToggle;
        private Button _exitGraceMinusButton;
        private TextBox _exitGraceInput;
        private Button _exitGracePlusButton;
        private Button _startupGraceMinusButton;
        private TextBox _startupGraceInput;
        private Button _startupGracePlusButton;
        private CheckBox _pauseOnClientCloseToggle;
        private CheckBox _notificationsToggle;
        private CheckBox _neverStartedToggle;
        private CheckBox _staleSessionToggle;
        private TextBlock _settingsHintText;
        private Button _saveSettingsButton;

        // ---- 运行日志 ----
        private TextBlock _logSourceText;
        private TextBlock _logMatchCountText;
        private TextBox _logSearchInput;
        private ComboBox _logLevelCombo;
        private Button _logCopyButton;
        private Button _openLogFolderButton;
        private Button _refreshLogButton;
        private RichTextBox _logTextBox;

        // ---- 诊断 ----
        private TextBlock _diagSummaryText;
        private TextBlock _diagTokenText;
        private TextBlock _diagAccountText;
        private TextBlock _diagClientText;
        private TextBlock _diagGameText;
        private TextBlock _diagAdviceText;
        private Button _diagRunButton;
        private Button _diagCopyButton;

        // ---- 外壳 ----
        private Border _overviewNavHost;
        private Border _overviewIndicator;
        private Button _overviewNavButton;
        private Border _settingsNavHost;
        private Border _settingsIndicator;
        private Button _settingsNavButton;
        private Border _logsNavHost;
        private Border _logsIndicator;
        private Button _logsNavButton;
        private Border _diagNavHost;
        private Border _diagIndicator;
        private Button _diagNavButton;
        private Grid _overviewPanel;
        private Grid _settingsPanel;
        private Grid _logsPanel;
        private Grid _diagPanel;
        private TextBlock _footerMessageText;

        // ---- 运行状态 ----
        private bool _loadingConfig;
        private bool _suppressAutoStartEvents;
        private bool _autoStartPending;
        private bool _settingsDirty;
        private string _monitorInstanceState = "Unknown";
        private MonitorOperation _control;
        private bool _closeAfterControl;
        private DateTime _nextLocalRefreshAt = DateTime.MinValue;
        private DateTime _nextLogRefreshAt = DateTime.MinValue;
        private bool? _autoStartState;
        private DateTime _autoStartCheckedAt = DateTime.MinValue;
        private string _lastLogPlainText = "";
        private bool _statusProbeEnabled;
        private DispatcherTimer _uiTimer;

        public ControlPanel(AppPaths paths, Window window, PanelOptions options)
        {
            _paths = paths;
            _window = window;
            _options = options;
        }

        private bool SnapshotMode
        {
            get { return !string.IsNullOrEmpty(_options.SnapshotPath); }
        }

        /// <summary>快照模式渲染失败时为 true，进程用非零退出码告诉调用方。</summary>
        public bool SnapshotFailed { get; private set; }

        public void Initialize()
        {
            BindControls();
            VerifyResourceKeys();

            _config = new ConfigStore(_paths.ConfigPath, _paths.ConfigExamplePath, _paths.AppDirectory);
            _config.EnsureExists();
            _descriptors = SettingDescriptor.CreateDefault();
            _statusProbeEnabled = !SnapshotMode;

            WindowIcon();
            LoadConfiguration(false);
            SubscribeEvents();
            ShowPanel(_options.InitialPanel);
            UpdateLogView();
            UpdateLocalStatus();
            StartStatusProbe(false);

            _uiTimer = new DispatcherTimer();
            _uiTimer.Interval = TimeSpan.FromMilliseconds(750);
            _uiTimer.Tick += OnUiTick;
            _uiTimer.Start();

            if (SnapshotMode)
            {
                DispatcherTimer snapshotTimer = new DispatcherTimer();
                snapshotTimer.Interval = TimeSpan.FromSeconds(2);
                snapshotTimer.Tick += OnSnapshotTick;
                snapshotTimer.Start();
            }
            else if (_options.AutoCloseSeconds > 0)
            {
                DispatcherTimer closeTimer = new DispatcherTimer();
                closeTimer.Interval = TimeSpan.FromSeconds(_options.AutoCloseSeconds);
                closeTimer.Tick += OnCloseTick;
                closeTimer.Start();
            }
        }

        /// <summary>已打开的窗口收到第二次启动请求时，切换到指定面板并激活窗口。</summary>
        public void Activate(string panelName)
        {
            if (!string.IsNullOrEmpty(panelName))
            {
                ShowPanel(panelName);
            }
            if (_window.WindowState == WindowState.Minimized)
            {
                _window.WindowState = WindowState.Normal;
            }
            _window.Show();
            _window.Activate();
            _window.Topmost = true;
            _window.Topmost = false;
        }

        private void OnSnapshotTick(object sender, EventArgs args)
        {
            DispatcherTimer timer = sender as DispatcherTimer;
            if (timer != null)
            {
                timer.Stop();
            }
            try
            {
                RenderWindowSnapshot(_options.SnapshotPath);
            }
            catch (Exception exception)
            {
                // 快照模式是给文档和自动化用的：失败时只留痕并退出，
                // 不能弹模态对话框，否则无人值守的调用会一直卡在那里。
                SnapshotFailed = true;
                Diagnostics.LogProbe(_paths, "界面快照失败", _options.SnapshotPath, exception);
            }
            finally
            {
                _window.Close();
            }
        }

        private void OnCloseTick(object sender, EventArgs args)
        {
            DispatcherTimer timer = sender as DispatcherTimer;
            if (timer != null)
            {
                timer.Stop();
            }
            _window.Close();
        }

        private void OnUiTick(object sender, EventArgs args)
        {
            try
            {
                CompleteControlAction();
                CompleteStatusProbe();

                DateTime now = DateTime.Now;
                if (now >= _nextLocalRefreshAt)
                {
                    UpdateLocalStatus();
                    if (_diagPanel.Visibility == Visibility.Visible)
                    {
                        UpdateDiagView();
                    }
                    _nextLocalRefreshAt = now.AddSeconds(2);
                }

                if (now >= _nextLogRefreshAt)
                {
                    if (_logsPanel.Visibility == Visibility.Visible)
                    {
                        UpdateLogView();
                    }
                    _nextLogRefreshAt = now.AddSeconds(5);
                }

                StartStatusProbe(false);
            }
            catch (Exception exception)
            {
                SetFooterMessage("界面刷新失败: " + exception.Message);
            }
        }

        // ==================================================================
        // 控件与资源绑定
        // ==================================================================

        private void BindControls()
        {
            _headerStatusDot = Require<Ellipse>("HeaderStatusDot");
            _headerStatusText = Require<TextBlock>("HeaderStatusText");
            _refreshButton = Require<Button>("RefreshButton");
            _openLeigodButton = Require<Button>("OpenLeigodButton");
            _sidebarStatusDot = Require<Ellipse>("SidebarStatusDot");
            _sidebarStatusText = Require<TextBlock>("SidebarStatusText");
            _autoStartToggle = Require<CheckBox>("AutoStartToggle");

            _overviewNavHost = Require<Border>("OverviewNavHost");
            _overviewIndicator = Require<Border>("OverviewIndicator");
            _overviewNavButton = Require<Button>("OverviewNavButton");
            _settingsNavHost = Require<Border>("SettingsNavHost");
            _settingsIndicator = Require<Border>("SettingsIndicator");
            _settingsNavButton = Require<Button>("SettingsNavButton");
            _logsNavHost = Require<Border>("LogsNavHost");
            _logsIndicator = Require<Border>("LogsIndicator");
            _logsNavButton = Require<Button>("LogsNavButton");
            _diagNavHost = Require<Border>("DiagNavHost");
            _diagIndicator = Require<Border>("DiagIndicator");
            _diagNavButton = Require<Button>("DiagNavButton");

            _overviewPanel = Require<Grid>("OverviewPanel");
            _settingsPanel = Require<Grid>("SettingsPanel");
            _logsPanel = Require<Grid>("LogsPanel");
            _diagPanel = Require<Grid>("DiagPanel");

            _mainStatusDot = Require<Ellipse>("MainStatusDot");
            _mainStatusText = Require<TextBlock>("MainStatusText");
            _mainStatusDetail = Require<TextBlock>("MainStatusDetail");
            _lastEventText = Require<TextBlock>("LastEventText");
            _monitorActionButton = Require<Button>("MonitorActionButton");
            _monitorActionIcon = Require<TextBlock>("MonitorActionIcon");
            _monitorActionText = Require<TextBlock>("MonitorActionText");
            _clientStatusText = Require<TextBlock>("ClientStatusText");
            _accountStatusText = Require<TextBlock>("AccountStatusText");
            _gameStatusText = Require<TextBlock>("GameStatusText");
            _activityText = Require<TextBlock>("ActivityText");
            _graceSummaryText = Require<TextBlock>("GraceSummaryText");
            _clientCloseRuleText = Require<TextBlock>("ClientCloseRuleText");
            _gameCountText = Require<TextBlock>("GameCountText");
            _neverStartRuleText = Require<TextBlock>("NeverStartRuleText");
            _staleSessionRuleText = Require<TextBlock>("StaleSessionRuleText");

            _processInput = Require<TextBox>("ProcessInput");
            _addProcessButton = Require<Button>("AddProcessButton");
            _gameList = Require<ListView>("GameList");
            _gameEmptyText = Require<TextBlock>("GameEmptyText");
            _removeProcessButton = Require<Button>("RemoveProcessButton");
            _exitGraceInput = Require<TextBox>("ExitGraceInput");
            _exitGraceMinusButton = Require<Button>("ExitGraceMinusButton");
            _exitGracePlusButton = Require<Button>("ExitGracePlusButton");
            _startupGraceInput = Require<TextBox>("StartupGraceInput");
            _startupGraceMinusButton = Require<Button>("StartupGraceMinusButton");
            _startupGracePlusButton = Require<Button>("StartupGracePlusButton");
            _autoDetectGamesToggle = Require<CheckBox>("AutoDetectGamesToggle");
            _pauseOnClientCloseToggle = Require<CheckBox>("PauseOnClientCloseToggle");
            _notificationsToggle = Require<CheckBox>("NotificationsToggle");
            _neverStartedToggle = Require<CheckBox>("NeverStartedToggle");
            _staleSessionToggle = Require<CheckBox>("StaleSessionToggle");
            _settingsHintText = Require<TextBlock>("SettingsHintText");
            _saveSettingsButton = Require<Button>("SaveSettingsButton");
            _openLogFolderButton = Require<Button>("OpenLogFolderButton");
            _refreshLogButton = Require<Button>("RefreshLogButton");
            _logTextBox = Require<RichTextBox>("LogTextBox");
            _footerMessageText = Require<TextBlock>("FooterMessageText");

            _verdictText = Require<TextBlock>("VerdictText");
            _verdictIcon = Require<TextBlock>("VerdictIcon");
            _freshnessText = Require<TextBlock>("FreshnessText");
            _countdownText = Require<TextBlock>("CountdownText");
            _lastDecisionText = Require<TextBlock>("LastDecisionText");

            _logSourceText = Require<TextBlock>("LogSourceText");
            _logMatchCountText = Require<TextBlock>("LogMatchCountText");
            _logSearchInput = Require<TextBox>("LogSearchInput");
            _logLevelCombo = Require<ComboBox>("LogLevelCombo");
            _logCopyButton = Require<Button>("LogCopyButton");

            _diagRunButton = Require<Button>("DiagRunButton");
            _diagCopyButton = Require<Button>("DiagCopyButton");
            _diagSummaryText = Require<TextBlock>("DiagSummaryText");
            _diagTokenText = Require<TextBlock>("DiagTokenText");
            _diagAccountText = Require<TextBlock>("DiagAccountText");
            _diagClientText = Require<TextBlock>("DiagClientText");
            _diagGameText = Require<TextBlock>("DiagGameText");
            _diagAdviceText = Require<TextBlock>("DiagAdviceText");
        }

        private void VerifyResourceKeys()
        {
            string[] required =
            {
                "GreenBrush", "AmberBrush", "RedBrush", "MutedBrush", "WeakBrush",
                "TextBrush", "SurfaceStrongBrush", "PrimaryButtonStyle", "DangerButtonStyle"
            };

            List<string> missing = new List<string>();
            for (int index = 0; index < required.Length; index++)
            {
                if (_window.TryFindResource(required[index]) == null)
                {
                    missing.Add(required[index]);
                }
            }
            if (missing.Count > 0)
            {
                throw new InvalidOperationException("界面资源缺失: " + string.Join(", ", missing.ToArray()));
            }
        }

        private T Require<T>(string name) where T : class
        {
            object found = _window.FindName(name);
            if (found == null)
            {
                throw new InvalidOperationException("界面控件缺失: " + name);
            }
            T typed = found as T;
            if (typed == null)
            {
                throw new InvalidOperationException(
                    "界面控件类型不符: " + name + "（期望 " + typeof(T).Name + "）");
            }
            return typed;
        }

        private Brush Brush(string name)
        {
            object resource = _window.FindResource(name);
            Brush brush = resource as Brush;
            if (brush == null)
            {
                throw new InvalidOperationException("界面资源类型不符: " + name);
            }
            return brush;
        }

        private Style ResourceStyle(string name)
        {
            return _window.FindResource(name) as Style;
        }

        private void WindowIcon()
        {
            // 窗口图标：任务栏、Alt-Tab、标题栏都取这个；缺失时静默降级，不影响启动。
            if (!File.Exists(_paths.IconPath))
            {
                return;
            }
            try
            {
                _window.Icon = BitmapFrame.Create(new Uri(_paths.IconPath));
            }
            catch (Exception)
            {
            }
        }

        private void SetFooterMessage(string message)
        {
            _footerMessageText.Text = message;
        }

        // ==================================================================
        // 配置读写
        // ==================================================================

        private FrameworkElement SettingControl(SettingDescriptor descriptor)
        {
            switch (descriptor.ControlName)
            {
                case "AutoDetectGamesToggle":
                    return _autoDetectGamesToggle;
                case "PauseOnClientCloseToggle":
                    return _pauseOnClientCloseToggle;
                case "NotificationsToggle":
                    return _notificationsToggle;
                case "NeverStartedToggle":
                    return _neverStartedToggle;
                case "StaleSessionToggle":
                    return _staleSessionToggle;
                case "ExitGraceInput":
                    return _exitGraceInput;
                case "StartupGraceInput":
                    return _startupGraceInput;
                default:
                    throw new InvalidOperationException("未知的设置控件: " + descriptor.ControlName);
            }
        }

        private bool IsChecked(FrameworkElement control)
        {
            CheckBox box = control as CheckBox;
            return box != null && box.IsChecked == true;
        }

        private void LoadConfiguration(bool skipValidation)
        {
            if (!skipValidation)
            {
                ShellResult validation = ValidateConfig(_paths.ConfigPath);
                if (validation.ExitCode != 0)
                {
                    string detail = string.IsNullOrWhiteSpace(validation.Error) ? "" : "：" + validation.Error;
                    throw new InvalidOperationException("配置未通过监控器验证" + detail);
                }
            }

            _loadingConfig = true;
            try
            {
                _config.Load();
                for (int index = 0; index < _descriptors.Length; index++)
                {
                    SettingDescriptor descriptor = _descriptors[index];
                    FrameworkElement control = SettingControl(descriptor);
                    CheckBox box = control as CheckBox;
                    if (box != null)
                    {
                        box.IsChecked = Json.Bool(_config.Document.Get(descriptor.Key), (bool)descriptor.DefaultValue);
                        continue;
                    }
                    TextBox textBox = (TextBox)control;
                    textBox.Text = Json.String(_config.Document.Get(descriptor.Key), Convert.ToString(descriptor.DefaultValue, CultureInfo.InvariantCulture));
                }
                _settingsDirty = false;
                _settingsHintText.Text = "设置未修改";
            }
            finally
            {
                _loadingConfig = false;
            }

            UpdateGameList();
            UpdateRuleSummary();
        }

        private void SetSettingsDirty()
        {
            if (_loadingConfig)
            {
                return;
            }
            _settingsDirty = true;
            _settingsHintText.Text = "有未保存的修改";
            _settingsHintText.Foreground = Brush("AmberBrush");
        }

        private void SaveConfiguration()
        {
            int exitGrace;
            if (!int.TryParse(_exitGraceInput.Text.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out exitGrace) ||
                exitGrace < 10 || exitGrace > 3600)
            {
                throw new InvalidOperationException("游戏退出宽限必须是 10 到 3600 秒之间的整数。");
            }

            int startupGrace;
            if (!int.TryParse(_startupGraceInput.Text.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out startupGrace) ||
                startupGrace < 10 || startupGrace > 7200)
            {
                throw new InvalidOperationException("启动观察期必须是 10 到 7200 秒之间的整数。");
            }

            if (!IsChecked(_autoDetectGamesToggle) && _config.GameNames.Count == 0)
            {
                throw new InvalidOperationException("关闭自动识别时，至少需要一个手动补充进程。");
            }

            // 以现有配置为底，只覆写界面负责的键。否则用户在 config.json 里手写的键
            // 或未来新增的键，会在界面上点一次“保存”后被静默删掉。
            List<KeyValuePair<string, object>> overrides = new List<KeyValuePair<string, object>>();
            overrides.Add(new KeyValuePair<string, object>("game_processes", _config.GameNames.ToArray()));
            for (int index = 0; index < _descriptors.Length; index++)
            {
                SettingDescriptor descriptor = _descriptors[index];
                FrameworkElement control = SettingControl(descriptor);
                CheckBox box = control as CheckBox;
                if (box != null)
                {
                    overrides.Add(new KeyValuePair<string, object>(descriptor.Key, box.IsChecked == true));
                    continue;
                }

                int parsed;
                if (!int.TryParse(((TextBox)control).Text.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed))
                {
                    throw new InvalidOperationException(descriptor.Key + " 必须是整数。");
                }
                overrides.Add(new KeyValuePair<string, object>(descriptor.Key, (long)parsed));
            }

            JsonObject document = _config.BuildSaveDocument(overrides);
            string temporaryPath = _paths.ConfigPath + ".ui.tmp";
            try
            {
                ConfigStore.WriteJsonFile(temporaryPath, document);
                ShellResult validation = ValidateConfig(temporaryPath);
                if (validation.ExitCode != 0)
                {
                    string detail = string.IsNullOrWhiteSpace(validation.Error) ? "" : "：" + validation.Error;
                    throw new InvalidOperationException("新配置未通过监控器验证" + detail);
                }

                if (File.Exists(_paths.ConfigPath))
                {
                    File.Replace(temporaryPath, _paths.ConfigPath, null);
                }
                else
                {
                    File.Move(temporaryPath, _paths.ConfigPath);
                }
            }
            finally
            {
                if (File.Exists(temporaryPath))
                {
                    try
                    {
                        File.Delete(temporaryPath);
                    }
                    catch (Exception)
                    {
                    }
                }
            }

            LoadConfiguration(true);
            _settingsHintText.Text = "设置已保存";
            _settingsHintText.Foreground = Brush("GreenBrush");
        }

        /// <summary>
        /// 调用监控器做配置校验，并把 stderr 原文带回来——否则用户只能看到
        /// “未通过验证”这种没有信息量的结论。
        /// </summary>
        private ShellResult ValidateConfig(string path)
        {
            return ProcessJob.Run(
                _paths,
                _paths.MonitorScript,
                path,
                "-ConfigPath $env:LAP_CONFIG -ValidateConfig",
                120000);
        }

        // ==================================================================
        // 后台监控启停
        // ==================================================================

        private void StartControlAction(MonitorAction action)
        {
            if (_control != null)
            {
                SetFooterMessage("另一项控制操作正在进行。");
                return;
            }

            _control = MonitorOperation.Start(_paths, action);
            _monitorActionButton.IsEnabled = false;
            _saveSettingsButton.IsEnabled = false;
            SetFooterMessage(MonitorOperation.PendingMessage(action));
        }

        private void CompleteControlAction()
        {
            if (_control == null || !_control.IsFinished)
            {
                return;
            }

            MonitorOperation operation = _control;
            _control = null;
            int exitCode = operation.ExitCode;
            MonitorAction action = operation.Action;

            _monitorActionButton.IsEnabled = true;
            _saveSettingsButton.IsEnabled = true;

            if (exitCode == 0)
            {
                SetFooterMessage(MonitorOperation.SuccessMessage(action));
            }
            else
            {
                string detail = operation.FailureDetail();
                SetFooterMessage("控制操作失败: " + detail);
                MessageBox.Show(
                    OwnerWindow,
                    detail,
                    AppPaths.ApplicationName,
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }

            operation.Dispose();
            _nextLocalRefreshAt = DateTime.MinValue;
            _nextLogRefreshAt = DateTime.MinValue;

            if (_closeAfterControl)
            {
                _closeAfterControl = false;
                _window.Close();
            }
        }

        private Window OwnerWindow
        {
            get { return _window; }
        }

        private string GetMonitorInstanceState()
        {
            MutexHolder probe = MutexHolder.Probe(AppPaths.MonitorMutexName);
            return probe.State;
        }

        // ==================================================================
        // 账号状态探测
        // ==================================================================

        private void StartStatusProbe(bool force)
        {
            if (!_statusProbeEnabled)
            {
                return;
            }

            // 后台监控运行时，runtime-state.json 里已经带着 account_state，界面直接读即可；
            // 但状态文件过期（监控卡住或刚重启）时必须自己探测兜底，否则界面会一直显示旧值。
            if (!force && _monitorInstanceState == "Running")
            {
                RuntimeState live = GetCurrentRuntimeState();
                if (live != null)
                {
                    return;
                }
            }

            if (!_probe.CanStart(force))
            {
                return;
            }

            _probe.Start(_paths);
            _accountStatusText.Text = "正在检查";
            _accountStatusText.Foreground = Brush("MutedBrush");
        }

        private void CompleteStatusProbe()
        {
            bool succeeded;
            ProbeOutcome outcome = _probe.Poll(out succeeded);
            if (outcome == ProbeOutcome.TimedOut)
            {
                _accountStatusText.Text = "检查超时";
                _accountStatusText.Foreground = Brush("RedBrush");
                return;
            }
            if (outcome == ProbeOutcome.Completed)
            {
                UpdateLocalStatus();
            }
        }

        private RuntimeState GetCurrentRuntimeState()
        {
            int pollSeconds = _config != null ? _config.GetInt("poll_seconds", 2) : 2;
            return RuntimeState.Load(_paths.RuntimeStatePath, pollSeconds);
        }

        // ==================================================================
        // 日志
        // ==================================================================

        private void UpdateLogView()
        {
            LogSnapshot snapshot = LogSource.Snapshot(_paths.LogDirectory, 200);
            _logSourceText.Text = string.IsNullOrEmpty(snapshot.FileName)
                ? "暂无日志文件"
                : "来源: " + snapshot.FileName;

            string keyword = _logSearchInput.Text ?? "";
            string levelFilter = "";
            ComboBoxItem selectedItem = _logLevelCombo.SelectedItem as ComboBoxItem;
            if (selectedItem != null && selectedItem.Content != null)
            {
                levelFilter = Convert.ToString(selectedItem.Content, CultureInfo.InvariantCulture);
            }

            List<string> filtered = new List<string>();
            for (int index = 0; index < snapshot.Lines.Length; index++)
            {
                if (LogSource.Matches(snapshot.Lines[index], keyword, levelFilter))
                {
                    filtered.Add(snapshot.Lines[index]);
                }
            }

            _logMatchCountText.Text = filtered.Count != snapshot.Lines.Length
                ? string.Format(CultureInfo.InvariantCulture, "命中 {0} / {1} 行", filtered.Count, snapshot.Lines.Length)
                : "";

            if (filtered.Count == 0)
            {
                if (_lastLogPlainText != "暂无匹配的运行日志。")
                {
                    SetLogDocument(new[] { "暂无匹配的运行日志。" });
                    _lastLogPlainText = "暂无匹配的运行日志。";
                }
                _activityText.Text = "暂无活动记录";
                _lastEventText.Text = "暂无活动记录";
                return;
            }

            // 只有内容真的变了才重建文档：无条件重建会每 5 秒清掉滚动位置和选区，排障时没法看。
            string text = string.Join(Environment.NewLine, filtered.ToArray());
            if (_lastLogPlainText != text)
            {
                bool wasAtBottom = (_logTextBox.ExtentHeight - _logTextBox.VerticalOffset - _logTextBox.ViewportHeight) < 2;
                SetLogDocument(filtered.ToArray());
                _lastLogPlainText = text;
                if (wasAtBottom)
                {
                    _logTextBox.ScrollToEnd();
                }
            }

            string[] highlights = LogSource.Highlights(filtered.ToArray(), 3);
            _activityText.Text = highlights.Length > 0
                ? string.Join(NewLine, highlights)
                : "暂无活动记录";
            _lastEventText.Text = filtered[filtered.Count - 1];
        }

        /// <summary>把日志行渲染成带级别配色的 FlowDocument（RichTextBox 不支持 Text 属性）。</summary>
        private void SetLogDocument(string[] lines)
        {
            FlowDocument document = new FlowDocument();
            document.PagePadding = new Thickness(0);
            document.LineHeight = 18;
            document.FontFamily = new FontFamily("Consolas, Microsoft YaHei UI");
            document.FontSize = 12;

            Brush infoBrush = Brush("MutedBrush");
            Brush warnBrush = Brush("AmberBrush");
            Brush errorBrush = Brush("RedBrush");
            Brush okBrush = Brush("GreenBrush");

            for (int index = 0; index < lines.Length; index++)
            {
                string line = lines[index] ?? "";
                Paragraph paragraph = new Paragraph();
                paragraph.Margin = new Thickness(0);
                paragraph.LineHeight = 18;
                Run run = new Run(line);

                if (line.IndexOf("[ERROR]", StringComparison.Ordinal) >= 0 ||
                    line.IndexOf("DECISION:PAUSE_FAILED", StringComparison.Ordinal) >= 0)
                {
                    run.Foreground = errorBrush;
                }
                else if (line.IndexOf("[WARN]", StringComparison.Ordinal) >= 0)
                {
                    run.Foreground = warnBrush;
                }
                else if (line.IndexOf("DECISION:PAUSED", StringComparison.Ordinal) >= 0)
                {
                    run.Foreground = okBrush;
                }
                else if (line.IndexOf("[DECISION:", StringComparison.Ordinal) >= 0)
                {
                    run.Foreground = warnBrush;
                }
                else
                {
                    run.Foreground = infoBrush;
                }

                paragraph.Inlines.Add(run);
                document.Blocks.Add(paragraph);
            }

            _logTextBox.Document = document;
        }

        // ==================================================================
        // 概览状态
        // ==================================================================

        private void UpdateLocalStatus()
        {
            _monitorInstanceState = GetMonitorInstanceState();
            bool clientRunning = ProcessSnapshot.IsRunningExact("leigod.exe");
            RuntimeState runtimeState = GetCurrentRuntimeState();
            bool autoDetectionEnabled = _config.GetBool("auto_detect_launched_games", true);

            List<string> runningGames = new List<string>();
            for (int index = 0; index < _config.GameNames.Count; index++)
            {
                string name = _config.GameNames[index];
                if (ProcessSnapshot.IsRunningExact(name))
                {
                    runningGames.Add(name);
                }
            }

            string[] targetProcesses = _config.GameNames.ToArray();
            bool launchPending = false;
            bool unresolvedLaunch = false;
            string runtimeMonitorState = "";
            string runtimeAccountState = "";

            if (runtimeState != null)
            {
                runningGames.Clear();
                runningGames.AddRange(runtimeState.RunningGames);
                targetProcesses = runtimeState.TargetProcesses;
                launchPending = runtimeState.LaunchPending;
                unresolvedLaunch = runtimeState.UnresolvedLaunch;
                runtimeMonitorState = runtimeState.State;
                runtimeAccountState = runtimeState.AccountState;
            }

            bool gameRunning = runningGames.Count > 0;

            Brush statusBrush;
            if (_monitorInstanceState == "Running")
            {
                statusBrush = Brush("GreenBrush");
                _headerStatusText.Text = "后台运行中";
                _sidebarStatusText.Text = "运行中";
                _monitorActionButton.Style = ResourceStyle("DangerButtonStyle");
                _monitorActionIcon.Text = ((char)0xE71A).ToString();
                _monitorActionText.Text = "停止监控";

                if (runtimeMonitorState == "GameStarting" || launchPending)
                {
                    _mainStatusText.Text = "游戏正在启动";
                    if (unresolvedLaunch)
                    {
                        _mainStatusDetail.Text = "当前启动事件未提供可用进程名";
                    }
                    else if (targetProcesses.Length > 0)
                    {
                        _mainStatusDetail.Text = "等待 " + string.Join(", ", targetProcesses);
                    }
                    else
                    {
                        _mainStatusDetail.Text = "等待雷神提供目标进程";
                    }
                }
                else if (gameRunning)
                {
                    _mainStatusText.Text = "游戏运行中";
                    _mainStatusDetail.Text = "正在监测 " + string.Join(", ", runningGames.ToArray());
                }
                else if (runtimeMonitorState == "AfterGameExit" ||
                         runtimeMonitorState == "AfterClientExit" ||
                         runtimeMonitorState == "WaitingForGame" ||
                         runtimeMonitorState == "StaleSession")
                {
                    switch (runtimeMonitorState)
                    {
                        case "AfterGameExit":
                            _mainStatusText.Text = "游戏已退出，等待复核";
                            _mainStatusDetail.Text = "宽限期结束后将再次检查游戏与账号状态";
                            break;
                        case "AfterClientExit":
                            _mainStatusText.Text = "客户端已关闭，等待复核";
                            _mainStatusDetail.Text = "宽限期结束后将再次检查客户端、游戏与账号状态";
                            break;
                        case "WaitingForGame":
                            _mainStatusText.Text = "等待目标游戏启动";
                            _mainStatusDetail.Text = "启动观察期结束后将进行安全复核";
                            break;
                        default:
                            _mainStatusText.Text = "等待遗留会话复核";
                            _mainStatusDetail.Text = "观察期结束后将重新确认客户端、游戏与账号状态";
                            break;
                    }
                }
                else if (unresolvedLaunch)
                {
                    _mainStatusText.Text = "目标游戏无法确认";
                    _mainStatusDetail.Text = "当前雷神启动事件没有可用进程名";
                }
                else
                {
                    _mainStatusText.Text = autoDetectionEnabled ? "等待雷神启动游戏" : "等待手动目标游戏";
                    _mainStatusDetail.Text = autoDetectionEnabled ? "正在监听新的游戏启动事件" : "正在监测已配置的游戏进程";
                }
            }
            else if (_monitorInstanceState == "Stopped")
            {
                statusBrush = Brush("WeakBrush");
                _headerStatusText.Text = "后台已停止";
                _sidebarStatusText.Text = "已停止";
                _mainStatusText.Text = "监控已停止";
                _mainStatusDetail.Text = "当前不会自动暂停雷神时长";
                _monitorActionButton.Style = ResourceStyle("PrimaryButtonStyle");
                _monitorActionIcon.Text = ((char)0xE768).ToString();
                _monitorActionText.Text = "启动监控";
            }
            else
            {
                statusBrush = Brush("RedBrush");
                _headerStatusText.Text = "状态未知";
                _sidebarStatusText.Text = "无法确认";
                _mainStatusText.Text = "无法确认监控状态";
                _mainStatusDetail.Text = "已阻止重复控制操作";
                _monitorActionButton.Style = ResourceStyle("PrimaryButtonStyle");
                _monitorActionIcon.Text = ((char)0xE72C).ToString();
                _monitorActionText.Text = "重新检查";
            }

            _headerStatusDot.Fill = statusBrush;
            _sidebarStatusDot.Fill = statusBrush;
            _mainStatusDot.Fill = statusBrush;

            _clientStatusText.Text = clientRunning ? "运行中" : "未运行";
            _clientStatusText.Foreground = clientRunning ? Brush("GreenBrush") : Brush("MutedBrush");

            if (gameRunning)
            {
                _gameStatusText.Text = string.Join(", ", runningGames.ToArray());
            }
            else if (launchPending)
            {
                _gameStatusText.Text = "启动中";
            }
            else if (unresolvedLaunch)
            {
                _gameStatusText.Text = "无法识别";
            }
            else
            {
                _gameStatusText.Text = "未检测到";
            }
            _gameStatusText.Foreground = gameRunning
                ? Brush("GreenBrush")
                : (launchPending || unresolvedLaunch ? Brush("AmberBrush") : Brush("MutedBrush"));

            string accountDisplayState = runtimeAccountState;
            if (string.IsNullOrWhiteSpace(accountDisplayState) && _probe.LastProbe != null)
            {
                accountDisplayState = Json.String(_probe.LastProbe.Get("AccountState"), "");
            }
            switch (accountDisplayState)
            {
                case "Active":
                    _accountStatusText.Text = "正在计时";
                    _accountStatusText.Foreground = Brush("AmberBrush");
                    break;
                case "Paused":
                    _accountStatusText.Text = "已暂停";
                    _accountStatusText.Foreground = Brush("GreenBrush");
                    break;
                case "Unknown":
                    _accountStatusText.Text = "无法确认";
                    _accountStatusText.Foreground = Brush("RedBrush");
                    break;
                default:
                    _accountStatusText.Text = _probe.IsRunning ? "正在确认" : "尚未确认";
                    _accountStatusText.Foreground = Brush("RedBrush");
                    break;
            }

            // ---- 结论条：一句话回答“我现在安全吗” ----
            bool sessionConfirmed = false;
            string pauseDeadlineText = "";
            string lastDecisionCode = "";
            string runtimeAccountMessage = "";
            if (runtimeState != null)
            {
                sessionConfirmed = runtimeState.SessionConfirmed;
                pauseDeadlineText = runtimeState.PauseDeadlineAt;
                lastDecisionCode = runtimeState.LastDecision;
                runtimeAccountMessage = runtimeState.AccountMessage;
            }

            string verdictLabel;
            string verdictBrushName;
            char verdictGlyph;
            if (_monitorInstanceState != "Running")
            {
                verdictLabel = "后台监控未运行，不会自动暂停";
                verdictBrushName = "WeakBrush";
                verdictGlyph = (char)0xEA39;
            }
            else if (runtimeAccountState == "Paused")
            {
                verdictLabel = "已暂停，安全";
                verdictBrushName = "GreenBrush";
                verdictGlyph = (char)0xE73E;
            }
            else if (gameRunning && runtimeAccountState == "Active" && sessionConfirmed)
            {
                verdictLabel = "计时中，游戏退出后将自动暂停";
                verdictBrushName = "AmberBrush";
                verdictGlyph = (char)0xE7BA;
            }
            else if (runtimeAccountState == "Active")
            {
                verdictLabel = "账号在计时，但本次会话尚未确认；退出后不会自动暂停";
                verdictBrushName = "AmberBrush";
                verdictGlyph = (char)0xE7BA;
            }
            else
            {
                verdictLabel = "账号状态无法确认";
                verdictBrushName = "RedBrush";
                verdictGlyph = (char)0xEA39;
            }

            _verdictIcon.Text = verdictGlyph.ToString();
            _verdictText.Text = verdictLabel;
            _verdictText.Foreground = Brush(verdictBrushName);
            _lastDecisionText.Text = string.IsNullOrEmpty(lastDecisionCode) ? "" : "最近结论: " + lastDecisionCode;

            // 数据新鲜度：监控卡住时界面不能假装一切正常
            string freshnessLabel = "";
            if (runtimeState != null)
            {
                int ageSeconds = (int)Math.Max(0, (DateTime.Now - runtimeState.UpdatedAt.ToLocalTime()).TotalSeconds);
                freshnessLabel = "状态更新于 " + ageSeconds + " 秒前";
            }
            _freshnessText.Text = freshnessLabel;

            // 倒计时只在四个倒计时状态出现
            _countdownText.Visibility = Visibility.Collapsed;
            if (!string.IsNullOrWhiteSpace(pauseDeadlineText))
            {
                DateTime deadline;
                if (RuntimeState.TryParseRoundtrip(pauseDeadlineText, out deadline))
                {
                    double remainingSeconds = Math.Ceiling((deadline.ToLocalTime() - DateTime.Now).TotalSeconds);
                    if (remainingSeconds > 0)
                    {
                        _countdownText.Text = LogSource.FormatCountdown(TimeSpan.FromSeconds(remainingSeconds));
                        _countdownText.Visibility = Visibility.Visible;
                    }
                }
            }

            // 账号状态无法确认时，直接给出原因（凭据失效 / HTTP 超时），而不是只说“无法确认”
            if (runtimeAccountState == "Unknown" && !string.IsNullOrWhiteSpace(runtimeAccountMessage))
            {
                _accountStatusText.Text = "无法确认：" + runtimeAccountMessage;
            }

            // 开机自启状态原来每 2 秒新建一次 WScript.Shell COM 对象并读快捷方式，缓存 10 秒即可。
            if (!_autoStartState.HasValue ||
                (DateTime.Now - _autoStartCheckedAt).TotalSeconds >= 10)
            {
                _autoStartState = AutoStartService.IsEnabled(_paths);
                _autoStartCheckedAt = DateTime.Now;
            }
            _suppressAutoStartEvents = true;
            try
            {
                _autoStartToggle.IsChecked = _autoStartState.Value;
            }
            finally
            {
                _suppressAutoStartEvents = false;
            }

            UpdateGameList();
            UpdateRuleSummary();
        }

        private void UpdateGameList()
        {
            string selectedProcess = null;
            GameListItem selected = _gameList.SelectedItem as GameListItem;
            if (selected != null)
            {
                selectedProcess = selected.Process;
            }

            _gameList.Items.Clear();
            for (int index = 0; index < _config.GameNames.Count; index++)
            {
                string name = _config.GameNames[index];
                GameListItem item = new GameListItem();
                item.Process = name;
                item.Status = ProcessSnapshot.IsRunningExact(name) ? "运行中" : "未运行";
                _gameList.Items.Add(item);
                if (!string.IsNullOrEmpty(selectedProcess) &&
                    string.Equals(selectedProcess, name, StringComparison.OrdinalIgnoreCase))
                {
                    _gameList.SelectedItem = item;
                }
            }

            _gameEmptyText.Visibility = _config.GameNames.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        private void UpdateRuleSummary()
        {
            int exitGrace = 120;
            if (!int.TryParse(_exitGraceInput.Text.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out exitGrace))
            {
                exitGrace = 120;
            }
            _graceSummaryText.Text = exitGrace + " 秒";
            _clientCloseRuleText.Text = IsChecked(_pauseOnClientCloseToggle) ? "启用" : "关闭";
            _gameCountText.Text = IsChecked(_autoDetectGamesToggle)
                ? "自动 + " + _config.GameNames.Count + " 个"
                : "仅 " + _config.GameNames.Count + " 个";
            _neverStartRuleText.Text = IsChecked(_neverStartedToggle) ? "启用" : "关闭";
            _staleSessionRuleText.Text = IsChecked(_staleSessionToggle) ? "启用" : "关闭";
        }

        // ==================================================================
        // 诊断
        // ==================================================================

        private void UpdateDiagView()
        {
            JsonObject probe = _probe.LastProbe;
            if (probe == null)
            {
                _diagSummaryText.Text = "还没有诊断结果。点击「运行诊断」读取本机状态（只读，不会发送暂停请求）。";
                _diagTokenText.Text = "—";
                _diagAccountText.Text = "—";
                _diagClientText.Text = "—";
                _diagGameText.Text = "—";
                _diagAdviceText.Text = "诊断只读取四件事：登录凭据是否存在、账号是否在计时、雷神客户端是否在运行、目标游戏是否已识别。";
                return;
            }

            bool tokenFound = Json.Bool(probe.Get("TokenFound"), false);
            string accountState = Json.String(probe.Get("AccountState"), "Unknown");
            string accountMessage = Json.String(probe.Get("AccountStateMessage"), "");
            bool clientRunning = Json.Bool(probe.Get("LeigodRunning"), false);
            int configuredCount = Json.Int(probe.Get("ConfiguredGameCount"), 0);
            int detectedCount = Json.Int(probe.Get("DetectedGameCount"), 0);
            int targetCount = Json.Int(probe.Get("TargetGameCount"), 0);
            int runningCount = Json.Int(probe.Get("RunningGameCount"), 0);
            bool autoDetect = Json.Bool(probe.Get("AutoDetectionEnabled"), false);

            _diagSummaryText.Text = string.Format(
                CultureInfo.InvariantCulture,
                "监控: {0}；自动识别: {1}",
                _monitorInstanceState,
                autoDetect ? "启用" : "关闭");
            _diagTokenText.Text = tokenFound
                ? "已找到（来自雷神客户端日志，不会写入本项目）"
                : "未找到，请先登录雷神客户端";
            _diagAccountText.Text = string.IsNullOrWhiteSpace(accountMessage)
                ? accountState
                : accountState + "（" + accountMessage + "）";
            _diagClientText.Text = clientRunning ? "运行中" : "未运行";
            _diagGameText.Text = string.Format(
                CultureInfo.InvariantCulture,
                "手动 {0} 个 · 自动识别 {1} 个 · 目标合计 {2} 个 · 正在运行 {3} 个",
                configuredCount,
                detectedCount,
                targetCount,
                runningCount);

            List<string> advice = new List<string>();
            if (!tokenFound)
            {
                advice.Add("· 没有找到登录凭据：先登录雷神客户端，再运行一次诊断。");
            }
            if (!clientRunning && autoDetect)
            {
                advice.Add("· 客户端未运行：自动识别依赖客户端日志，未打开客户端时不会自动暂停。");
            }
            if (targetCount == 0)
            {
                advice.Add("· 没有任何目标游戏：打开自动识别，或在规则设置里补充进程名。");
            }
            if (accountState != "Active" && accountState != "Paused")
            {
                advice.Add("· 账号状态不是 Active/Paused：暂停请求会被拒绝，先确认客户端里已登录并正常计时。");
            }
            if (advice.Count == 0)
            {
                advice.Add("· 检查通过：监控运行时会按规则在游戏退出后复核并暂停。");
            }
            if (_monitorInstanceState != "Running")
            {
                advice.Add("· 后台监控当前未运行，任何规则都不会生效。");
            }
            _diagAdviceText.Text = string.Join(NewLine, advice.ToArray());
        }

        private string GetDiagReportText()
        {
            string[] lines =
            {
                "雷神自动暂停 排障报告",
                "时间: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture),
                "监控: " + _monitorInstanceState,
                "登录凭据: " + _diagTokenText.Text,
                "账号时长: " + _diagAccountText.Text,
                "雷神客户端: " + _diagClientText.Text,
                "目标游戏: " + _diagGameText.Text,
                "建议: " + Regex.Replace(_diagAdviceText.Text ?? "", "\\r?\\n", " ")
            };
            return string.Join(NewLine, lines);
        }

        // ==================================================================
        // 面板切换 / 列表编辑
        // ==================================================================

        private void ShowPanel(string name)
        {
            _overviewPanel.Visibility = name == "Overview" ? Visibility.Visible : Visibility.Collapsed;
            _settingsPanel.Visibility = name == "Settings" ? Visibility.Visible : Visibility.Collapsed;
            _logsPanel.Visibility = name == "Logs" ? Visibility.Visible : Visibility.Collapsed;
            _diagPanel.Visibility = name == "Diag" ? Visibility.Visible : Visibility.Collapsed;

            ApplyNavState("Overview", _overviewNavHost, _overviewIndicator, _overviewNavButton, name);
            ApplyNavState("Settings", _settingsNavHost, _settingsIndicator, _settingsNavButton, name);
            ApplyNavState("Logs", _logsNavHost, _logsIndicator, _logsNavButton, name);
            ApplyNavState("Diag", _diagNavHost, _diagIndicator, _diagNavButton, name);

            if (name == "Logs")
            {
                UpdateLogView();
            }
        }

        private void ApplyNavState(string entryName, Border host, Border indicator, Button button, string selectedName)
        {
            bool isSelected = entryName == selectedName;
            host.Background = isSelected ? Brush("SurfaceStrongBrush") : Brushes.Transparent;
            indicator.Visibility = isSelected ? Visibility.Visible : Visibility.Collapsed;
            button.Foreground = isSelected ? Brush("TextBrush") : Brush("MutedBrush");
        }

        private void AddConfiguredProcess()
        {
            string name = (_processInput.Text ?? "").Trim();
            if (string.IsNullOrWhiteSpace(name))
            {
                return;
            }
            if (!string.Equals(Path.GetFileName(name), name, StringComparison.OrdinalIgnoreCase) ||
                name.IndexOfAny(InvalidNameChars) >= 0 ||
                WildcardPattern.IsMatch(name))
            {
                throw new InvalidOperationException("请输入不含路径或通配符的完整 exe 进程名。");
            }
            if (!name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            {
                name += ".exe";
            }
            for (int index = 0; index < _config.GameNames.Count; index++)
            {
                if (string.Equals(_config.GameNames[index], name, StringComparison.OrdinalIgnoreCase))
                {
                    _processInput.Clear();
                    return;
                }
            }

            _config.GameNames.Add(name);
            _processInput.Clear();
            SetSettingsDirty();
            UpdateGameList();
            UpdateRuleSummary();
        }

        private void AdjustNumberInput(TextBox textBox, int delta, int minimum, int maximum)
        {
            int value;
            if (!int.TryParse((textBox.Text ?? "").Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out value))
            {
                value = 0;
            }
            textBox.Text = Math.Max(minimum, Math.Min(maximum, value + delta)).ToString(CultureInfo.InvariantCulture);
            SetSettingsDirty();
        }

        private void RenderWindowSnapshot(string path)
        {
            string directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(directory) && !Directory.Exists(directory))
            {
                Directory.CreateDirectory(directory);
            }

            FrameworkElement visual = (FrameworkElement)_window.Content;
            int width = Math.Max(1, (int)Math.Ceiling(visual.ActualWidth));
            int height = Math.Max(1, (int)Math.Ceiling(visual.ActualHeight));
            RenderTargetBitmap bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(visual);
            PngBitmapEncoder encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (FileStream stream = new FileStream(path, FileMode.Create, FileAccess.Write))
            {
                encoder.Save(stream);
            }
        }

        // ==================================================================
        // 事件绑定
        // ==================================================================

        private void SubscribeEvents()
        {
            _overviewNavButton.Click += delegate { ShowPanel("Overview"); };
            _settingsNavButton.Click += delegate { ShowPanel("Settings"); };
            _logsNavButton.Click += delegate { ShowPanel("Logs"); };
            _diagNavButton.Click += delegate { ShowPanel("Diag"); };

            _diagRunButton.Click += delegate
            {
                _probe.Reset();
                StartStatusProbe(true);
                SetFooterMessage("正在运行诊断...");
            };

            _diagCopyButton.Click += delegate
            {
                try
                {
                    Clipboard.SetText(GetDiagReportText());
                    SetFooterMessage("排障报告已复制。");
                }
                catch (Exception)
                {
                    SetFooterMessage("复制失败，可手动选择文本复制。");
                }
            };

            _monitorActionButton.Click += delegate
            {
                string state = GetMonitorInstanceState();
                if (state == "Running")
                {
                    StartControlAction(MonitorAction.Stop);
                }
                else if (state == "Stopped")
                {
                    StartControlAction(MonitorAction.Start);
                }
                else
                {
                    _nextLocalRefreshAt = DateTime.MinValue;
                }
            };

            _refreshButton.Click += delegate
            {
                _nextLocalRefreshAt = DateTime.MinValue;
                _nextLogRefreshAt = DateTime.MinValue;
                _probe.Reset();
                StartStatusProbe(false);
                SetFooterMessage("正在刷新状态...");
            };

            _openLeigodButton.Click += delegate { OpenLeigod(); };

            _autoStartToggle.Checked += delegate { SetAutoStart(true); };
            _autoStartToggle.Unchecked += delegate { SetAutoStart(false); };

            _addProcessButton.Click += delegate { Guarded(AddConfiguredProcess, "游戏进程", MessageBoxImage.Warning); };
            _processInput.KeyDown += delegate(object sender, System.Windows.Input.KeyEventArgs args)
            {
                if (args.Key == System.Windows.Input.Key.Enter)
                {
                    Guarded(AddConfiguredProcess, "游戏进程", MessageBoxImage.Warning);
                    args.Handled = true;
                }
            };

            _removeProcessButton.Click += delegate
            {
                GameListItem selected = _gameList.SelectedItem as GameListItem;
                if (selected == null)
                {
                    return;
                }
                for (int index = _config.GameNames.Count - 1; index >= 0; index--)
                {
                    if (string.Equals(_config.GameNames[index], selected.Process, StringComparison.OrdinalIgnoreCase))
                    {
                        _config.GameNames.RemoveAt(index);
                    }
                }
                SetSettingsDirty();
                UpdateGameList();
                UpdateRuleSummary();
            };

            // 步长必须让默认值可达：min=10、步长 30 时 120/300 都永远点不到。
            _exitGraceMinusButton.Click += delegate { AdjustNumberInput(_exitGraceInput, -10, 10, 3600); };
            _exitGracePlusButton.Click += delegate { AdjustNumberInput(_exitGraceInput, 10, 10, 3600); };
            _startupGraceMinusButton.Click += delegate { AdjustNumberInput(_startupGraceInput, -10, 10, 7200); };
            _startupGracePlusButton.Click += delegate { AdjustNumberInput(_startupGraceInput, 10, 10, 7200); };

            for (int index = 0; index < _descriptors.Length; index++)
            {
                SettingDescriptor descriptor = _descriptors[index];
                FrameworkElement control = SettingControl(descriptor);
                CheckBox box = control as CheckBox;
                if (box != null)
                {
                    box.Checked += delegate
                    {
                        SetSettingsDirty();
                        UpdateRuleSummary();
                    };
                    box.Unchecked += delegate
                    {
                        SetSettingsDirty();
                        UpdateRuleSummary();
                    };
                }
                else
                {
                    ((TextBox)control).TextChanged += delegate
                    {
                        SetSettingsDirty();
                        UpdateRuleSummary();
                    };
                }
            }

            _saveSettingsButton.Click += delegate { SaveSettings(); };
            _refreshLogButton.Click += delegate
            {
                UpdateLogView();
                SetFooterMessage("日志已刷新。");
            };
            _logSearchInput.TextChanged += delegate { UpdateLogView(); };
            _logLevelCombo.SelectionChanged += delegate { UpdateLogView(); };
            _logCopyButton.Click += delegate
            {
                try
                {
                    Clipboard.SetText(_lastLogPlainText ?? "");
                    SetFooterMessage("已复制当前日志视图。");
                }
                catch (Exception)
                {
                    SetFooterMessage("复制失败，可改用鼠标选中后 Ctrl+C。");
                }
            };
            _openLogFolderButton.Click += delegate
            {
                if (!Directory.Exists(_paths.LogDirectory))
                {
                    Directory.CreateDirectory(_paths.LogDirectory);
                }
                System.Diagnostics.Process.Start("explorer.exe", AppPaths.QuoteArgument(_paths.LogDirectory));
            };

            _window.Closing += OnWindowClosing;
            _window.Closed += OnWindowClosed;
        }

        private void SetAutoStart(bool enabled)
        {
            if (_suppressAutoStartEvents || _autoStartPending)
            {
                return;
            }

            // 这个操作要起一个 PowerShell 进程并做 ACL 校验，可能耗时数百毫秒到数秒。
            // 放到线程池执行，界面在等待期间必须保持可响应（否则整窗会假死）。
            _autoStartPending = true;
            SetFooterMessage(enabled ? "正在启用开机自启..." : "正在关闭开机自启...");

            ThreadPool.QueueUserWorkItem(delegate
            {
                string failure = null;
                try
                {
                    AutoStartService.SetEnabled(_paths, enabled);
                }
                catch (Exception exception)
                {
                    failure = exception.Message;
                }

                Application.Current.Dispatcher.BeginInvoke(
                    new Action(delegate { OnAutoStartCompleted(enabled, failure); }));
            });
        }

        private void OnAutoStartCompleted(bool enabled, string failure)
        {
            _autoStartPending = false;
            _autoStartCheckedAt = DateTime.MinValue;

            if (failure == null)
            {
                _autoStartState = enabled;
                _autoStartCheckedAt = DateTime.Now;
                SetFooterMessage(enabled ? "已启用开机自启。" : "已关闭开机自启；当前监控不受影响。");
                return;
            }

            // 失败时把开关拨回真实状态，不能停在一个骗人的勾上。
            _autoStartState = null;
            SetFooterMessage("开机自启设置失败: " + failure);
            _suppressAutoStartEvents = true;
            try
            {
                _autoStartToggle.IsChecked = AutoStartService.IsEnabled(_paths);
            }
            catch (Exception)
            {
            }
            finally
            {
                _suppressAutoStartEvents = false;
            }

            MessageBox.Show(
                OwnerWindow,
                failure,
                "开机自启",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
        private void SaveSettings()
        {
            try
            {
                bool wasRunning = GetMonitorInstanceState() == "Running";
                SaveConfiguration();
                if (wasRunning)
                {
                    StartControlAction(MonitorAction.Restart);
                }
                else
                {
                    _settingsHintText.Text = "已保存，待下次启动监控生效";
                    _settingsHintText.Foreground = Brush("AmberBrush");
                    SetFooterMessage("设置已保存，将在下次启动监控时生效。");
                }
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    OwnerWindow,
                    exception.Message,
                    "设置未保存",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        private void OpenLeigod()
        {
            try
            {
                string executable = _config.GetString("leigod_executable", "");
                string shortcut = _config.GetString("leigod_shortcut", "");
                string launchTarget = LeigodLocator.Resolve(executable, shortcut);
                if (string.IsNullOrWhiteSpace(launchTarget))
                {
                    throw new InvalidOperationException("无法定位本机 leigod.exe，请检查 app\\config.json。");
                }
                System.Diagnostics.Process.Start(launchTarget);
                SetFooterMessage("已打开雷神加速器。");
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    OwnerWindow,
                    exception.Message,
                    "无法打开雷神",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
        }

        private void Guarded(Action action, string title, MessageBoxImage icon)
        {
            try
            {
                action();
            }
            catch (Exception exception)
            {
                MessageBox.Show(OwnerWindow, exception.Message, title, MessageBoxButton.OK, icon);
            }
        }

        private void OnWindowClosing(object sender, System.ComponentModel.CancelEventArgs args)
        {
            if (_control != null)
            {
                if (!_control.IsFinished)
                {
                    args.Cancel = true;
                    _closeAfterControl = true;
                    SetFooterMessage("控制操作完成后将自动关闭控制台。");
                    return;
                }
                CompleteControlAction();
            }

            if (_settingsDirty)
            {
                MessageBoxResult choice = MessageBox.Show(
                    OwnerWindow,
                    "规则设置有未保存的修改。是否放弃修改并关闭？",
                    AppPaths.ApplicationName,
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Warning);
                if (choice != MessageBoxResult.Yes)
                {
                    args.Cancel = true;
                }
            }
        }

        private void OnWindowClosed(object sender, EventArgs args)
        {
            if (_uiTimer != null)
            {
                _uiTimer.Stop();
            }
            _probe.Dispose();
            if (_control != null)
            {
                _control.Dispose();
                _control = null;
            }
        }
    }
}
