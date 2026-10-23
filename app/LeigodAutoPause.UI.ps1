[CmdletBinding()]
param(
    [ValidateScript({
        if ([string]::IsNullOrWhiteSpace($_) -or $_.EndsWith(".snapshot.png", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        throw "SnapshotPath 必须以 .snapshot.png 结尾，以确保生成文件被 Git 忽略。"
    })]
    [string]$SnapshotPath = "",
    [ValidateSet("Overview", "Settings", "Logs")][string]$InitialPanel = "Overview",
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
        "LogTextBox", "FooterMessageText"
    )
    foreach ($controlName in $controlNames) {
        $control = $window.FindName($controlName)
        if ($null -eq $control) {
            throw "界面控件缺失: $controlName"
        }
        Set-Variable -Name $controlName -Value $control -Scope Script
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
        $queryName = [System.Management.Automation.WildcardPattern]::Escape($baseName)
        $currentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        return @(Get-Process -Name $queryName -ErrorAction SilentlyContinue | Where-Object {
            try {
                $_.SessionId -eq $currentSessionId -and
                    [string]::Equals($_.ProcessName, $baseName, [System.StringComparison]::OrdinalIgnoreCase)
            }
            catch {
                $false
            }
        }).Count -gt 0
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
            & $script:PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $script:MonitorScript -ConfigPath $script:ConfigPath -ValidateConfig | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "配置未通过监控器验证。"
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

            $AutoDetectGamesToggle.IsChecked = [bool](Get-ConfigValue -Object $script:Config -Name "auto_detect_launched_games" -DefaultValue $true)
            $ExitGraceInput.Text = [string](Get-ConfigValue -Object $script:Config -Name "exit_grace_seconds" -DefaultValue 120)
            $StartupGraceInput.Text = [string](Get-ConfigValue -Object $script:Config -Name "startup_grace_seconds" -DefaultValue 300)
            $PauseOnClientCloseToggle.IsChecked = [bool](Get-ConfigValue -Object $script:Config -Name "pause_if_client_closes" -DefaultValue $true)
            $NotificationsToggle.IsChecked = [bool](Get-ConfigValue -Object $script:Config -Name "notifications" -DefaultValue $true)
            $NeverStartedToggle.IsChecked = [bool](Get-ConfigValue -Object $script:Config -Name "pause_if_game_never_starts" -DefaultValue $false)
            $StaleSessionToggle.IsChecked = [bool](Get-ConfigValue -Object $script:Config -Name "pause_stale_session_on_start" -DefaultValue $false)
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
    }

    function Update-RuleSummary {
        $exitGrace = 120
        [void][int]::TryParse($ExitGraceInput.Text, [ref]$exitGrace)
        $GraceSummaryText.Text = "$exitGrace 秒"
        $ClientCloseRuleText.Text = $(if ($PauseOnClientCloseToggle.IsChecked) { "启用" } else { "关闭" })
        $GameCountText.Text = $(if ($AutoDetectGamesToggle.IsChecked) { "自动 + $($script:GameNames.Count) 个" } else { "仅 $($script:GameNames.Count) 个" })
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

        $configObject = [ordered]@{
            auto_detect_launched_games     = [bool]$AutoDetectGamesToggle.IsChecked
            game_processes                = [string[]]@($script:GameNames)
            poll_seconds                  = [int](Get-ConfigValue -Object $script:Config -Name "poll_seconds" -DefaultValue 2)
            status_poll_seconds           = [int](Get-ConfigValue -Object $script:Config -Name "status_poll_seconds" -DefaultValue 20)
            startup_grace_seconds         = $startupGrace
            exit_grace_seconds            = $exitGrace
            pause_if_client_closes        = [bool]$PauseOnClientCloseToggle.IsChecked
            pause_if_game_never_starts    = [bool]$NeverStartedToggle.IsChecked
            pause_stale_session_on_start  = [bool]$StaleSessionToggle.IsChecked
            notifications                 = [bool]$NotificationsToggle.IsChecked
            leigod_executable             = [string](Get-ConfigValue -Object $script:Config -Name "leigod_executable" -DefaultValue "")
            leigod_shortcut               = [string](Get-ConfigValue -Object $script:Config -Name "leigod_shortcut" -DefaultValue "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\雷神加速器\雷神加速器.lnk")
        }

        $temporaryPath = "$($script:ConfigPath).ui.tmp"
        try {
            $configObject | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
            & $script:PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $script:MonitorScript -ConfigPath $temporaryPath -ValidateConfig | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "新配置未通过监控器验证。"
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
            $detail = $(if ($errorText) { ($errorText -split "`r?`n")[-1] } elseif ($output) { ($output -split "`r?`n")[-1] } else { "未知错误" })
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
        if (-not $script:StatusProbeEnabled) {
            return
        }
        if ($null -ne $script:ProbeProcess -or (Get-Date) -lt $script:NextProbeAt) {
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

    function Get-LatestLogLines {
        param([ValidateRange(1, 500)][int]$Count = 200)
        if (-not (Test-Path -LiteralPath $script:LogDirectory -PathType Container)) {
            return [string[]]@()
        }
        $file = Get-ChildItem -LiteralPath $script:LogDirectory -Filter "monitor-*.log" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -eq $file) {
            return [string[]]@()
        }
        return [string[]]@(Get-Content -LiteralPath $file.FullName -Tail $Count -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    function Update-LogView {
        $lines = @(Get-LatestLogLines -Count 200)
        if ($lines.Count -eq 0) {
            $LogTextBox.Text = "暂无运行日志。"
            $ActivityText.Text = "暂无活动记录"
            $LastEventText.Text = "暂无活动记录"
            return
        }
        $LogTextBox.Text = $lines -join [Environment]::NewLine
        $LogTextBox.ScrollToEnd()
        $recent = @($lines | Select-Object -Last 4)
        $ActivityText.Text = $recent -join [Environment]::NewLine
        $LastEventText.Text = [string]$lines[-1]
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

        $script:SuppressAutoStartEvents = $true
        try {
            $AutoStartToggle.IsChecked = Test-AutoStartEnabled
        }
        finally {
            $script:SuppressAutoStartEvents = $false
        }
        Update-GameList
        Update-RuleSummary
    }

    function Show-Panel {
        param([Parameter(Mandatory = $true)][ValidateSet("Overview", "Settings", "Logs")][string]$Name)
        $OverviewPanel.Visibility = $(if ($Name -eq "Overview") { "Visible" } else { "Collapsed" })
        $SettingsPanel.Visibility = $(if ($Name -eq "Settings") { "Visible" } else { "Collapsed" })
        $LogsPanel.Visibility = $(if ($Name -eq "Logs") { "Visible" } else { "Collapsed" })

        foreach ($entry in @(
            @{ Name = "Overview"; Host = $OverviewNavHost; Indicator = $OverviewIndicator; Button = $OverviewNavButton },
            @{ Name = "Settings"; Host = $SettingsNavHost; Indicator = $SettingsIndicator; Button = $SettingsNavButton },
            @{ Name = "Logs"; Host = $LogsNavHost; Indicator = $LogsIndicator; Button = $LogsNavButton }
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
            Set-FooterMessage -Message "已启用开机自启。"
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "开机自启", "OK", "Error") | Out-Null
        }
    })
    $AutoStartToggle.Add_Unchecked({
        if ($script:SuppressAutoStartEvents) { return }
        try {
            Set-AutoStartEnabled -Enabled $false
            Set-FooterMessage -Message "已关闭开机自启；当前监控不受影响。"
        }
        catch {
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

    $ExitGraceMinusButton.Add_Click({ Adjust-NumberInput -TextBox $ExitGraceInput -Delta -30 -Minimum 10 -Maximum 3600 })
    $ExitGracePlusButton.Add_Click({ Adjust-NumberInput -TextBox $ExitGraceInput -Delta 30 -Minimum 10 -Maximum 3600 })
    $StartupGraceMinusButton.Add_Click({ Adjust-NumberInput -TextBox $StartupGraceInput -Delta -30 -Minimum 10 -Maximum 7200 })
    $StartupGracePlusButton.Add_Click({ Adjust-NumberInput -TextBox $StartupGraceInput -Delta 30 -Minimum 10 -Maximum 7200 })
    $ExitGraceInput.Add_TextChanged({ Set-SettingsDirty; Update-RuleSummary })
    $StartupGraceInput.Add_TextChanged({ Set-SettingsDirty })
    foreach ($toggle in @($AutoDetectGamesToggle, $PauseOnClientCloseToggle, $NotificationsToggle, $NeverStartedToggle, $StaleSessionToggle)) {
        $toggle.Add_Checked({ Set-SettingsDirty; Update-RuleSummary })
        $toggle.Add_Unchecked({ Set-SettingsDirty; Update-RuleSummary })
    }

    $SaveSettingsButton.Add_Click({
        try {
            $wasRunning = (Get-MonitorInstanceState) -eq "Running"
            Save-Configuration
            if ($wasRunning) {
                Start-ControlAction -Kind "Restart"
            }
            else {
                Set-FooterMessage -Message "设置已保存，将在下次启动监控时生效。"
            }
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "设置未保存", "OK", "Warning") | Out-Null
        }
    })

    $RefreshLogButton.Add_Click({ Update-LogView; Set-FooterMessage -Message "日志已刷新。" })
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
                $script:NextLocalRefreshAt = $now.AddSeconds(2)
            }
            if ($now -ge $script:NextLogRefreshAt) {
                Update-LogView
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
