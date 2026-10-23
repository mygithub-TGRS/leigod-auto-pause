[CmdletBinding()]
param(
    [ValidateScript({
        if ([string]::IsNullOrWhiteSpace($_) -or $_.EndsWith(".snapshot.png", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        throw "SnapshotPath 必须以 .snapshot.png 结尾，以确保生成文件被 Git 忽略。"
    })]
    [string]$SnapshotPath = "",
    [ValidateSet("Overview", "Settings", "Logs", "Diag")][string]$InitialPanel = "Overview",
    [ValidateRange(0, 300)][int]$AutoCloseSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:RootDirectory = $PSScriptRoot
$script:ConfigPath = Join-Path $PSScriptRoot "config.json"
$script:MonitorScript = Join-Path $PSScriptRoot "LeigodAutoPause.ps1"
$script:StartScript = Join-Path $PSScriptRoot "Start-Monitor.ps1"
$script:StopScript = Join-Path $PSScriptRoot "Stop-Monitor.ps1"
$script:RestartScript = Join-Path $PSScriptRoot "Restart-Monitor.ps1"
$script:ConfigBootstrapScript = Join-Path $PSScriptRoot "ConfigBootstrap.ps1"
$script:SecurityHelpersScript = Join-Path $PSScriptRoot "SecurityHelpers.ps1"
$script:ConfigExamplePath = Join-Path $PSScriptRoot "config.example.json"
$script:XamlPath = Join-Path $PSScriptRoot "ui\MainWindow.xaml"
$script:LogDirectory = Join-Path $PSScriptRoot "logs"
$script:RuntimeStatePath = Join-Path $script:LogDirectory "runtime-state.json"
$script:StartupShortcut = Join-Path ([Environment]::GetFolderPath("Startup")) "Leigod Auto Pause.lnk"
$script:MonitorMutexName = "Local\LeigodAutoPauseMonitor"
$script:ControlMutexName = "Local\LeigodAutoPauseControl"
$script:UiMutexName = "Local\LeigodAutoPauseUI"

. $script:ConfigBootstrapScript
. $script:SecurityHelpersScript
$script:PowerShellPath = Get-WindowsPowerShellPath
[void](Initialize-LeigodAutoPauseConfig -ConfigPath $script:ConfigPath -AppDirectory $PSScriptRoot)

$uiMutexName = $(if ($SnapshotPath) { "$($script:UiMutexName)-Snapshot-$PID" } else { $script:UiMutexName })
$uiMutex = New-Object System.Threading.Mutex($false, $uiMutexName)
$ownsUiMutex = $false
try {
    try {
        $ownsUiMutex = $uiMutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $ownsUiMutex = $true
    }
    if (-not $ownsUiMutex) {
        [System.Windows.MessageBox]::Show("控制台已经打开。", "雷神自动暂停（非官方）", "OK", "Information") | Out-Null
        return
    }

    [xml]$xaml = Get-Content -LiteralPath $script:XamlPath -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    try {
        $window = [Windows.Markup.XamlReader]::Load($reader)
    }
    finally {
        $reader.Close()
    }

    # 窗口图标：任务栏、Alt-Tab、标题栏都取这个；缺失时静默降级，不影响启动。
    $windowIconPath = Join-Path $PSScriptRoot "ui\app.ico"
    if (Test-Path -LiteralPath $windowIconPath) {
        try {
            $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($windowIconPath))
        }
        catch { }
    }

    $controlNames = @(
        "HeaderStatusDot", "HeaderStatusText", "RefreshButton", "OpenLeigodButton",
        "SidebarStatusDot", "SidebarStatusText", "AutoStartToggle",
        "OverviewNavHost", "OverviewIndicator", "OverviewNavButton",
        "SettingsNavHost", "SettingsIndicator", "SettingsNavButton",
        "LogsNavHost", "LogsIndicator", "LogsNavButton",
        "OverviewPanel", "SettingsPanel", "LogsPanel",
        "MainStatusDot", "MainStatusText", "MainStatusDetail", "LastEventText",
        "MonitorActionButton", "MonitorActionIcon", "MonitorActionText",
        "ClientStatusText", "AccountStatusText", "GameStatusText", "ActivityText",
        "GraceSummaryText", "ClientCloseRuleText", "GameCountText",
        "ProcessInput", "AddProcessButton", "GameList", "RemoveProcessButton",
        "ExitGraceInput", "ExitGraceMinusButton", "ExitGracePlusButton",
        "StartupGraceInput", "StartupGraceMinusButton", "StartupGracePlusButton",
        "AutoDetectGamesToggle", "PauseOnClientCloseToggle", "NotificationsToggle", "NeverStartedToggle", "StaleSessionToggle",
        "SettingsHintText", "SaveSettingsButton", "OpenLogFolderButton", "RefreshLogButton",
        "LogTextBox", "FooterMessageText",
        "VerdictBar", "VerdictIcon", "VerdictText", "FreshnessText", "CountdownText", "LastDecisionText",
        "LogSourceText", "LogMatchCountText", "LogSearchInput", "LogLevelCombo", "LogCopyButton",
        "DiagNavHost", "DiagIndicator", "DiagNavButton", "DiagPanel", "DiagRunButton", "DiagCopyButton",
        "DiagSummaryText", "DiagTokenText", "DiagAccountText", "DiagClientText", "DiagGameText", "DiagAdviceText",
        "GameEmptyText", "NeverStartRuleText", "StaleSessionRuleText"
    )
    foreach ($controlName in $controlNames) {
        $control = $window.FindName($controlName)
        if ($null -eq $control) {
            throw "界面控件缺失: $controlName"
        }
        Set-Variable -Name $controlName -Value $control -Scope Script
    }

    # 资源 key 同样是脚本侧的硬契约（Get-ResourceBrush 用），缺失时要在启动就报错，
    # 而不是等用户点到某个状态才发现界面崩了。
    $requiredResourceKeys = @(
        "GreenBrush", "AmberBrush", "RedBrush", "MutedBrush", "WeakBrush",
        "TextBrush", "SurfaceStrongBrush", "PrimaryButtonStyle", "DangerButtonStyle"
    )
    $missingResourceKeys = @()
    foreach ($resourceKey in $requiredResourceKeys) {
        try {
            [void]$window.FindResource($resourceKey)
        }
        catch {
            $missingResourceKeys += $resourceKey
        }
    }
    if ($missingResourceKeys.Count -gt 0) {
        throw ("界面资源缺失: " + ($missingResourceKeys -join ", "))
    }

    $script:Config = $null
    $script:GameNames = New-Object System.Collections.ArrayList
    $script:LoadingConfig = $false
    $script:SuppressAutoStartEvents = $false
    $script:SettingsDirty = $false
    $script:MonitorInstanceState = "Unknown"
    $script:LastProbeData = $null
    $script:ProbeProcess = $null
    $script:ProbeStartedAt = [datetime]::MinValue
    $script:NextProbeAt = [datetime]::MinValue
    $script:StatusProbeEnabled = [string]::IsNullOrWhiteSpace($SnapshotPath)
    $script:ControlProcess = $null
    $script:ControlKind = ""
    $script:CloseAfterControl = $false
    $script:NextLocalRefreshAt = [datetime]::MinValue
    $script:NextLogRefreshAt = [datetime]::MinValue
    $script:UiProcessNames = $null
    $script:UiProcessNamesAt = [datetime]::MinValue
    $script:AutoStartState = $null
    $script:AutoStartCheckedAt = [datetime]::MinValue
    $script:LastLogPlainText = ""

    # 设置项的唯一清单：加载、保存、脏标记都遍历它。
    # 新增一个设置项只需要三处：XAML 控件、这张表的一行、Read-MonitorConfig 的一行。
    $script:SettingDescriptors = @(
        @{ Key = "auto_detect_launched_games";   Control = "AutoDetectGamesToggle";    Kind = "bool"; Default = $true },
        @{ Key = "pause_if_client_closes";       Control = "PauseOnClientCloseToggle"; Kind = "bool"; Default = $true },
        @{ Key = "notifications";                Control = "NotificationsToggle";      Kind = "bool"; Default = $true },
        @{ Key = "pause_if_game_never_starts";   Control = "NeverStartedToggle";       Kind = "bool"; Default = $false },
        @{ Key = "pause_stale_session_on_start"; Control = "StaleSessionToggle";       Kind = "bool"; Default = $false },
        @{ Key = "exit_grace_seconds";           Control = "ExitGraceInput";           Kind = "int";  Default = 120 },
        @{ Key = "startup_grace_seconds";        Control = "StartupGraceInput";        Kind = "int";  Default = 300 }
    )

    function Get-SettingControl {
        param([Parameter(Mandatory = $true)]$Descriptor)
        return Get-Variable -Name $Descriptor.Control -Scope Script -ValueOnly
    }
    function Get-ResourceBrush {
        param([Parameter(Mandatory = $true)][string]$Name)
        return $window.FindResource($Name)
    }

    function Set-FooterMessage {
        param([Parameter(Mandatory = $true)][string]$Message)
        $FooterMessageText.Text = $Message
    }

    function Get-ConfigValue {
        param(
            [Parameter(Mandatory = $true)]$Object,
            [Parameter(Mandatory = $true)][string]$Name,
            $DefaultValue
        )
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property -or $null -eq $property.Value) {
            return $DefaultValue
        }
        return $property.Value
    }

    function Get-ProcessBaseName {
        param([Parameter(Mandatory = $true)][string]$Name)
        $trimmed = $Name.Trim()
        if ($trimmed.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $trimmed.Substring(0, $trimmed.Length - 4)
        }
        return $trimmed
    }

    function Test-ExactProcessRunning {
        param([Parameter(Mandatory = $true)][string]$Name)
        $baseName = Get-ProcessBaseName -Name $Name
        if ([string]::IsNullOrWhiteSpace($baseName)) {
            return $false
        }
        # 统一走一次进程表快照：原来每个进程名都调一次 Get-Process，界面每 2 秒刷新时很浪费。
        $runningNames = Get-UiProcessNameList
        return ($runningNames -contains $baseName)
    }

    function Get-UiProcessNameList {
        $now = Get-Date
        if ($null -ne $script:UiProcessNames -and
            ($now - $script:UiProcessNamesAt).TotalSeconds -lt 1) {
            return $script:UiProcessNames
        }
        $names = @()
        $currentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
            try {
                if ($process.SessionId -eq $currentSessionId -and
                    -not [string]::IsNullOrWhiteSpace([string]$process.ProcessName)) {
                    $names += [string]$process.ProcessName
                }
            }
            catch { }
        }
        $script:UiProcessNames = $names
        $script:UiProcessNamesAt = $now
        return $names
    }

    function Get-MonitorInstanceState {
        $mutex = $null
        $acquired = $false
        try {
            $mutex = New-Object System.Threading.Mutex($false, $script:MonitorMutexName)
            try {
                $acquired = $mutex.WaitOne(0, $false)
            }
            catch [System.Threading.AbandonedMutexException] {
                $acquired = $true
            }
            if ($acquired) {
                return "Stopped"
            }
            return "Running"
        }
        catch [System.UnauthorizedAccessException] {
            return "Unknown"
        }
        catch {
            return "Unknown"
        }
        finally {
            if ($null -ne $mutex) {
                if ($acquired) {
                    try { $mutex.ReleaseMutex() } catch { }
                }
                $mutex.Dispose()
            }
        }
    }

    function Get-CurrentRuntimeState {
        if (-not (Test-Path -LiteralPath $script:RuntimeStatePath -PathType Leaf)) {
            return $null
        }
        try {
            $state = Get-Content -LiteralPath $script:RuntimeStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $maximumAgeSeconds = 20
            if ($null -ne $script:Config) {
                $pollSeconds = [int](Get-ConfigValue -Object $script:Config -Name "poll_seconds" -DefaultValue 2)
                $maximumAgeSeconds = [math]::Max(20, $pollSeconds + 15)
            }
            $updatedAt = [datetime]::MinValue
            if (-not [datetime]::TryParse(
                [string](Get-ConfigValue -Object $state -Name "updated_at" -DefaultValue ""),
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$updatedAt
            ) -or ((Get-Date) - $updatedAt.ToLocalTime()).TotalSeconds -gt $maximumAgeSeconds) {
                return $null
            }
            $monitorPid = [int]0
            if (-not [int]::TryParse([string](Get-ConfigValue -Object $state -Name "monitor_pid" -DefaultValue ""), [ref]$monitorPid) -or $monitorPid -le 0) {
                return $null
            }
            $process = Get-Process -Id $monitorPid -ErrorAction SilentlyContinue
            if ($null -eq $process -or $process.SessionId -ne [System.Diagnostics.Process]::GetCurrentProcess().SessionId) {
                return $null
            }
            return $state
        }
        catch {
            return $null
        }
    }

    function Get-RunningConfiguredGames {
        $running = @()
        foreach ($name in @($script:GameNames)) {
            if (Test-ExactProcessRunning -Name ([string]$name)) {
                $running += [string]$name
            }
        }
        return [string[]]$running
    }

    function Test-AutoStartEnabled {
        if (-not (Test-Path -LiteralPath $script:StartupShortcut -PathType Leaf)) {
            return $false
        }
        $shell = $null
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($script:StartupShortcut)
            return [string]::Equals($shortcut.TargetPath, $script:PowerShellPath, [System.StringComparison]::OrdinalIgnoreCase) -and
                $shortcut.Arguments.IndexOf($script:StartScript, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        }
        catch {
            return $false
        }
        finally {
            if ($null -ne $shell) {
                [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
            }
        }
    }

    function Set-AutoStartEnabled {
        param([Parameter(Mandatory = $true)][bool]$Enabled)
        if (-not $Enabled) {
            if (Test-Path -LiteralPath $script:StartupShortcut) {
                Remove-Item -LiteralPath $script:StartupShortcut -Force
            }
            return
        }

        Assert-PrivateAutoStartSource -Path @(
            $script:RootDirectory, $script:StartScript, $script:MonitorScript,
            $script:ConfigBootstrapScript, $script:SecurityHelpersScript,
            $script:ConfigExamplePath, $script:ConfigPath,
            (Split-Path -Parent $script:StartupShortcut)
        )

        $shell = New-Object -ComObject WScript.Shell
        try {
            $shortcut = $shell.CreateShortcut($script:StartupShortcut)
            $shortcut.TargetPath = $script:PowerShellPath
            $shortcut.Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($script:StartScript)`" -ConfigPath `"$($script:ConfigPath)`""
            $shortcut.WorkingDirectory = $script:RootDirectory
            $shortcut.Description = "雷神加速器游戏退出自动暂停监控（非官方）"
            $shortcut.Save()
            Assert-PrivateAutoStartSource -Path @($script:StartupShortcut)
        }
        catch {
            if (Test-Path -LiteralPath $script:StartupShortcut -PathType Leaf) {
                Remove-Item -LiteralPath $script:StartupShortcut -Force
            }
            throw
        }
        finally {
            [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }

    function Load-Configuration {
        param([switch]$SkipValidation)

        if (-not $SkipValidation) {
            $validation = Invoke-ConfigValidation -Path $script:ConfigPath
            if ($validation.ExitCode -ne 0) {
                $validationDetail = $(if ([string]::IsNullOrWhiteSpace($validation.Error)) { "" } else { "：" + $validation.Error })
                throw ("配置未通过监控器验证{0}" -f $validationDetail)
            }
        }

        $script:LoadingConfig = $true
        try {
            $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8
            $script:Config = $raw | ConvertFrom-Json
            $script:GameNames.Clear()
            foreach ($name in @(Get-ConfigValue -Object $script:Config -Name "game_processes" -DefaultValue @())) {
                $displayName = [string]$name
                if (-not $displayName.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $displayName += ".exe"
                }
                [void]$script:GameNames.Add($displayName)
            }

            foreach ($descriptor in $script:SettingDescriptors) {
                $control = Get-SettingControl -Descriptor $descriptor
                $value = Get-ConfigValue -Object $script:Config -Name $descriptor.Key -DefaultValue $descriptor.Default
                if ($descriptor.Kind -eq "bool") {
                    $control.IsChecked = [bool]$value
                }
                else {
                    $control.Text = [string]$value
                }
            }
            $script:SettingsDirty = $false
            $SettingsHintText.Text = "设置未修改"
        }
        finally {
            $script:LoadingConfig = $false
        }
        Update-GameList
        Update-RuleSummary
    }

    function Set-SettingsDirty {
        if ($script:LoadingConfig) {
            return
        }
        $script:SettingsDirty = $true
        $SettingsHintText.Text = "有未保存的修改"
        $SettingsHintText.Foreground = Get-ResourceBrush -Name "AmberBrush"
    }

    function Update-GameList {
        $selectedProcess = $null
        if ($null -ne $GameList.SelectedItem) {
            $selectedProcess = [string]$GameList.SelectedItem.Process
        }
        $GameList.Items.Clear()
        foreach ($name in @($script:GameNames)) {
            $status = $(if (Test-ExactProcessRunning -Name ([string]$name)) { "运行中" } else { "未运行" })
            $item = [pscustomobject]@{ Process = [string]$name; Status = $status }
            [void]$GameList.Items.Add($item)
            if ($selectedProcess -and [string]::Equals($selectedProcess, [string]$name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $GameList.SelectedItem = $item
            }
        }
        $GameEmptyText.Visibility = $(if ($script:GameNames.Count -eq 0) { "Visible" } else { "Collapsed" })
    }

    function Update-RuleSummary {
        $exitGrace = 120
        [void][int]::TryParse($ExitGraceInput.Text, [ref]$exitGrace)
        $GraceSummaryText.Text = "$exitGrace 秒"
        $ClientCloseRuleText.Text = $(if ($PauseOnClientCloseToggle.IsChecked) { "启用" } else { "关闭" })
        $GameCountText.Text = $(if ($AutoDetectGamesToggle.IsChecked) { "自动 + $($script:GameNames.Count) 个" } else { "仅 $($script:GameNames.Count) 个" })
        $NeverStartRuleText.Text = $(if ($NeverStartedToggle.IsChecked) { "启用" } else { "关闭" })
        $StaleSessionRuleText.Text = $(if ($StaleSessionToggle.IsChecked) { "启用" } else { "关闭" })
    }

    function Save-Configuration {
        $exitGrace = 0
        $startupGrace = 0
        if (-not [int]::TryParse($ExitGraceInput.Text.Trim(), [ref]$exitGrace) -or $exitGrace -lt 10 -or $exitGrace -gt 3600) {
            throw "游戏退出宽限必须是 10 到 3600 秒之间的整数。"
        }
        if (-not [int]::TryParse($StartupGraceInput.Text.Trim(), [ref]$startupGrace) -or $startupGrace -lt 10 -or $startupGrace -gt 7200) {
            throw "启动观察期必须是 10 到 7200 秒之间的整数。"
        }
        if (-not $AutoDetectGamesToggle.IsChecked -and $script:GameNames.Count -eq 0) {
            throw "关闭自动识别时，至少需要一个手动补充进程。"
        }

        # 以现有配置为底，只覆写界面负责的键。否则用户在 config.json 里手写的键
        # 或未来新增的键，会在界面上点一次“保存”后被静默删掉。
        $configObject = [ordered]@{}
        if ($null -ne $script:Config) {
            foreach ($property in $script:Config.PSObject.Properties) {
                $configObject[$property.Name] = $property.Value
            }
        }
        $configObject["game_processes"] = [string[]]@($script:GameNames)
        foreach ($descriptor in $script:SettingDescriptors) {
            $control = Get-SettingControl -Descriptor $descriptor
            if ($descriptor.Kind -eq "bool") {
                $configObject[$descriptor.Key] = [bool]$control.IsChecked
                continue
            }
            $parsed = 0
            if (-not [int]::TryParse([string]$control.Text, [ref]$parsed)) {
                throw ("{0} 必须是整数。" -f $descriptor.Key)
            }
            $configObject[$descriptor.Key] = $parsed
        }

        $temporaryPath = "$($script:ConfigPath).ui.tmp"
        try {
            $configObject | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
            $validation = Invoke-ConfigValidation -Path $temporaryPath
            if ($validation.ExitCode -ne 0) {
                $validationDetail = $(if ([string]::IsNullOrWhiteSpace($validation.Error)) { "" } else { "：" + $validation.Error })
                throw ("新配置未通过监控器验证{0}" -f $validationDetail)
            }
            Move-Item -LiteralPath $temporaryPath -Destination $script:ConfigPath -Force
        }
        finally {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }
        }

        Load-Configuration -SkipValidation
        $SettingsHintText.Text = "设置已保存"
        $SettingsHintText.Foreground = Get-ResourceBrush -Name "GreenBrush"
    }

    function Quote-ProcessArgument {
        param([Parameter(Mandatory = $true)][string]$Value)
        return '"' + $Value.Replace('"', '\"') + '"'
    }

    function Invoke-ConfigValidation {
        <# 调用监控器做配置校验，并把 stderr 原文带回来——否则用户只能看到“未通过验证”这种没有信息量的结论。 #>
        param([Parameter(Mandatory = $true)][string]$Path)

        $stamp = [guid]::NewGuid().ToString("N")
        $stdoutPath = Join-Path $env:TEMP ("leigod-validate-out-$stamp.txt")
        $stderrPath = Join-Path $env:TEMP ("leigod-validate-err-$stamp.txt")
        try {
            $process = Start-Process -FilePath $script:PowerShellPath -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", (Quote-ProcessArgument -Value $script:MonitorScript),
                "-ConfigPath", (Quote-ProcessArgument -Value $Path),
                "-ValidateConfig"
            ) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
            $errorText = ""
            if (Test-Path -LiteralPath $stderrPath) {
                # 空文件时 Get-Content -Raw 会返回 $null，直接 .Trim() 会炸，所以先判空再收敛成字符串。
                $rawError = Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($null -ne $rawError) {
                    $errorText = ([string]$rawError).Trim()
                }
            }
            return [pscustomobject]@{
                ExitCode = $process.ExitCode
                Error    = $errorText
            }
        }
        finally {
            Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }

    function Start-ControlAction {
        param([Parameter(Mandatory = $true)][ValidateSet("Start", "Stop", "Restart")][string]$Kind)
        if ($null -ne $script:ControlProcess) {
            Set-FooterMessage -Message "另一项控制操作正在进行。"
            return
        }

        $scriptPath = switch ($Kind) {
            "Start" { $script:StartScript }
            "Stop" { $script:StopScript }
            "Restart" { $script:RestartScript }
        }
        $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $(Quote-ProcessArgument -Value $scriptPath)"
        if ($Kind -in @("Start", "Restart")) {
            $arguments += " -ConfigPath $(Quote-ProcessArgument -Value $script:ConfigPath)"
        }

        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $script:PowerShellPath
        $info.Arguments = $arguments
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $script:ControlProcess = [System.Diagnostics.Process]::Start($info)
        $script:ControlKind = $Kind
        $MonitorActionButton.IsEnabled = $false
        $SaveSettingsButton.IsEnabled = $false
        Set-FooterMessage -Message $(switch ($Kind) { "Start" { "正在启动后台监控..." } "Stop" { "正在安全停止后台监控..." } "Restart" { "正在应用设置并重启监控..." } })
    }

    function Complete-ControlAction {
        if ($null -eq $script:ControlProcess -or -not $script:ControlProcess.HasExited) {
            return
        }
        $output = $script:ControlProcess.StandardOutput.ReadToEnd().Trim()
        $errorText = $script:ControlProcess.StandardError.ReadToEnd().Trim()
        $exitCode = $script:ControlProcess.ExitCode
        $kind = $script:ControlKind
        $script:ControlProcess.Dispose()
        $script:ControlProcess = $null
        $script:ControlKind = ""
        $MonitorActionButton.IsEnabled = $true
        $SaveSettingsButton.IsEnabled = $true

        if ($exitCode -eq 0) {
            $message = switch ($kind) {
                "Start" { "后台监控已启动。" }
                "Stop" { "后台监控已停止；控制台仍保持打开。" }
                "Restart" { "设置已应用，后台监控已重启。" }
            }
            Set-FooterMessage -Message $message
        }
        else {
            # 只取最后一行会把真正的原因吞掉（例如“配置验证失败，未启动监控。”盖住了
            # “game_processes 必须使用不含路径或通配符的完整进程名。”），所以保留最后 3 行。
            $detailLines = @(
                foreach ($source in @($errorText, $output)) {
                    if ([string]::IsNullOrWhiteSpace($source)) { continue }
                    foreach ($line in ($source -split "`r?`n")) {
                        if (-not [string]::IsNullOrWhiteSpace($line)) { $line.Trim() }
                    }
                }
            ) | Select-Object -Last 3
            $detail = $(if (@($detailLines).Count -gt 0) { (@($detailLines) -join " / ") } else { "未知错误" })
            if ($detail -match 'MONITOR_ALREADY_RUNNING') {
                $detail = "后台监控已在运行。"
            }
            Set-FooterMessage -Message ("控制操作失败: {0}" -f $detail)
            [System.Windows.MessageBox]::Show($detail, "雷神自动暂停（非官方）", "OK", "Error") | Out-Null
        }
        $script:NextLocalRefreshAt = [datetime]::MinValue
        $script:NextLogRefreshAt = [datetime]::MinValue
        if ($script:CloseAfterControl) {
            $script:CloseAfterControl = $false
            $window.Close()
        }
    }

    function Start-StatusProbe {
        param([switch]$Force)

        if (-not $script:StatusProbeEnabled) {
            return
        }
        # 后台监控运行时，runtime-state.json 里已经带着 account_state，界面直接读即可；
        # 但状态文件过期（监控卡住或刚重启）时必须自己探测兜底，否则界面会一直显示旧值。
        if (-not $Force -and $script:MonitorInstanceState -eq "Running") {
            $liveState = Get-CurrentRuntimeState
            if ($null -ne $liveState) {
                return
            }
        }
        if ($null -ne $script:ProbeProcess) {
            return
        }
        if (-not $Force -and (Get-Date) -lt $script:NextProbeAt) {
            return
        }
        $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $(Quote-ProcessArgument -Value $script:MonitorScript) -ConfigPath $(Quote-ProcessArgument -Value $script:ConfigPath) -CheckJson"
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $script:PowerShellPath
        $info.Arguments = $arguments
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $script:ProbeProcess = [System.Diagnostics.Process]::Start($info)
        $script:ProbeStartedAt = Get-Date
        $script:NextProbeAt = (Get-Date).AddSeconds(30)
        $AccountStatusText.Text = "正在检查"
        $AccountStatusText.Foreground = Get-ResourceBrush -Name "MutedBrush"
    }

    function Complete-StatusProbe {
        if ($null -eq $script:ProbeProcess) {
            return
        }
        if (-not $script:ProbeProcess.HasExited) {
            if (((Get-Date) - $script:ProbeStartedAt).TotalSeconds -gt 20) {
                try { $script:ProbeProcess.Kill() } catch { }
                $script:LastProbeData = $null
                $script:ProbeProcess.Dispose()
                $script:ProbeProcess = $null
                $AccountStatusText.Text = "检查超时"
                $AccountStatusText.Foreground = Get-ResourceBrush -Name "RedBrush"
            }
            return
        }

        $output = $script:ProbeProcess.StandardOutput.ReadToEnd().Trim()
        $exitCode = $script:ProbeProcess.ExitCode
        $script:ProbeProcess.Dispose()
        $script:ProbeProcess = $null
        if ($exitCode -eq 0 -and $output) {
            try {
                $script:LastProbeData = $output | ConvertFrom-Json
            }
            catch {
                $script:LastProbeData = $null
            }
        }
        else {
            $script:LastProbeData = $null
        }
        Update-LocalStatus
    }

    function Get-LatestLogSnapshot {
        param([ValidateRange(1, 500)][int]$Count = 200)

        if (-not (Test-Path -LiteralPath $script:LogDirectory -PathType Container)) {
            return [pscustomobject]@{ FileName = ""; Lines = [string[]]@() }
        }
        $file = Get-ChildItem -LiteralPath $script:LogDirectory -Filter "monitor-*.log" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -eq $file) {
            return [pscustomobject]@{ FileName = ""; Lines = [string[]]@() }
        }
        $lines = @(Get-Content -LiteralPath $file.FullName -Tail $Count -Encoding UTF8 -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        return [pscustomobject]@{ FileName = $file.Name; Lines = [string[]]$lines }
    }

    function Test-LogLineMatchesFilter {
        param(
            [AllowEmptyString()][string]$Line,
            [AllowEmptyString()][string]$Keyword,
            [AllowEmptyString()][string]$LevelFilter
        )

        $level = "INFO"
        if ($Line -match '\[(WARN|ERROR)\]') {
            $level = $Matches[1]
        }
        switch ($LevelFilter) {
            "仅提醒" { if ($level -ne "WARN") { return $false } }
            "仅错误" { if ($level -ne "ERROR") { return $false } }
            "仅决策" { if ($Line -notmatch '\[DECISION:') { return $false } }
        }
        if (-not [string]::IsNullOrWhiteSpace($Keyword) -and
            $Line.IndexOf($Keyword, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            return $false
        }
        return $true
    }

    function Set-LogDocument {
        <# 把日志行渲染成带级别配色的 FlowDocument（RichTextBox 不支持 Text 属性）。 #>
        param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Lines)

        $document = New-Object System.Windows.Documents.FlowDocument
        $document.PagePadding = New-Object System.Windows.Thickness(0)
        $document.LineHeight = 18
        $document.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas, Microsoft YaHei UI")
        $document.FontSize = 12

        $infoBrush = Get-ResourceBrush -Name "MutedBrush"
        $warnBrush = Get-ResourceBrush -Name "AmberBrush"
        $errorBrush = Get-ResourceBrush -Name "RedBrush"
        $okBrush = Get-ResourceBrush -Name "GreenBrush"

        foreach ($line in $Lines) {
            $paragraph = New-Object System.Windows.Documents.Paragraph
            $paragraph.Margin = New-Object System.Windows.Thickness(0)
            $paragraph.LineHeight = 18
            $run = New-Object System.Windows.Documents.Run([string]$line)
            if ($line -match '\[ERROR\]' -or $line -match 'DECISION:PAUSE_FAILED') {
                $run.Foreground = $errorBrush
            }
            elseif ($line -match '\[WARN\]') {
                $run.Foreground = $warnBrush
            }
            elseif ($line -match 'DECISION:PAUSED') {
                $run.Foreground = $okBrush
            }
            elseif ($line -match '\[DECISION:') {
                $run.Foreground = $warnBrush
            }
            else {
                $run.Foreground = $infoBrush
            }
            [void]$paragraph.Inlines.Add($run)
            [void]$document.Blocks.Add($paragraph)
        }
        $LogTextBox.Document = $document
    }

    function Get-ActivityHighlights {
        <# 从日志里挑出关键事件，去掉级别前缀只留时间和内容，比原样复读最后 4 行有用。 #>
        param(
            [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Lines,
            [int]$Count = 3
        )

        $keyPattern = '检测到游戏运行|游戏进程已退出|检测到游戏退出|暂停成功|暂停失败|客户端已关闭|收到停止标记|账号状态更新|账号状态无法确认|已按保留策略'
        $picked = @()
        for ($i = $Lines.Count - 1; $i -ge 0 -and $picked.Count -lt $Count; $i--) {
            $line = [string]$Lines[$i]
            if ($line -notmatch $keyPattern) {
                continue
            }
            $time = ""
            if ($line -match '^\[(?<stamp>[^\]]+)\]') {
                $stamp = [string]$Matches['stamp']
                if ($stamp.Length -ge 8) {
                    $time = $stamp.Substring($stamp.Length - 8) + " "
                }
            }
            $body = $line -replace '^\[[^\]]+\]\s*\[(INFO|WARN|ERROR)\]\s*', ''
            $picked += ("· " + $time + $body)
        }
        return [string[]]$picked
    }
    function Update-LogView {
        $snapshot = Get-LatestLogSnapshot -Count 200
        $LogSourceText.Text = $(if ($snapshot.FileName) { "来源: " + $snapshot.FileName } else { "暂无日志文件" })

        $keyword = [string]$LogSearchInput.Text
        $levelFilter = ""
        if ($null -ne $LogLevelCombo.SelectedItem -and $null -ne $LogLevelCombo.SelectedItem.Content) {
            $levelFilter = [string]$LogLevelCombo.SelectedItem.Content
        }

        $filtered = @($snapshot.Lines | Where-Object {
                Test-LogLineMatchesFilter -Line $_ -Keyword $keyword -LevelFilter $levelFilter
            })
        $LogMatchCountText.Text = $(if ($filtered.Count -ne $snapshot.Lines.Count) {
                "命中 {0} / {1} 行" -f $filtered.Count, $snapshot.Lines.Count
            }
            else { "" })

        if ($filtered.Count -eq 0) {
            if ($script:LastLogPlainText -ne "暂无匹配的运行日志。") {
                Set-LogDocument -Lines @("暂无匹配的运行日志。")
                $script:LastLogPlainText = "暂无匹配的运行日志。"
            }
            $ActivityText.Text = "暂无活动记录"
            $LastEventText.Text = "暂无活动记录"
            return
        }

        # 只有内容真的变了才重建文档：无条件重建会每 5 秒清掉滚动位置和选区，排障时没法看。
        $text = $filtered -join [Environment]::NewLine
        if ($script:LastLogPlainText -ne $text) {
            $wasAtBottom = (($LogTextBox.ExtentHeight - $LogTextBox.VerticalOffset - $LogTextBox.ViewportHeight) -lt 2)
            Set-LogDocument -Lines $filtered
            $script:LastLogPlainText = $text
            if ($wasAtBottom) {
                $LogTextBox.ScrollToEnd()
            }
        }

        $highlights = @(Get-ActivityHighlights -Lines $filtered -Count 3)
        $ActivityText.Text = $(if ($highlights.Count -gt 0) { $highlights -join [Environment]::NewLine } else { "暂无活动记录" })
        $LastEventText.Text = [string]$filtered[-1]
    }

    function Update-LocalStatus {
        $script:MonitorInstanceState = Get-MonitorInstanceState
        $clientRunning = Test-ExactProcessRunning -Name "leigod.exe"
        $runtimeState = Get-CurrentRuntimeState
        $autoDetectionEnabled = [bool](Get-ConfigValue -Object $script:Config -Name "auto_detect_launched_games" -DefaultValue $true)
        $runningGames = @(Get-RunningConfiguredGames)
        $targetProcesses = [string[]]@($script:GameNames)
        $launchPending = $false
        $unresolvedLaunch = $false
        $runtimeMonitorState = ""
        $runtimeAccountState = ""
        if ($null -ne $runtimeState) {
            $runningGames = [string[]]@(Get-ConfigValue -Object $runtimeState -Name "running_games" -DefaultValue @())
            $targetProcesses = [string[]]@(Get-ConfigValue -Object $runtimeState -Name "target_processes" -DefaultValue @())
            $launchPending = [bool](Get-ConfigValue -Object $runtimeState -Name "launch_pending" -DefaultValue $false)
            $unresolvedLaunch = [bool](Get-ConfigValue -Object $runtimeState -Name "unresolved_launch" -DefaultValue $false)
            $runtimeMonitorState = [string](Get-ConfigValue -Object $runtimeState -Name "state" -DefaultValue "")
            $runtimeAccountState = [string](Get-ConfigValue -Object $runtimeState -Name "account_state" -DefaultValue "")
        }
        $gameRunning = $runningGames.Count -gt 0

        if ($script:MonitorInstanceState -eq "Running") {
            $statusBrush = Get-ResourceBrush -Name "GreenBrush"
            $HeaderStatusText.Text = "后台运行中"
            $SidebarStatusText.Text = "运行中"
            $MonitorActionButton.Style = $window.FindResource("DangerButtonStyle")
            $MonitorActionIcon.Text = [char]0xE71A
            $MonitorActionText.Text = "停止监控"
            if ($runtimeMonitorState -eq "GameStarting" -or $launchPending) {
                $MainStatusText.Text = "游戏正在启动"
                $MainStatusDetail.Text = $(if ($unresolvedLaunch) { "当前启动事件未提供可用进程名" } elseif ($targetProcesses.Count -gt 0) { "等待 $($targetProcesses -join ', ')" } else { "等待雷神提供目标进程" })
            }
            elseif ($gameRunning) {
                $MainStatusText.Text = "游戏运行中"
                $MainStatusDetail.Text = "正在监测 $($runningGames -join ', ')"
            }
            elseif ($runtimeMonitorState -in @("AfterGameExit", "AfterClientExit", "WaitingForGame", "StaleSession")) {
                switch ($runtimeMonitorState) {
                    "AfterGameExit" {
                        $MainStatusText.Text = "游戏已退出，等待复核"
                        $MainStatusDetail.Text = "宽限期结束后将再次检查游戏与账号状态"
                    }
                    "AfterClientExit" {
                        $MainStatusText.Text = "客户端已关闭，等待复核"
                        $MainStatusDetail.Text = "宽限期结束后将再次检查客户端、游戏与账号状态"
                    }
                    "WaitingForGame" {
                        $MainStatusText.Text = "等待目标游戏启动"
                        $MainStatusDetail.Text = "启动观察期结束后将进行安全复核"
                    }
                    "StaleSession" {
                        $MainStatusText.Text = "等待遗留会话复核"
                        $MainStatusDetail.Text = "观察期结束后将重新确认客户端、游戏与账号状态"
                    }
                }
            }
            elseif ($unresolvedLaunch) {
                $MainStatusText.Text = "目标游戏无法确认"
                $MainStatusDetail.Text = "当前雷神启动事件没有可用进程名"
            }
            else {
                $MainStatusText.Text = $(if ($autoDetectionEnabled) { "等待雷神启动游戏" } else { "等待手动目标游戏" })
                $MainStatusDetail.Text = $(if ($autoDetectionEnabled) { "正在监听新的游戏启动事件" } else { "正在监测已配置的游戏进程" })
            }
        }
        elseif ($script:MonitorInstanceState -eq "Stopped") {
            $statusBrush = Get-ResourceBrush -Name "WeakBrush"
            $HeaderStatusText.Text = "后台已停止"
            $SidebarStatusText.Text = "已停止"
            $MainStatusText.Text = "监控已停止"
            $MainStatusDetail.Text = "当前不会自动暂停雷神时长"
            $MonitorActionButton.Style = $window.FindResource("PrimaryButtonStyle")
            $MonitorActionIcon.Text = [char]0xE768
            $MonitorActionText.Text = "启动监控"
        }
        else {
            $statusBrush = Get-ResourceBrush -Name "RedBrush"
            $HeaderStatusText.Text = "状态未知"
            $SidebarStatusText.Text = "无法确认"
            $MainStatusText.Text = "无法确认监控状态"
            $MainStatusDetail.Text = "已阻止重复控制操作"
            $MonitorActionButton.Style = $window.FindResource("PrimaryButtonStyle")
            $MonitorActionIcon.Text = [char]0xE72C
            $MonitorActionText.Text = "重新检查"
        }
        $HeaderStatusDot.Fill = $statusBrush
        $SidebarStatusDot.Fill = $statusBrush
        $MainStatusDot.Fill = $statusBrush

        $ClientStatusText.Text = $(if ($clientRunning) { "运行中" } else { "未运行" })
        $ClientStatusText.Foreground = $(if ($clientRunning) { Get-ResourceBrush -Name "GreenBrush" } else { Get-ResourceBrush -Name "MutedBrush" })
        $GameStatusText.Text = $(if ($gameRunning) { $runningGames -join ", " } elseif ($launchPending) { "启动中" } elseif ($unresolvedLaunch) { "无法识别" } else { "未检测到" })
        $GameStatusText.Foreground = $(if ($gameRunning) { Get-ResourceBrush -Name "GreenBrush" } elseif ($launchPending -or $unresolvedLaunch) { Get-ResourceBrush -Name "AmberBrush" } else { Get-ResourceBrush -Name "MutedBrush" })

        $accountDisplayState = $runtimeAccountState
        if ([string]::IsNullOrWhiteSpace($accountDisplayState) -and $null -ne $script:LastProbeData) {
            $accountDisplayState = [string]$script:LastProbeData.AccountState
        }
        switch ($accountDisplayState) {
            "Active" {
                $AccountStatusText.Text = "正在计时"
                $AccountStatusText.Foreground = Get-ResourceBrush -Name "AmberBrush"
            }
            "Paused" {
                $AccountStatusText.Text = "已暂停"
                $AccountStatusText.Foreground = Get-ResourceBrush -Name "GreenBrush"
            }
            "Unknown" {
                $AccountStatusText.Text = "无法确认"
                $AccountStatusText.Foreground = Get-ResourceBrush -Name "RedBrush"
            }
            default {
                $AccountStatusText.Text = $(if ($null -ne $script:ProbeProcess) { "正在确认" } else { "尚未确认" })
                $AccountStatusText.Foreground = Get-ResourceBrush -Name "RedBrush"
            }
        }

        # ---- 结论条：一句话回答“我现在安全吗” ----
        $sessionConfirmed = $false
        $pauseDeadlineText = ""
        $lastDecisionCode = ""
        $lastDecisionTime = ""
        $runtimeAccountMessage = ""
        if ($null -ne $runtimeState) {
            $sessionConfirmed = [bool](Get-ConfigValue -Object $runtimeState -Name "session_confirmed" -DefaultValue (Get-ConfigValue -Object $runtimeState -Name "association_confirmed" -DefaultValue $false))
            $pauseDeadlineText = [string](Get-ConfigValue -Object $runtimeState -Name "pause_deadline_at" -DefaultValue "")
            $lastDecisionCode = [string](Get-ConfigValue -Object $runtimeState -Name "last_decision" -DefaultValue "")
            $lastDecisionTime = [string](Get-ConfigValue -Object $runtimeState -Name "last_decision_at" -DefaultValue "")
            $runtimeAccountMessage = [string](Get-ConfigValue -Object $runtimeState -Name "account_message" -DefaultValue "")
        }

        $verdictLabel = ""
        $verdictBrushName = "MutedBrush"
        $verdictGlyph = [char]0xE946
        if ($script:MonitorInstanceState -ne "Running") {
            $verdictLabel = "后台监控未运行，不会自动暂停"
            $verdictBrushName = "WeakBrush"
            $verdictGlyph = [char]0xEA39
        }
        elseif ($runtimeAccountState -eq "Paused") {
            $verdictLabel = "已暂停，安全"
            $verdictBrushName = "GreenBrush"
            $verdictGlyph = [char]0xE73E
        }
        elseif ($gameRunning -and $runtimeAccountState -eq "Active" -and $sessionConfirmed) {
            $verdictLabel = "计时中，游戏退出后将自动暂停"
            $verdictBrushName = "AmberBrush"
            $verdictGlyph = [char]0xE7BA
        }
        elseif ($runtimeAccountState -eq "Active") {
            $verdictLabel = "账号在计时，但本次会话尚未确认；退出后不会自动暂停"
            $verdictBrushName = "AmberBrush"
            $verdictGlyph = [char]0xE7BA
        }
        else {
            $verdictLabel = "账号状态无法确认"
            $verdictBrushName = "RedBrush"
            $verdictGlyph = [char]0xEA39
        }
        $VerdictIcon.Text = [string]$verdictGlyph
        $VerdictText.Text = $verdictLabel
        $VerdictText.Foreground = Get-ResourceBrush -Name $verdictBrushName
        $LastDecisionText.Text = $(if ($lastDecisionCode) { "最近结论: " + $lastDecisionCode } else { "" })

        # 数据新鲜度：监控卡住时界面不能假装一切正常
        $freshnessLabel = ""
        if ($null -ne $runtimeState) {
            $updatedAtValue = [datetime]::MinValue
            if ([datetime]::TryParse(
                    [string](Get-ConfigValue -Object $runtimeState -Name "updated_at" -DefaultValue ""),
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind,
                    [ref]$updatedAtValue)) {
                $ageSeconds = [int][math]::Max(0, ((Get-Date) - $updatedAtValue.ToLocalTime()).TotalSeconds)
                $freshnessLabel = "状态更新于 $ageSeconds 秒前"
            }
        }
        $FreshnessText.Text = $freshnessLabel

        # 倒计时只在四个倒计时状态出现
        $CountdownText.Visibility = "Collapsed"
        if (-not [string]::IsNullOrWhiteSpace($pauseDeadlineText)) {
            $deadlineValue = [datetime]::MinValue
            if ([datetime]::TryParse(
                    $pauseDeadlineText,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind,
                    [ref]$deadlineValue)) {
                $remainingSeconds = [int][math]::Ceiling(($deadlineValue.ToLocalTime() - (Get-Date)).TotalSeconds)
                if ($remainingSeconds -gt 0) {
                    $CountdownText.Text = ("剩余 {0:mm\:ss}" -f [timespan]::FromSeconds($remainingSeconds))
                    $CountdownText.Visibility = "Visible"
                }
            }
        }

        # 账号状态无法确认时，直接给出原因（凭据失效 / HTTP 超时），而不是只说“无法确认”
        if ($runtimeAccountState -eq "Unknown" -and -not [string]::IsNullOrWhiteSpace($runtimeAccountMessage)) {
            $AccountStatusText.Text = "无法确认：" + $runtimeAccountMessage
        }
        # 开机自启状态原来每 2 秒新建一次 WScript.Shell COM 对象并读快捷方式，缓存 10 秒即可。
        if ($null -eq $script:AutoStartState -or
            ((Get-Date) - $script:AutoStartCheckedAt).TotalSeconds -ge 10) {
            $script:AutoStartState = Test-AutoStartEnabled
            $script:AutoStartCheckedAt = Get-Date
        }
        $script:SuppressAutoStartEvents = $true
        try {
            $AutoStartToggle.IsChecked = [bool]$script:AutoStartState
        }
        finally {
            $script:SuppressAutoStartEvents = $false
        }
        Update-GameList
        Update-RuleSummary
    }

    function Update-DiagView {
        $probe = $script:LastProbeData
        if ($null -eq $probe) {
            $DiagSummaryText.Text = "还没有诊断结果。点击「运行诊断」读取本机状态（只读，不会发送暂停请求）。"
            $DiagTokenText.Text = "—"
            $DiagAccountText.Text = "—"
            $DiagClientText.Text = "—"
            $DiagGameText.Text = "—"
            $DiagAdviceText.Text = "诊断只读取四件事：登录凭据是否存在、账号是否在计时、雷神客户端是否在运行、目标游戏是否已识别。"
            return
        }

        $tokenFound = [bool](Get-ConfigValue -Object $probe -Name "TokenFound" -DefaultValue $false)
        $accountState = [string](Get-ConfigValue -Object $probe -Name "AccountState" -DefaultValue "Unknown")
        $accountMessage = [string](Get-ConfigValue -Object $probe -Name "AccountStateMessage" -DefaultValue "")
        $clientRunning = [bool](Get-ConfigValue -Object $probe -Name "LeigodRunning" -DefaultValue $false)
        $configuredCount = [int](Get-ConfigValue -Object $probe -Name "ConfiguredGameCount" -DefaultValue 0)
        $detectedCount = [int](Get-ConfigValue -Object $probe -Name "DetectedGameCount" -DefaultValue 0)
        $targetCount = [int](Get-ConfigValue -Object $probe -Name "TargetGameCount" -DefaultValue 0)
        $runningCount = [int](Get-ConfigValue -Object $probe -Name "RunningGameCount" -DefaultValue 0)
        $autoDetect = [bool](Get-ConfigValue -Object $probe -Name "AutoDetectionEnabled" -DefaultValue $false)

        $DiagSummaryText.Text = ("监控: {0}；自动识别: {1}" -f $script:MonitorInstanceState, $(if ($autoDetect) { "启用" } else { "关闭" }))
        $DiagTokenText.Text = $(if ($tokenFound) { "已找到（来自雷神客户端日志，不会写入本项目）" } else { "未找到，请先登录雷神客户端" })
        $DiagAccountText.Text = $(if ([string]::IsNullOrWhiteSpace($accountMessage)) { $accountState } else { "$accountState（$accountMessage）" })
        $DiagClientText.Text = $(if ($clientRunning) { "运行中" } else { "未运行" })
        $DiagGameText.Text = ("手动 {0} 个 · 自动识别 {1} 个 · 目标合计 {2} 个 · 正在运行 {3} 个" -f $configuredCount, $detectedCount, $targetCount, $runningCount)

        $advice = @()
        if (-not $tokenFound) {
            $advice += "· 没有找到登录凭据：先登录雷神客户端，再运行一次诊断。"
        }
        if (-not $clientRunning -and $autoDetect) {
            $advice += "· 客户端未运行：自动识别依赖客户端日志，未打开客户端时不会自动暂停。"
        }
        if ($targetCount -eq 0) {
            $advice += "· 没有任何目标游戏：打开自动识别，或在规则设置里补充进程名。"
        }
        if ($accountState -notin @("Active", "Paused")) {
            $advice += "· 账号状态不是 Active/Paused：暂停请求会被拒绝，先确认客户端里已登录并正常计时。"
        }
        if ($advice.Count -eq 0) {
            $advice += "· 检查通过：监控运行时会按规则在游戏退出后复核并暂停。"
        }
        if ($script:MonitorInstanceState -ne "Running") {
            $advice += "· 后台监控当前未运行，任何规则都不会生效。"
        }
        $DiagAdviceText.Text = ($advice -join [Environment]::NewLine)
    }

    function Get-DiagReportText {
        $lines = @(
            "雷神自动暂停 排障报告",
            ("时间: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")),
            ("监控: " + $script:MonitorInstanceState),
            ("登录凭据: " + $DiagTokenText.Text),
            ("账号时长: " + $DiagAccountText.Text),
            ("雷神客户端: " + $DiagClientText.Text),
            ("目标游戏: " + $DiagGameText.Text),
            ("建议: " + ($DiagAdviceText.Text -replace "`r?`n", " "))
        )
        return ($lines -join [Environment]::NewLine)
    }
    function Show-Panel {
        param([Parameter(Mandatory = $true)][ValidateSet("Overview", "Settings", "Logs", "Diag")][string]$Name)
        $OverviewPanel.Visibility = $(if ($Name -eq "Overview") { "Visible" } else { "Collapsed" })
        $SettingsPanel.Visibility = $(if ($Name -eq "Settings") { "Visible" } else { "Collapsed" })
        $LogsPanel.Visibility = $(if ($Name -eq "Logs") { "Visible" } else { "Collapsed" })
        $DiagPanel.Visibility = $(if ($Name -eq "Diag") { "Visible" } else { "Collapsed" })

        foreach ($entry in @(
            @{ Name = "Overview"; Host = $OverviewNavHost; Indicator = $OverviewIndicator; Button = $OverviewNavButton },
            @{ Name = "Settings"; Host = $SettingsNavHost; Indicator = $SettingsIndicator; Button = $SettingsNavButton },
            @{ Name = "Logs"; Host = $LogsNavHost; Indicator = $LogsIndicator; Button = $LogsNavButton },
            @{ Name = "Diag"; Host = $DiagNavHost; Indicator = $DiagIndicator; Button = $DiagNavButton }
        )) {
            $selected = $entry.Name -eq $Name
            $entry.Host.Background = $(if ($selected) { Get-ResourceBrush -Name "SurfaceStrongBrush" } else { [System.Windows.Media.Brushes]::Transparent })
            $entry.Indicator.Visibility = $(if ($selected) { "Visible" } else { "Collapsed" })
            $entry.Button.Foreground = $(if ($selected) { Get-ResourceBrush -Name "TextBrush" } else { Get-ResourceBrush -Name "MutedBrush" })
        }
        if ($Name -eq "Logs") {
            Update-LogView
        }
    }

    function Add-ConfiguredProcess {
        $name = $ProcessInput.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            return
        }
        if ([System.IO.Path]::GetFileName($name) -ne $name -or $name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $name -match '[*?\[\]]') {
            throw "请输入不含路径或通配符的完整 exe 进程名。"
        }
        if (-not $name.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) {
            $name += ".exe"
        }
        foreach ($existing in @($script:GameNames)) {
            if ([string]::Equals([string]$existing, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $ProcessInput.Clear()
                return
            }
        }
        [void]$script:GameNames.Add($name)
        $ProcessInput.Clear()
        Set-SettingsDirty
        Update-GameList
        Update-RuleSummary
    }

    function Adjust-NumberInput {
        param(
            [Parameter(Mandatory = $true)]$TextBox,
            [Parameter(Mandatory = $true)][int]$Delta,
            [Parameter(Mandatory = $true)][int]$Minimum,
            [Parameter(Mandatory = $true)][int]$Maximum
        )
        $value = $Minimum
        [void][int]::TryParse($TextBox.Text, [ref]$value)
        $TextBox.Text = [string][math]::Max($Minimum, [math]::Min($Maximum, $value + $Delta))
        Set-SettingsDirty
    }

    function Render-WindowSnapshot {
        param([Parameter(Mandatory = $true)][string]$Path)
        $directory = Split-Path -Parent $Path
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }
        $visual = [System.Windows.FrameworkElement]$window.Content
        $width = [math]::Max(1, [int][math]::Ceiling($visual.ActualWidth))
        $height = [math]::Max(1, [int][math]::Ceiling($visual.ActualHeight))
        $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($visual)
        $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
    }

    $OverviewNavButton.Add_Click({ Show-Panel -Name "Overview" })
    $SettingsNavButton.Add_Click({ Show-Panel -Name "Settings" })
    $LogsNavButton.Add_Click({ Show-Panel -Name "Logs" })
    $DiagNavButton.Add_Click({ Show-Panel -Name "Diag" })
    $DiagRunButton.Add_Click({
        $script:NextProbeAt = [datetime]::MinValue
        Start-StatusProbe -Force
        Set-FooterMessage -Message "正在运行诊断..."
    })
    $DiagCopyButton.Add_Click({
        try {
            [System.Windows.Clipboard]::SetText((Get-DiagReportText))
            Set-FooterMessage -Message "排障报告已复制。"
        }
        catch {
            Set-FooterMessage -Message "复制失败，可手动选择文本复制。"
        }
    })

    $MonitorActionButton.Add_Click({
        if ($script:MonitorInstanceState -eq "Running") {
            Start-ControlAction -Kind "Stop"
        }
        elseif ($script:MonitorInstanceState -eq "Stopped") {
            Start-ControlAction -Kind "Start"
        }
        else {
            $script:NextLocalRefreshAt = [datetime]::MinValue
        }
    })

    $RefreshButton.Add_Click({
        $script:NextLocalRefreshAt = [datetime]::MinValue
        $script:NextLogRefreshAt = [datetime]::MinValue
        $script:NextProbeAt = [datetime]::MinValue
        Start-StatusProbe
        Set-FooterMessage -Message "正在刷新状态..."
    })

    $OpenLeigodButton.Add_Click({
        try {
            $executable = [string](Get-ConfigValue -Object $script:Config -Name "leigod_executable" -DefaultValue "")
            $shortcut = [string](Get-ConfigValue -Object $script:Config -Name "leigod_shortcut" -DefaultValue "")
            $launchTarget = Resolve-LeigodExecutableFromPaths -ExecutablePath $executable -ShortcutPath $shortcut
            if ([string]::IsNullOrWhiteSpace([string]$launchTarget)) {
                throw "无法定位本机 leigod.exe，请检查 app\config.json。"
            }
            Start-Process -FilePath $launchTarget | Out-Null
            Set-FooterMessage -Message "已打开雷神加速器。"
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "无法打开雷神", "OK", "Error") | Out-Null
        }
    })

    $AutoStartToggle.Add_Checked({
        if ($script:SuppressAutoStartEvents) { return }
        try {
            Set-AutoStartEnabled -Enabled $true
            $script:AutoStartState = $true
            $script:AutoStartCheckedAt = Get-Date
            Set-FooterMessage -Message "已启用开机自启。"
        }
        catch {
            $script:AutoStartState = $null
            [System.Windows.MessageBox]::Show($_.Exception.Message, "开机自启", "OK", "Error") | Out-Null
        }
    })
    $AutoStartToggle.Add_Unchecked({
        if ($script:SuppressAutoStartEvents) { return }
        try {
            Set-AutoStartEnabled -Enabled $false
            $script:AutoStartState = $false
            $script:AutoStartCheckedAt = Get-Date
            Set-FooterMessage -Message "已关闭开机自启；当前监控不受影响。"
        }
        catch {
            $script:AutoStartState = $null
            [System.Windows.MessageBox]::Show($_.Exception.Message, "开机自启", "OK", "Error") | Out-Null
        }
    })

    $AddProcessButton.Add_Click({ try { Add-ConfiguredProcess } catch { [System.Windows.MessageBox]::Show($_.Exception.Message, "游戏进程", "OK", "Warning") | Out-Null } })
    $ProcessInput.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq "Enter") {
            try { Add-ConfiguredProcess } catch { [System.Windows.MessageBox]::Show($_.Exception.Message, "游戏进程", "OK", "Warning") | Out-Null }
            $eventArgs.Handled = $true
        }
    })
    $RemoveProcessButton.Add_Click({
        if ($null -eq $GameList.SelectedItem) { return }
        $selected = [string]$GameList.SelectedItem.Process
        for ($index = $script:GameNames.Count - 1; $index -ge 0; $index--) {
            if ([string]::Equals([string]$script:GameNames[$index], $selected, [System.StringComparison]::OrdinalIgnoreCase)) {
                $script:GameNames.RemoveAt($index)
            }
        }
        Set-SettingsDirty
        Update-GameList
        Update-RuleSummary
    })

    # 步长必须让默认值可达：min=10、步长 30 时 120/300 都永远点不到。
    $ExitGraceMinusButton.Add_Click({ Adjust-NumberInput -TextBox $ExitGraceInput -Delta -10 -Minimum 10 -Maximum 3600 })
    $ExitGracePlusButton.Add_Click({ Adjust-NumberInput -TextBox $ExitGraceInput -Delta 10 -Minimum 10 -Maximum 3600 })
    $StartupGraceMinusButton.Add_Click({ Adjust-NumberInput -TextBox $StartupGraceInput -Delta -10 -Minimum 10 -Maximum 7200 })
    $StartupGracePlusButton.Add_Click({ Adjust-NumberInput -TextBox $StartupGraceInput -Delta 10 -Minimum 10 -Maximum 7200 })
    foreach ($descriptor in $script:SettingDescriptors) {
        $control = Get-SettingControl -Descriptor $descriptor
        if ($descriptor.Kind -eq "bool") {
            $control.Add_Checked({ Set-SettingsDirty; Update-RuleSummary })
            $control.Add_Unchecked({ Set-SettingsDirty; Update-RuleSummary })
        }
        else {
            $control.Add_TextChanged({ Set-SettingsDirty; Update-RuleSummary })
        }
    }

    $SaveSettingsButton.Add_Click({
        try {
            $wasRunning = (Get-MonitorInstanceState) -eq "Running"
            Save-Configuration
            if ($wasRunning) {
                Start-ControlAction -Kind "Restart"
            }
            else {
                $SettingsHintText.Text = "已保存，待下次启动监控生效"
                $SettingsHintText.Foreground = Get-ResourceBrush -Name "AmberBrush"
                Set-FooterMessage -Message "设置已保存，将在下次启动监控时生效。"
            }
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "设置未保存", "OK", "Warning") | Out-Null
        }
    })

    $RefreshLogButton.Add_Click({ Update-LogView; Set-FooterMessage -Message "日志已刷新。" })
    $LogSearchInput.Add_TextChanged({ Update-LogView })
    $LogLevelCombo.Add_SelectionChanged({ Update-LogView })
    $LogCopyButton.Add_Click({
        try {
            [System.Windows.Clipboard]::SetText([string]$script:LastLogPlainText)
            Set-FooterMessage -Message "已复制当前日志视图。"
        }
        catch {
            Set-FooterMessage -Message "复制失败，可改用鼠标选中后 Ctrl+C。"
        }
    })
    $OpenLogFolderButton.Add_Click({
        if (-not (Test-Path -LiteralPath $script:LogDirectory)) {
            [void](New-Item -ItemType Directory -Path $script:LogDirectory -Force)
        }
        Start-Process -FilePath (Join-Path $env:WINDIR "explorer.exe") -ArgumentList $script:LogDirectory | Out-Null
    })

    Load-Configuration
    Show-Panel -Name $InitialPanel
    Update-LogView
    Update-LocalStatus
    Start-StatusProbe

    $uiTimer = New-Object System.Windows.Threading.DispatcherTimer
    $uiTimer.Interval = [TimeSpan]::FromMilliseconds(750)
    $uiTimer.Add_Tick({
        try {
            Complete-ControlAction
            Complete-StatusProbe
            $now = Get-Date
            if ($now -ge $script:NextLocalRefreshAt) {
                Update-LocalStatus
                if ($DiagPanel.Visibility -eq "Visible") {
                    Update-DiagView
                }
                $script:NextLocalRefreshAt = $now.AddSeconds(2)
            }
            if ($now -ge $script:NextLogRefreshAt) {
                if ($LogsPanel.Visibility -eq "Visible") {
                    Update-LogView
                }
                $script:NextLogRefreshAt = $now.AddSeconds(5)
            }
            Start-StatusProbe
        }
        catch {
            Set-FooterMessage -Message ("界面刷新失败: {0}" -f $_.Exception.Message)
        }
    })
    $uiTimer.Start()

    if ($SnapshotPath) {
        $snapshotTimer = New-Object System.Windows.Threading.DispatcherTimer
        $snapshotTimer.Interval = [TimeSpan]::FromSeconds(2)
        $snapshotTimer.Add_Tick({
            $snapshotTimer.Stop()
            try { Render-WindowSnapshot -Path $SnapshotPath } finally { $window.Close() }
        })
        $snapshotTimer.Start()
    }
    elseif ($AutoCloseSeconds -gt 0) {
        $closeTimer = New-Object System.Windows.Threading.DispatcherTimer
        $closeTimer.Interval = [TimeSpan]::FromSeconds($AutoCloseSeconds)
        $closeTimer.Add_Tick({ $closeTimer.Stop(); $window.Close() })
        $closeTimer.Start()
    }

    $window.Add_Closing({
        param($sender, $eventArgs)

        if ($null -ne $script:ControlProcess) {
            if (-not $script:ControlProcess.HasExited) {
                $eventArgs.Cancel = $true
                $script:CloseAfterControl = $true
                Set-FooterMessage -Message "控制操作完成后将自动关闭控制台。"
                return
            }
            Complete-ControlAction
        }

        if ($script:SettingsDirty) {
            $choice = [System.Windows.MessageBox]::Show(
                "规则设置有未保存的修改。是否放弃修改并关闭？",
                "雷神自动暂停（非官方）",
                "YesNo",
                "Warning"
            )
            if ($choice -ne [System.Windows.MessageBoxResult]::Yes) {
                $eventArgs.Cancel = $true
            }
        }
    })

    $window.Add_Closed({
        $uiTimer.Stop()
        if ($null -ne $script:ProbeProcess -and -not $script:ProbeProcess.HasExited) {
            try { $script:ProbeProcess.Kill() } catch { }
        }
        if ($null -ne $script:ProbeProcess) {
            $script:ProbeProcess.Dispose()
            $script:ProbeProcess = $null
        }
        if ($null -ne $script:ControlProcess) {
            $script:ControlProcess.Dispose()
            $script:ControlProcess = $null
        }
    })

    [void]$window.ShowDialog()
}
finally {
    if ($ownsUiMutex) {
        try { $uiMutex.ReleaseMutex() } catch { }
    }
    $uiMutex.Dispose()
}
