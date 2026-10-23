[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [switch]$Check,
    [switch]$CheckJson,
    [switch]$IncludeSensitiveDetails,
    [switch]$ValidateConfig,
    [switch]$DryRun,
    [switch]$SelfTest,
    [int]$MaxCycles = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot "config.json"
}

$script:PauseEndpoint = "https://webapi.leigod.com/api/user/pause"
$script:InfoEndpoint = "https://webapi.leigod.com/api/user/info"
$script:LogDirectory = Join-Path $PSScriptRoot "logs"
$script:RuntimeStatePath = Join-Path $script:LogDirectory "runtime-state.json"
$script:StopMarker = Join-Path $PSScriptRoot ".stop"
$script:MonitorMutexName = "Local\LeigodAutoPauseMonitor"
$script:RuntimeStateMaxAgeSeconds = 20
# 雷神接口的业务返回码：400006 = 登录凭据失效；400803 = 账号已处于暂停状态（视为幂等成功）。
$script:TokenInvalidCode = 400006
$script:PauseAlreadyPausedCode = 400803
# 进程名快照缓存：一个轮询周期内多次判断进程状态时只枚举一次进程表。
$script:ProcessSnapshotCache = $null
$script:ProcessSnapshotAt = [datetime]::MinValue
$script:ProcessSnapshotMaxAgeSeconds = 1

. (Join-Path $PSScriptRoot "SecurityHelpers.ps1")

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $DefaultValue = $null
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }
    return $property.Value
}

function Get-StrictBooleanProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [bool]$DefaultValue
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }
    if ($property.Value -isnot [bool]) {
        throw "$Name 必须是 JSON 布尔值 true 或 false。"
    }
    return [bool]$property.Value
}

function Get-StrictIntegerProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$DefaultValue
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }
    $integerTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
    if ($integerTypes -notcontains $property.Value.GetType()) {
        throw "$Name 必须是 JSON 整数。"
    }
    if ([int64]$property.Value -lt [int]::MinValue -or [int64]$property.Value -gt [int]::MaxValue) {
        throw "$Name 超出支持范围。"
    }
    return [int]$property.Value
}

function Get-StrictStringProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyString()][string]$DefaultValue
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }
    if ($property.Value -isnot [string]) {
        throw "$Name 必须是 JSON 字符串。"
    }
    return [string]$property.Value
}

function Normalize-ProcessName {
    param([Parameter(Mandatory = $true)][string]$Name)

    $normalized = $Name.Trim()
    if ($normalized.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(0, $normalized.Length - 4)
    }
    return $normalized
}

function Read-MonitorConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到配置文件: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $source = $raw | ConvertFrom-Json

    $gameProperty = $source.PSObject.Properties["game_processes"]
    if ($null -eq $gameProperty -or $gameProperty.Value -isnot [System.Array]) {
        throw "game_processes 必须是 JSON 字符串数组。"
    }

    $processNames = @()
    foreach ($name in @($gameProperty.Value)) {
        if ($name -isnot [string]) {
            throw "game_processes 只能包含字符串。"
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$name)) {
            $normalized = Normalize-ProcessName -Name ([string]$name)
            if ([System.IO.Path]::GetFileName($normalized) -ne $normalized -or $normalized -match '[*?\[\]]') {
                throw "game_processes 必须使用不含路径或通配符的完整进程名。"
            }
            if ($normalized -and $processNames -notcontains $normalized) {
                $processNames += $normalized
            }
        }
    }

    $autoDetectLaunchedGames = Get-StrictBooleanProperty -Object $source -Name "auto_detect_launched_games" -DefaultValue $true
    if ($processNames.Count -eq 0 -and -not $autoDetectLaunchedGames) {
        throw "关闭自动识别时，game_processes 至少需要一个完整的游戏进程名。"
    }

    $config = [pscustomobject]@{
        GameProcesses             = [string[]]$processNames
        AutoDetectLaunchedGames   = $autoDetectLaunchedGames
        PollSeconds               = Get-StrictIntegerProperty -Object $source -Name "poll_seconds" -DefaultValue 2
        StatusPollSeconds         = Get-StrictIntegerProperty -Object $source -Name "status_poll_seconds" -DefaultValue 20
        StartupGraceSeconds       = Get-StrictIntegerProperty -Object $source -Name "startup_grace_seconds" -DefaultValue 300
        ExitGraceSeconds          = Get-StrictIntegerProperty -Object $source -Name "exit_grace_seconds" -DefaultValue 120
        PauseIfClientCloses       = Get-StrictBooleanProperty -Object $source -Name "pause_if_client_closes" -DefaultValue $true
        PauseIfGameNeverStarts    = Get-StrictBooleanProperty -Object $source -Name "pause_if_game_never_starts" -DefaultValue $false
        PauseStaleSessionOnStart  = Get-StrictBooleanProperty -Object $source -Name "pause_stale_session_on_start" -DefaultValue $false
        Notifications             = Get-StrictBooleanProperty -Object $source -Name "notifications" -DefaultValue $true
        LogRetentionDays          = Get-StrictIntegerProperty -Object $source -Name "log_retention_days" -DefaultValue 30
        LeigodExecutable          = Get-StrictStringProperty -Object $source -Name "leigod_executable" -DefaultValue ""
        LeigodShortcut            = Get-StrictStringProperty -Object $source -Name "leigod_shortcut" -DefaultValue "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\雷神加速器\雷神加速器.lnk"
    }

    if ($config.PollSeconds -lt 1 -or $config.PollSeconds -gt 60) {
        throw "poll_seconds 必须在 1 到 60 之间。"
    }
    if ($config.StatusPollSeconds -lt 1 -or $config.StatusPollSeconds -gt 600) {
        throw "status_poll_seconds 必须在 1 到 600 之间。"
    }
    if ($config.StartupGraceSeconds -lt 10 -or $config.StartupGraceSeconds -gt 7200) {
        throw "startup_grace_seconds 必须在 10 到 7200 之间。"
    }
    if ($config.ExitGraceSeconds -lt 10 -or $config.ExitGraceSeconds -gt 3600) {
        throw "exit_grace_seconds 必须在 10 到 3600 之间。"
    }
    if ($config.LogRetentionDays -lt 0 -or $config.LogRetentionDays -gt 3650) {
        throw "log_retention_days 必须在 0 到 3650 之间（0 表示不自动清理）。"
    }

    return $config
}

function Resolve-LeigodExecutable {
    param([Parameter(Mandatory = $true)]$Config)

    $resolvedPath = Resolve-LeigodExecutableFromPaths `
        -ExecutablePath $Config.LeigodExecutable `
        -ShortcutPath $Config.LeigodShortcut
    if ($resolvedPath) {
        return $resolvedPath
    }

    throw "无法定位本机 leigod.exe。仅接受本地磁盘上的 leigod.exe 或指向它的 .lnk 快捷方式。"
}

function Get-TokenFromText {
    param([Parameter(Mandatory = $true)][string]$Text)

    $urlMatches = [regex]::Matches($Text, "https://[^`"'\s]+", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    for ($urlIndex = $urlMatches.Count - 1; $urlIndex -ge 0; $urlIndex--) {
        try {
            $uri = [uri]$urlMatches[$urlIndex].Value.TrimEnd(")", "]", "}", ",", ";")
            $isLeigodHost = [string]::Equals($uri.Host, "leigod.com", [System.StringComparison]::OrdinalIgnoreCase) -or
                $uri.Host.EndsWith(".leigod.com", [System.StringComparison]::OrdinalIgnoreCase)
            if ($uri.Scheme -ne "https" -or -not $isLeigodHost) {
                continue
            }

            $tokenMatches = [regex]::Matches($uri.Query, "(?:[?&])account_token=([^&]+)", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($tokenMatches.Count -eq 0) {
                continue
            }
            $token = [uri]::UnescapeDataString($tokenMatches[$tokenMatches.Count - 1].Groups[1].Value)
            if ($token.Length -ge 12 -and $token.Length -le 512) {
                return $token
            }
        }
        catch {
            continue
        }
    }
    return $null
}

function Get-LatestAccountToken {
    param([Parameter(Mandatory = $true)][string]$HttpLogDirectory)

    if (-not (Test-Path -LiteralPath $HttpLogDirectory -PathType Container)) {
        return $null
    }

    $files = @(Get-ChildItem -LiteralPath $HttpLogDirectory -Filter "http-*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 5)

    foreach ($file in $files) {
        $lines = @(Get-Content -LiteralPath $file.FullName -Tail 5000 -Encoding UTF8 -ErrorAction SilentlyContinue)
        for ($index = $lines.Count - 1; $index -ge 0; $index--) {
            $token = Get-TokenFromText -Text ([string]$lines[$index])
            if ($token) {
                return $token
            }
        }
    }
    return $null
}

function ConvertTo-AutomaticGameProcessNames {
    param([AllowEmptyString()][string]$ProcessList)

    if ([string]::IsNullOrWhiteSpace($ProcessList)) {
        return [string[]]@()
    }

    $excludedNames = @(
        "leigod", "steam", "steamservice", "epicgameslauncher", "battle.net",
        "agent", "upc", "ubisoftconnect", "eadesktop", "ealauncher",
        "rockstarservice", "rockstar-games-launcher", "goggalaxy",
        "crashhandler", "crashpad_handler"
    )
    $names = @()
    foreach ($item in @($ProcessList -split ',')) {
        $candidate = ([string]$item).Trim()
        if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate.Length -gt 260) {
            continue
        }
        if ([System.IO.Path]::GetFileName($candidate) -ne $candidate -or
            $candidate.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $candidate -match '[*?\[\]]') {
            continue
        }

        $normalized = Normalize-ProcessName -Name $candidate
        if ([string]::IsNullOrWhiteSpace($normalized) -or $excludedNames -contains $normalized) {
            continue
        }
        if ($names -notcontains $normalized) {
            $names += $normalized
        }
    }
    return [string[]]$names
}

function ConvertFrom-LeigodLaunchLogLine {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)

    $pattern = '^\[(?<pid>\d+)\]\[(?<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\]\s+\[info\]\s+ipc handle launch-local-game with \[(?<payload>\{.*\})\]\s*$'
    $match = [regex]::Match($Line, $pattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) {
        return $null
    }

    $timestamp = [datetime]::MinValue
    if (-not [datetime]::TryParseExact(
        $match.Groups["timestamp"].Value,
        "yyyy-MM-dd HH:mm:ss.fff",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeLocal,
        [ref]$timestamp
    )) {
        return $null
    }

    try {
        $payload = $match.Groups["payload"].Value | ConvertFrom-Json
    }
    catch {
        return $null
    }

    $gameId = [long]0
    $rawGameId = Get-ObjectPropertyValue -Object $payload -Name "game_id" -DefaultValue $null
    if ($null -eq $rawGameId -or -not [long]::TryParse([string]$rawGameId, [ref]$gameId) -or $gameId -le 0) {
        return $null
    }

    $opProperty = $payload.PSObject.Properties["op"]
    $eventType = "Launch"
    if ($null -ne $opProperty -and $null -ne $opProperty.Value) {
        $op = [int]::MinValue
        if (-not [int]::TryParse([string]$opProperty.Value, [ref]$op) -or $op -ne 0) {
            return $null
        }
        $eventType = "Stop"
    }

    $rawProcesses = [string](Get-ObjectPropertyValue -Object $payload -Name "game_process" -DefaultValue "")
    $launchPath = [string](Get-ObjectPropertyValue -Object $payload -Name "launch_path" -DefaultValue "")
    if ($eventType -eq "Launch" -and
        [string]::IsNullOrWhiteSpace($rawProcesses) -and
        [string]::IsNullOrWhiteSpace($launchPath)) {
        return $null
    }

    $timeoutMilliseconds = 90000
    $rawTimeout = Get-ObjectPropertyValue -Object $payload -Name "timeout" -DefaultValue 90000
    $parsedTimeout = 0
    if ([int]::TryParse([string]$rawTimeout, [ref]$parsedTimeout)) {
        $timeoutMilliseconds = $parsedTimeout
    }
    $timeoutMilliseconds = [math]::Max(10000, [math]::Min(300000, $timeoutMilliseconds))
    $processNames = @(ConvertTo-AutomaticGameProcessNames -ProcessList $rawProcesses)

    return [pscustomobject]@{
        EventType     = $eventType
        Timestamp     = $timestamp
        GameId        = $gameId
        ProcessNames  = [string[]]$processNames
        TimeoutSeconds = [int][math]::Ceiling($timeoutMilliseconds / 1000.0)
    }
}

function Get-LeigodMainLogFiles {
    param([Parameter(Mandatory = $true)][string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $Directory -Filter "main-*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 10)
}

function Add-LeigodLaunchEventToTracker {
    param(
        [Parameter(Mandatory = $true)]$Tracker,
        [Parameter(Mandatory = $true)]$Event,
        [switch]$Restore
    )

    $signature = "{0}|{1}|{2}|{3}" -f $Event.Timestamp.Ticks, $Event.GameId, $Event.EventType, ($Event.ProcessNames -join ",")
    if ($Tracker.SeenEvents.ContainsKey($signature)) {
        return "Duplicate"
    }
    $Tracker.SeenEvents[$signature] = $true

    $key = [string]$Event.GameId
    $existingSession = $Tracker.Sessions[$key]
    if ($null -ne $existingSession -and [datetime]$Event.Timestamp -lt [datetime]$existingSession.LastEventAt) {
        return "OutOfOrder"
    }

    if ($Event.EventType -eq "Stop") {
        $session = $existingSession
        $processNames = [string[]]$Event.ProcessNames
        if ($null -ne $session) {
            $mergedProcesses = @()
            foreach ($name in @($session.ProcessNames + $processNames)) {
                if ($mergedProcesses -notcontains $name) {
                    $mergedProcesses += [string]$name
                }
            }
            $session.ProcessNames = [string[]]$mergedProcesses
            $session.LastEventAt = [datetime]$Event.Timestamp
            $session.PendingUntil = [datetime]$Event.Timestamp
            $session.StopObservedAt = [datetime]$Event.Timestamp
            $session.Unresolved = [bool]($mergedProcesses.Count -eq 0)
        }
        else {
            $Tracker.Sessions[$key] = [pscustomobject]@{
                GameId        = [long]$Event.GameId
                ProcessNames  = $processNames
                LastEventAt   = [datetime]$Event.Timestamp
                PendingUntil  = [datetime]$Event.Timestamp
                StopObservedAt = [datetime]$Event.Timestamp
                Unresolved    = [bool]($processNames.Count -eq 0)
            }
        }
        if (-not $Restore) {
            Write-MonitorLog -Level "INFO" -Message "雷神已结束当前加速会话；将继续监测已识别的游戏进程，直到其真正退出。"
        }
        return "Stop"
    }

    if ($Event.ProcessNames.Count -eq 0) {
        $Tracker.Sessions[$key] = [pscustomobject]@{
            GameId        = [long]$Event.GameId
            ProcessNames  = [string[]]@()
            LastEventAt   = [datetime]$Event.Timestamp
            PendingUntil  = ([datetime]$Event.Timestamp).AddSeconds($Event.TimeoutSeconds)
            StopObservedAt = $null
            Unresolved    = $true
        }
        if (-not $Restore) {
            Write-MonitorLog -Level "WARN" -Message "雷神记录了启动游戏请求，但未提供可安全使用的游戏进程名；不确定状态解除前不会执行非游戏退出触发的自动暂停。"
        }
        return "Unresolved"
    }

    $Tracker.Sessions[$key] = [pscustomobject]@{
        GameId       = [long]$Event.GameId
        ProcessNames = [string[]]$Event.ProcessNames
        LastEventAt  = [datetime]$Event.Timestamp
        PendingUntil = ([datetime]$Event.Timestamp).AddSeconds($Event.TimeoutSeconds)
        StopObservedAt = $null
        Unresolved   = $false
    }
    if (-not $Restore) {
        Write-MonitorLog -Level "INFO" -Message ("已从雷神启动事件识别游戏进程: {0}" -f ($Event.ProcessNames -join ", "))
    }
    return "Launch"
}

function Get-CompleteLeigodLogLength {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fileShare = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $fileShare)
    try {
        $position = [long]$stream.Length
        $chunkSize = 65536
        while ($position -gt 0) {
            $readStart = [math]::Max(0, $position - $chunkSize)
            $requested = [int]($position - $readStart)
            $buffer = New-Object byte[] $requested
            [void]$stream.Seek($readStart, [System.IO.SeekOrigin]::Begin)
            $bytesRead = $stream.Read($buffer, 0, $requested)
            for ($index = $bytesRead - 1; $index -ge 0; $index--) {
                if ($buffer[$index] -eq 10) {
                    return [long]($readStart + $index + 1)
                }
            }
            $position = $readStart
        }
        return [long]0
    }
    finally {
        $stream.Dispose()
    }
}

function New-LeigodLaunchTracker {
    param([Parameter(Mandatory = $true)][string]$LogDirectory)

    $tracker = [pscustomobject]@{
        StartedAt  = Get-Date
        LogDirectory = $LogDirectory
        FileOffsets = @{}
        FileCreationTicks = @{}
        SeenEvents = @{}
        Sessions = @{}
    }

    $historyEvents = @()
    $files = @(Get-LeigodMainLogFiles -Directory $LogDirectory)
    foreach ($file in @($files | Sort-Object LastWriteTime)) {
        foreach ($line in @(Get-Content -LiteralPath $file.FullName -Tail 5000 -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $event = ConvertFrom-LeigodLaunchLogLine -Line ([string]$line)
            if ($null -ne $event) {
                $historyEvents += $event
            }
        }
        try {
            $tracker.FileOffsets[$file.FullName] = Get-CompleteLeigodLogLength -Path $file.FullName
            $tracker.FileCreationTicks[$file.FullName] = [long]$file.CreationTimeUtc.Ticks
        }
        catch { }
    }

    foreach ($event in @($historyEvents | Sort-Object Timestamp)) {
        [void](Add-LeigodLaunchEventToTracker -Tracker $tracker -Event $event -Restore)
    }

    $now = Get-Date
    $currentGameId = Get-CurrentLeigodAccelerationGameId -LogDirectory $LogDirectory
    foreach ($key in @($tracker.Sessions.Keys)) {
        $session = $tracker.Sessions[$key]
        $running = @(Get-RunningConfiguredGames -ProcessNames $session.ProcessNames)
        $isCurrentUnresolved = [bool]($session.Unresolved -and $null -ne $currentGameId -and [long]$session.GameId -eq [long]$currentGameId)
        if ($running.Count -eq 0 -and $session.PendingUntil -le $now -and -not $isCurrentUnresolved) {
            [void]$tracker.Sessions.Remove($key)
        }
    }
    return $tracker
}

function Read-NewLeigodMainLogLines {
    param([Parameter(Mandatory = $true)]$Tracker)

    $lines = @()
    foreach ($file in @(Get-LeigodMainLogFiles -Directory $Tracker.LogDirectory)) {
        $path = $file.FullName
        $offset = [long]0
        if ($Tracker.FileOffsets.ContainsKey($path)) {
            $offset = [long]$Tracker.FileOffsets[$path]
        }
        $creationTicks = [long]$file.CreationTimeUtc.Ticks
        if ($Tracker.FileCreationTicks.ContainsKey($path) -and
            [long]$Tracker.FileCreationTicks[$path] -ne $creationTicks) {
            $offset = 0
        }
        $Tracker.FileCreationTicks[$path] = $creationTicks
        if ($file.Length -lt $offset) {
            $offset = 0
        }
        if ($file.Length -le $offset) {
            $Tracker.FileOffsets[$path] = [long]$file.Length
            continue
        }

        $maximumRead = [long](4 * 1024 * 1024)
        $requested = [int][math]::Min($maximumRead, $file.Length - $offset)
        $buffer = New-Object byte[] $requested
        $bytesRead = 0
        $fileShare = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = $null
        try {
            $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $fileShare)
            [void]$stream.Seek($offset, [System.IO.SeekOrigin]::Begin)
            while ($bytesRead -lt $requested) {
                $read = $stream.Read($buffer, $bytesRead, $requested - $bytesRead)
                if ($read -le 0) { break }
                $bytesRead += $read
            }
        }
        catch {
            continue
        }
        finally {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
        }

        $lastNewline = -1
        for ($index = $bytesRead - 1; $index -ge 0; $index--) {
            if ($buffer[$index] -eq 10) {
                $lastNewline = $index
                break
            }
        }
        if ($lastNewline -lt 0) {
            continue
        }

        $completeByteCount = $lastNewline + 1
        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $completeByteCount)
        $Tracker.FileOffsets[$path] = $offset + $completeByteCount
        $lines += @($text -split "`n" | ForEach-Object { ([string]$_).TrimEnd("`r") } | Where-Object { $_ })
    }
    return [string[]]$lines
}

function Update-LeigodLaunchTracker {
    param([Parameter(Mandatory = $true)]$Tracker)

    $events = @()
    foreach ($line in @(Read-NewLeigodMainLogLines -Tracker $Tracker)) {
        $event = ConvertFrom-LeigodLaunchLogLine -Line $line
        if ($null -eq $event -or $event.Timestamp -lt $Tracker.StartedAt.AddSeconds(-2)) {
            continue
        }
        $events += $event
    }
    foreach ($event in @($events | Sort-Object Timestamp)) {
        [void](Add-LeigodLaunchEventToTracker -Tracker $Tracker -Event $event)
    }
}

function Clear-LeigodLaunchTracker {
    param($Tracker)
    if ($null -ne $Tracker) {
        $Tracker.Sessions.Clear()
    }
}

function Remove-InactiveLeigodLaunchSessions {
    param($Tracker)

    if ($null -eq $Tracker) {
        return
    }
    $now = Get-Date
    foreach ($key in @($Tracker.Sessions.Keys)) {
        $session = $Tracker.Sessions[$key]
        $running = @(Get-RunningConfiguredGames -ProcessNames $session.ProcessNames)
        if ($running.Count -eq 0 -and $session.PendingUntil -le $now) {
            [void]$Tracker.Sessions.Remove($key)
        }
    }
}

function Get-AutomaticGameProcesses {
    param($Tracker)

    $names = @()
    if ($null -eq $Tracker) {
        return [string[]]$names
    }
    foreach ($session in @($Tracker.Sessions.Values)) {
        foreach ($name in @($session.ProcessNames)) {
            if ([string]::IsNullOrWhiteSpace([string]$name)) {
                continue
            }
            if ($names -notcontains [string]$name) {
                $names += [string]$name
            }
        }
    }
    return [string[]]$names
}

function Merge-ProcessNameList {
    <#
    .SYNOPSIS
        合并多个进程名来源，去空、去重，返回干净的进程名数组。
    .DESCRIPTION
        空集合经 PowerShell 管道会被展平成 $null，而“数组 + $null”会追加一个 null 元素，
        再转成字符串就变成空串，最终让 Get-Process -Name "" 抛异常。所有拼接都必须走这里。
    #>
    param([AllowNull()][AllowEmptyCollection()][object]$NameList)

    $merged = @()
    foreach ($name in @($NameList)) {
        $candidate = ([string]$name).Trim()
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if ($merged -notcontains $candidate) {
            $merged += $candidate
        }
    }
    return [string[]]$merged
}

function Get-CurrentLeigodAccelerationGameId {
    param([Parameter(Mandatory = $true)][string]$LogDirectory)

    try {
        $resourcesDirectory = Split-Path -Parent $LogDirectory
        $dataCenter = Join-Path $resourcesDirectory "leishenSdk\datacenter"
        $traitPath = Join-Path $dataCenter "acc_trait.json"
        $accingPath = Join-Path $dataCenter "accing.txt"
        if (-not (Test-Path -LiteralPath $traitPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $accingPath -PathType Leaf)) {
            return $null
        }

        $now = Get-Date
        $traitFile = Get-Item -LiteralPath $traitPath
        $accingFile = Get-Item -LiteralPath $accingPath
        # accing.txt is a launch marker; acc_trait.json is the live acceleration heartbeat.
        if (($now - $traitFile.LastWriteTime).TotalSeconds -gt 45) {
            return $null
        }

        $trait = Get-Content -LiteralPath $traitPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $traitId = [long]0
        if (-not [long]::TryParse([string](Get-ObjectPropertyValue -Object $trait -Name "game_id" -DefaultValue ""), [ref]$traitId) -or $traitId -le 0) {
            return $null
        }

        $accing = (Get-Content -LiteralPath $accingPath -Raw -Encoding UTF8).Trim()
        $accingMatch = [regex]::Match($accing, '(?:^|,)(?<game_id>\d+)\s*$')
        $accingId = [long]0
        if (-not $accingMatch.Success -or
            -not [long]::TryParse($accingMatch.Groups["game_id"].Value, [ref]$accingId) -or
            $accingId -ne $traitId) {
            return $null
        }
        return $traitId
    }
    catch {
        return $null
    }
}

function Get-GameActivity {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$LogDirectory,
        $Tracker,
        [switch]$RefreshTracker
    )

    if ($RefreshTracker -and $null -ne $Tracker) {
        Update-LeigodLaunchTracker -Tracker $Tracker
    }

    $manualTargets = [string[]]$Config.GameProcesses
    $automaticTargets = [string[]]$(Get-AutomaticGameProcesses -Tracker $Tracker)
    $manualRunning = @(Get-RunningConfiguredGames -ProcessNames $manualTargets)
    $automaticRunning = @(Get-RunningConfiguredGames -ProcessNames $automaticTargets)
    $currentGameId = $(if ($Config.AutoDetectLaunchedGames) { Get-CurrentLeigodAccelerationGameId -LogDirectory $LogDirectory } else { $null })
    if ($null -ne $Tracker -and $null -ne $currentGameId -and $manualRunning.Count -gt 0) {
        foreach ($session in @($Tracker.Sessions.Values)) {
            if ([long]$session.GameId -eq [long]$currentGameId -and
                [bool](Get-ObjectPropertyValue -Object $session -Name "Unresolved" -DefaultValue $false)) {
                $session.ProcessNames = [string[]]$manualRunning
                $session.Unresolved = $false
                Write-MonitorLog -Level "INFO" -Message ("已用手动补充进程确认当前雷神游戏: {0}" -f ($manualRunning -join ", "))
            }
        }
    }
    $associatedTargets = @()
    $pending = $false
    $unresolved = $false
    if ($null -ne $Tracker) {
        foreach ($session in @($Tracker.Sessions.Values)) {
            if ($session.PendingUntil -gt (Get-Date)) {
                $pending = $true
            }
            if ($null -ne $currentGameId -and [long]$session.GameId -eq [long]$currentGameId) {
                $associatedTargets += @(Merge-ProcessNameList -NameList $session.ProcessNames)
            }
            if ([bool](Get-ObjectPropertyValue -Object $session -Name "Unresolved" -DefaultValue $false)) {
                $unresolved = $true
            }
        }
    }
    $associatedRunning = @(Get-RunningConfiguredGames -ProcessNames (Merge-ProcessNameList -NameList $associatedTargets))

    $targets = @(Merge-ProcessNameList -NameList (@($manualTargets) + @($automaticTargets)))
    $running = @(Merge-ProcessNameList -NameList (@($manualRunning) + @($automaticRunning)))

    return [pscustomobject]@{
        TargetProcesses       = [string[]]$targets
        AutomaticProcesses    = [string[]]$automaticTargets
        RunningGames          = [string[]]$running
        ManualRunningGames    = [string[]]$manualRunning
        AssociatedRunningGames = [string[]]$associatedRunning
        LaunchPending         = [bool]$pending
        UnresolvedLaunch      = [bool]$unresolved
        CurrentGameIdConfirmed = [bool]($null -ne $currentGameId)
        CanConfirmSession     = [bool]($manualRunning.Count -gt 0 -or $associatedRunning.Count -gt 0)
    }
}

function ConvertTo-AccountState {
    param($Response)

    if ($null -eq $Response) {
        return [pscustomobject]@{ State = "Unknown"; Code = $null; Message = "空响应" }
    }

    $code = Get-ObjectPropertyValue -Object $Response -Name "code" -DefaultValue $null
    $message = [string](Get-ObjectPropertyValue -Object $Response -Name "msg" -DefaultValue "")
    if ($null -eq $code -or [int]$code -ne 0) {
        return [pscustomobject]@{ State = "Unknown"; Code = $code; Message = $message }
    }

    $data = Get-ObjectPropertyValue -Object $Response -Name "data" -DefaultValue $null
    if ($null -eq $data) {
        return [pscustomobject]@{ State = "Unknown"; Code = $code; Message = "响应缺少 data" }
    }
    $pauseStatus = Get-ObjectPropertyValue -Object $data -Name "pause_status_id" -DefaultValue $null
    if ($null -eq $pauseStatus) {
        return [pscustomobject]@{ State = "Unknown"; Code = $code; Message = "响应缺少 pause_status_id" }
    }

    if ([int]$pauseStatus -eq 1) {
        return [pscustomobject]@{ State = "Paused"; Code = $code; Message = $message }
    }
    if ([int]$pauseStatus -eq 0) {
        return [pscustomobject]@{ State = "Active"; Code = $code; Message = $message }
    }
    return [pscustomobject]@{ State = "Unknown"; Code = $code; Message = "未知 pause_status_id" }
}

function Get-HttpFailureReason {
    <# 把网络异常压缩成一行可诊断信息（异常类型 + 连接状态 + HTTP 状态码），不包含请求内容。 #>
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $reason = $ErrorRecord.Exception.GetType().Name
    try {
        $status = Get-ObjectPropertyValue -Object $ErrorRecord.Exception -Name "Status" -DefaultValue $null
        if ($null -ne $status) {
            $reason = "{0}/{1}" -f $reason, $status
        }
    }
    catch { }
    try {
        $response = Get-ObjectPropertyValue -Object $ErrorRecord.Exception -Name "Response" -DefaultValue $null
        if ($null -ne $response) {
            $statusCode = Get-ObjectPropertyValue -Object $response -Name "StatusCode" -DefaultValue $null
            if ($null -ne $statusCode) {
                $reason = "{0}/HTTP {1}" -f $reason, [int]$statusCode
            }
        }
    }
    catch { }
    return $reason
}

function Get-LeigodAccountState {
    param([Parameter(Mandatory = $true)][string]$Token)

    try {
        $body = @{
            account_token = $Token
            lang = "zh_CN"
            os_type = 4
        }
        $response = Invoke-RestMethod -Uri $script:InfoEndpoint -Method Post -Body $body -ContentType "application/x-www-form-urlencoded; charset=UTF-8" -TimeoutSec 8 -UseBasicParsing -MaximumRedirection 0
        return ConvertTo-AccountState -Response $response
    }
    catch {
        return [pscustomobject]@{
            State   = "Unknown"
            Code    = $null
            Message = ("状态请求失败({0})" -f (Get-HttpFailureReason -ErrorRecord $_))
        }
    }
}

function Invoke-LeigodPause {
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [switch]$WhatIfOnly
    )

    if ($WhatIfOnly) {
        return [pscustomobject]@{ Success = $true; Code = "DRY_RUN"; Message = "dry-run 未发送暂停请求" }
    }

    try {
        $body = @{
            account_token = $Token
            lang = "zh_CN"
            os_type = 4
        } | ConvertTo-Json -Compress
        $response = Invoke-RestMethod -Uri $script:PauseEndpoint -Method Post -Body $body -ContentType "application/json; charset=UTF-8" -TimeoutSec 8 -UseBasicParsing -MaximumRedirection 0
        $code = Get-ObjectPropertyValue -Object $response -Name "code" -DefaultValue $null
        $message = [string](Get-ObjectPropertyValue -Object $response -Name "msg" -DefaultValue "")
        $success = $null -ne $code -and ([int]$code -eq 0 -or [int]$code -eq $script:PauseAlreadyPausedCode)
        return [pscustomobject]@{ Success = $success; Code = $code; Message = $message }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Code    = $null
            Message = ("暂停请求失败({0})" -f (Get-HttpFailureReason -ErrorRecord $_))
        }
    }
}

function Get-RunningProcessNameSet {
    <#
    .SYNOPSIS
        返回当前 Windows 登录会话内所有进程名的集合（大小写不敏感）。
    .DESCRIPTION
        默认复用 1 秒内的快照。一个轮询周期里会多次判断进程状态，逐个进程名调用
        Get-Process 会把整张进程表重复枚举很多遍（实测 589 个进程时约 13.6 ms/名字），
        改成每周期一次快照后开销降到一次枚举。
    #>
    param([switch]$Refresh)

    $now = Get-Date
    if (-not $Refresh -and
        $null -ne $script:ProcessSnapshotCache -and
        ($now - $script:ProcessSnapshotAt).TotalSeconds -lt $script:ProcessSnapshotMaxAgeSeconds) {
        Write-Output -NoEnumerate $script:ProcessSnapshotCache
        return
    }

    $nameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $currentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if ($process.SessionId -eq $currentSessionId -and
                -not [string]::IsNullOrWhiteSpace([string]$process.ProcessName)) {
                [void]$nameSet.Add([string]$process.ProcessName)
            }
        }
        catch { }
    }

    $script:ProcessSnapshotCache = $nameSet
    $script:ProcessSnapshotAt = $now
    Write-Output -NoEnumerate $script:ProcessSnapshotCache
}

function Get-RunningConfiguredGames {
    param([AllowNull()][AllowEmptyCollection()][string[]]$ProcessNames)

    $running = @()
    if ($null -eq $ProcessNames) {
        return [string[]]$running
    }
    # 注意：PowerShell 5.1 下 @($null) 是含一个 null 元素的数组，不能直接用 @($x).Count 判空。
    $requested = @($ProcessNames)
    if ($requested.Count -eq 0) {
        return [string[]]$running
    }

    $nameSet = Get-RunningProcessNameSet
    foreach ($name in $requested) {
        # 空进程名会让 Get-Process 抛参数绑定异常并终止整个监控，这里必须先挡掉。
        $candidate = ([string]$name).Trim()
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if ($nameSet.Contains($candidate) -and $running -notcontains $candidate) {
            $running += $candidate
        }
    }
    return [string[]]$running
}

function Test-LeigodClientRunning {
    $nameSet = Get-RunningProcessNameSet
    return $nameSet.Contains("leigod")
}

function Write-MonitorLog {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("INFO", "WARN", "ERROR")][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    # 写日志失败绝不能反过来杀死监控：权限、磁盘被占用、杀软扫描都会让这里抛异常。
    try {
        if (-not (Test-Path -LiteralPath $script:LogDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $script:LogDirectory -Force)
        }
        Add-Content -LiteralPath (Join-Path $script:LogDirectory ("monitor-{0}.log" -f (Get-Date -Format "yyyy-MM-dd"))) -Value $line -Encoding UTF8
    }
    catch { }
    Write-Host $line
}

function Remove-ExpiredMonitorLogs {
    param([int]$RetentionDays)

    if ($RetentionDays -le 0) {
        return
    }
    try {
        if (-not (Test-Path -LiteralPath $script:LogDirectory -PathType Container)) {
            return
        }
        $threshold = (Get-Date).Date.AddDays(-1 * $RetentionDays)
        $removed = 0
        foreach ($file in @(Get-ChildItem -LiteralPath $script:LogDirectory -Filter "monitor-*.log" -File -ErrorAction SilentlyContinue)) {
            if ($file.LastWriteTime -ge $threshold) {
                continue
            }
            try {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                $removed++
            }
            catch { }
        }
        if ($removed -gt 0) {
            Write-MonitorLog -Level "INFO" -Message ("已按保留策略清理 {0} 个过期日志文件（保留 {1} 天）。" -f $removed, $RetentionDays)
        }
    }
    catch { }
}

function Get-MonitorRuntimeState {
    try {
        if (-not (Test-Path -LiteralPath $script:RuntimeStatePath -PathType Leaf)) {
            return $null
        }
        $state = Get-Content -LiteralPath $script:RuntimeStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $updatedAt = [datetime]::MinValue
        if (-not [datetime]::TryParse(
            [string](Get-ObjectPropertyValue -Object $state -Name "updated_at" -DefaultValue ""),
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$updatedAt
        ) -or ((Get-Date) - $updatedAt.ToLocalTime()).TotalSeconds -gt $script:RuntimeStateMaxAgeSeconds) {
            return $null
        }

        $monitorPid = [int]0
        if (-not [int]::TryParse([string](Get-ObjectPropertyValue -Object $state -Name "monitor_pid" -DefaultValue ""), [ref]$monitorPid) -or $monitorPid -le 0) {
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

function Write-MonitorRuntimeState {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$AccountState,
        [Parameter(Mandatory = $true)]$Activity,
        [Parameter(Mandatory = $true)][bool]$AutoDetectionEnabled,
        [Parameter(Mandatory = $true)][bool]$Force,
        [ref]$LastSignature,
        [ref]$LastWriteAt
    )

    $signature = "{0}|{1}|{2}|{3}|{4}|{5}" -f $State, $AccountState, $Activity.LaunchPending, $Activity.UnresolvedLaunch, ($Activity.TargetProcesses -join ","), ($Activity.RunningGames -join ",")
    if (-not $Force -and
        $signature -eq [string]$LastSignature.Value -and
        ((Get-Date) - [datetime]$LastWriteAt.Value).TotalSeconds -lt 10) {
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $script:LogDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $script:LogDirectory -Force)
        }
    }
    catch {
        return
    }
    $runtime = [ordered]@{
        schema_version        = 1
        updated_at            = (Get-Date).ToUniversalTime().ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
        monitor_pid           = $PID
        session_id            = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        state                 = $State
        account_state         = $AccountState
        auto_detection        = $AutoDetectionEnabled
        launch_pending        = [bool]$Activity.LaunchPending
        unresolved_launch     = [bool]$Activity.UnresolvedLaunch
        association_confirmed = [bool]$Activity.CanConfirmSession
        target_processes      = [string[]]$Activity.TargetProcesses
        automatic_processes   = [string[]]$Activity.AutomaticProcesses
        running_games         = [string[]]$Activity.RunningGames
    }
    $temporaryPath = "$($script:RuntimeStatePath).$PID.tmp"
    try {
        $runtime | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $script:RuntimeStatePath -Force
        $LastSignature.Value = $signature
        $LastWriteAt.Value = Get-Date
    }
    catch {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-MonitorRuntimeState {
    try {
        if (-not (Test-Path -LiteralPath $script:RuntimeStatePath -PathType Leaf)) {
            return
        }
        $state = Get-Content -LiteralPath $script:RuntimeStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int](Get-ObjectPropertyValue -Object $state -Name "monitor_pid" -DefaultValue 0) -eq $PID) {
            Remove-Item -LiteralPath $script:RuntimeStatePath -Force
        }
    }
    catch { }
}

function Show-MonitorNotification {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )

    if (-not $Enabled) {
        return
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $notification = New-Object System.Windows.Forms.NotifyIcon
        try {
            $notification.Icon = [System.Drawing.SystemIcons]::Information
            $notification.Visible = $true
            $notification.BalloonTipTitle = $Title
            $notification.BalloonTipText = $Message
            $notification.ShowBalloonTip(5000)
            Start-Sleep -Milliseconds 750
        }
        finally {
            $notification.Visible = $false
            $notification.Dispose()
        }
    }
    catch {
        Write-MonitorLog -Level "WARN" -Message "系统通知显示失败，监控不受影响。"
    }
}

function Format-Countdown {
    param([Parameter(Mandatory = $true)][datetime]$Deadline)

    $seconds = [math]::Max(0, [int][math]::Ceiling(($Deadline - (Get-Date)).TotalSeconds))
    $minutes = [int][math]::Floor($seconds / 60)
    $remainingSeconds = [int]($seconds % 60)
    return "{0:D2}:{1:D2}" -f $minutes, $remainingSeconds
}

function Start-CountdownState {
    param(
        [Parameter(Mandatory = $true)][string]$NewState,
        [Parameter(Mandatory = $true)][int]$Seconds,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)]$Config
    )

    $deadline = (Get-Date).AddSeconds($Seconds)
    Write-MonitorLog -Level "INFO" -Message ("{0}；若未检测到游戏，将在 {1} 秒后进行安全复核并暂停时长。" -f $Reason, $Seconds)
    Show-MonitorNotification -Title "雷神自动暂停（非官方）" -Message ("{0}，{1} 秒后复核并自动暂停。" -f $Reason, $Seconds) -Enabled $Config.Notifications
    return [pscustomobject]@{ State = $NewState; Deadline = $deadline }
}

function Invoke-PauseAfterFinalCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$HttpLogDirectory,
        [Parameter(Mandatory = $true)][bool]$DryRunEnabled,
        [Parameter(Mandatory = $true)]$Config,
        $LaunchTracker,
        [Parameter(Mandatory = $true)][string]$CountdownState
    )

    if (Test-Path -LiteralPath $script:StopMarker) {
        Write-MonitorLog -Level "INFO" -Message "暂停前收到停止标记，本次不执行。"
        return "Stopped"
    }

    $latestToken = Get-LatestAccountToken -HttpLogDirectory $HttpLogDirectory
    if (-not $latestToken -or
        -not [string]::Equals($latestToken, $Token, [System.StringComparison]::Ordinal)) {
        Write-MonitorLog -Level "WARN" -Message "暂停前发现当前登录凭据已变化或无法确认，取消本轮自动暂停。"
        return "TokenChanged"
    }

    $finalActivity = Get-GameActivity -Config $Config -LogDirectory $HttpLogDirectory -Tracker $LaunchTracker -RefreshTracker
    if ($finalActivity.UnresolvedLaunch) {
        Write-MonitorLog -Level "WARN" -Message "暂停前即时复核仍存在无法确认进程名的雷神游戏会话，本次不执行。"
        return "UnresolvedGame"
    }
    if ($finalActivity.LaunchPending) {
        Write-MonitorLog -Level "INFO" -Message "暂停前即时复核发现雷神正在启动游戏，取消自动暂停。"
        return "GameStarting"
    }
    if ($finalActivity.RunningGames.Count -gt 0) {
        Write-MonitorLog -Level "INFO" -Message ("暂停前即时复核发现游戏正在运行，取消自动暂停: {0}" -f ($finalActivity.RunningGames -join ", "))
        return "GameRunning"
    }

    if ($CountdownState -in @("AfterClientExit", "StaleSession") -and (Test-LeigodClientRunning)) {
        Write-MonitorLog -Level "INFO" -Message "暂停前即时复核发现雷神客户端已重新启动，取消自动暂停。"
        return "ClientRunning"
    }

    Write-MonitorLog -Level "INFO" -Message "宽限期已结束，正在进行暂停前安全复核。"
    $finalState = Get-LeigodAccountState -Token $Token
    if ($finalState.State -eq "Paused") {
        Write-MonitorLog -Level "INFO" -Message "暂停前复核：账号已经暂停，无需重复操作。"
        return "Completed"
    }
    if ($finalState.State -ne "Active") {
        Write-MonitorLog -Level "WARN" -Message ("暂停前复核无法确认账号正在计时（{0}），本次不执行。" -f $finalState.Message)
        return "Retry"
    }

    if (Test-Path -LiteralPath $script:StopMarker) {
        Write-MonitorLog -Level "INFO" -Message "账号复核后收到停止标记，本次不执行。"
        return "Stopped"
    }

    $immediateActivity = Get-GameActivity -Config $Config -LogDirectory $HttpLogDirectory -Tracker $LaunchTracker -RefreshTracker
    if ($immediateActivity.UnresolvedLaunch) {
        Write-MonitorLog -Level "WARN" -Message "账号复核后仍存在无法确认进程名的雷神游戏会话，本次不执行。"
        return "UnresolvedGame"
    }
    if ($immediateActivity.LaunchPending) {
        Write-MonitorLog -Level "INFO" -Message "账号复核后发现雷神正在启动游戏，取消自动暂停。"
        return "GameStarting"
    }
    if ($immediateActivity.RunningGames.Count -gt 0) {
        Write-MonitorLog -Level "INFO" -Message ("账号复核后发现游戏正在运行，取消自动暂停: {0}" -f ($immediateActivity.RunningGames -join ", "))
        return "GameRunning"
    }

    if ($CountdownState -in @("AfterClientExit", "StaleSession") -and (Test-LeigodClientRunning)) {
        Write-MonitorLog -Level "INFO" -Message "账号复核后发现雷神客户端已重新启动，取消自动暂停。"
        return "ClientRunning"
    }

    $latestToken = Get-LatestAccountToken -HttpLogDirectory $HttpLogDirectory
    if (-not $latestToken -or
        -not [string]::Equals($latestToken, $Token, [System.StringComparison]::Ordinal)) {
        Write-MonitorLog -Level "WARN" -Message "账号复核后发现当前登录凭据已变化或无法确认，取消本轮自动暂停。"
        return "TokenChanged"
    }

    $result = Invoke-LeigodPause -Token $Token -WhatIfOnly:$DryRunEnabled
    if ($result.Success) {
        if ($DryRunEnabled) {
            Write-MonitorLog -Level "INFO" -Message "dry-run：所有暂停条件均满足，但未发送暂停请求。"
            Show-MonitorNotification -Title "雷神自动暂停（非官方演练）" -Message "已满足暂停条件；演练模式未执行。" -Enabled $Config.Notifications
            return "Completed"
        }

        Write-MonitorLog -Level "INFO" -Message "暂停请求已接受，正在确认账号状态。"
        Start-Sleep -Milliseconds 750
        $confirmedState = Get-LeigodAccountState -Token $Token
        if ($confirmedState.State -eq "Paused") {
            Write-MonitorLog -Level "INFO" -Message ("暂停成功，接口返回代码: {0}。" -f $result.Code)
            Show-MonitorNotification -Title "雷神自动暂停（非官方）" -Message "安全复核完成，雷神时长已暂停。" -Enabled $Config.Notifications
            return "Completed"
        }

        Write-MonitorLog -Level "WARN" -Message "暂停接口已响应，但复核时未确认账号已暂停，将稍后重试。"
        return "Retry"
    }

    Write-MonitorLog -Level "ERROR" -Message ("暂停失败，接口返回代码: {0}；{1}。" -f $result.Code, $result.Message)
    return "Retry"
}

function Invoke-CheckMode {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$LeigodExecutable,
        [Parameter(Mandatory = $true)][string]$HttpLogDirectory,
        [Parameter(Mandatory = $true)][bool]$JsonOutput,
        [Parameter(Mandatory = $true)][bool]$SensitiveDetailsEnabled
    )

    $runtimeState = Get-MonitorRuntimeState
    $runningGames = @(Get-RunningConfiguredGames -ProcessNames $Config.GameProcesses)
    $targetProcesses = [string[]]$Config.GameProcesses
    $automaticProcesses = [string[]]@()
    if ($null -ne $runtimeState) {
        $runningGames = [string[]]@(Get-ObjectPropertyValue -Object $runtimeState -Name "running_games" -DefaultValue @())
        $targetProcesses = [string[]]@(Get-ObjectPropertyValue -Object $runtimeState -Name "target_processes" -DefaultValue @())
        $automaticProcesses = [string[]]@(Get-ObjectPropertyValue -Object $runtimeState -Name "automatic_processes" -DefaultValue @())
    }
    $token = Get-LatestAccountToken -HttpLogDirectory $HttpLogDirectory
    $accountState = "Unavailable"
    if ($token) {
        $accountState = (Get-LeigodAccountState -Token $token).State
    }

    $result = [pscustomobject]@{
        ConfigPath          = $(if ($SensitiveDetailsEnabled) { $ConfigPath } else { [System.IO.Path]::GetFileName($ConfigPath) })
        LeigodExecutable    = $(if ($SensitiveDetailsEnabled) { $LeigodExecutable } else { [System.IO.Path]::GetFileName($LeigodExecutable) })
        LeigodRunning       = Test-LeigodClientRunning
        HttpLogDirectory    = $(if ($SensitiveDetailsEnabled) { $HttpLogDirectory } else { [System.IO.Path]::GetFileName($HttpLogDirectory) })
        TokenFound          = [bool]$token
        AccountState        = $accountState
        ConfiguredProcesses = [string[]]$(if ($SensitiveDetailsEnabled) { $Config.GameProcesses } else { @() })
        DetectedProcesses   = [string[]]$(if ($SensitiveDetailsEnabled) { $automaticProcesses } else { @() })
        RunningGames        = [string[]]$(if ($SensitiveDetailsEnabled) { $runningGames } else { @() })
        AutoDetectionEnabled = [bool]$Config.AutoDetectLaunchedGames
        ConfiguredGameCount = [int]$Config.GameProcesses.Count
        DetectedGameCount   = [int]$automaticProcesses.Count
        TargetGameCount     = [int]$targetProcesses.Count
        RunningGameCount    = [int]$runningGames.Count
        ReadyToMonitor      = [bool]($token -and $accountState -in @("Active", "Paused") -and ($Config.AutoDetectLaunchedGames -or $Config.GameProcesses.Count -gt 0))
    }

    if ($JsonOutput) {
        $result | ConvertTo-Json -Compress -Depth 4
    }
    else {
        [pscustomobject]@{
            ConfigPath          = $result.ConfigPath
            LeigodExecutable    = $result.LeigodExecutable
            LeigodRunning       = $result.LeigodRunning
            HttpLogDirectory    = $result.HttpLogDirectory
            TokenFound          = $result.TokenFound
            AccountState        = $result.AccountState
            ConfiguredProcesses = $result.ConfiguredProcesses -join ", "
            DetectedProcesses   = $result.DetectedProcesses -join ", "
            RunningGames        = $result.RunningGames -join ", "
            AutoDetectionEnabled = $result.AutoDetectionEnabled
            ReadyToMonitor      = $result.ReadyToMonitor
        } | Format-List
    }
}

function Invoke-SelfTest {
    $failures = @()

    try {
        if ((Normalize-ProcessName -Name " ExampleGame.EXE ") -ne "ExampleGame") {
            throw "进程名标准化失败"
        }
        if (@(Get-RunningConfiguredGames -ProcessNames $null).Count -ne 0) {
            throw "空动态目标集合未被安全处理"
        }
    }
    catch { $failures += $_.Exception.Message }

    try {
        if ($null -ne (ConvertFrom-LeigodLaunchLogLine -Line "")) {
            throw "空日志行未被安全忽略"
        }
        $launchLine = '[1000][2026-01-01 00:00:01.000] [info]  ipc handle launch-local-game with [{"game_id":42,"launch_path":"example://launch/42","game_process":"ExampleGame.exe,ExampleGameWorker.exe","timeout":90000}]'
        $launchEvent = ConvertFrom-LeigodLaunchLogLine -Line $launchLine
        if ($null -eq $launchEvent -or
            $launchEvent.EventType -ne "Launch" -or
            $launchEvent.GameId -ne 42 -or
            $launchEvent.TimeoutSeconds -ne 90 -or
            $launchEvent.ProcessNames.Count -ne 2 -or
            $launchEvent.ProcessNames -notcontains "ExampleGameWorker") {
            throw "雷神启动事件解析失败"
        }

        $stopLine = '[1000][2026-01-01 00:00:02.000] [info]  ipc handle launch-local-game with [{"op":0,"game_id":42,"game_process":"ExampleGame.exe"}]'
        $stopEvent = ConvertFrom-LeigodLaunchLogLine -Line $stopLine
        if ($null -eq $stopEvent -or $stopEvent.EventType -ne "Stop") {
            throw "雷神停止事件解析失败"
        }

        $filteredLine = '[1000][2026-01-01 00:00:03.000] [info]  ipc handle launch-local-game with [{"game_id":42,"launch_path":"example://launch/42","game_process":"steam.exe,crashpad_handler.exe,ValidGame.exe"}]'
        $filteredEvent = ConvertFrom-LeigodLaunchLogLine -Line $filteredLine
        if ($filteredEvent.ProcessNames.Count -ne 1 -or $filteredEvent.ProcessNames[0] -ne "ValidGame") {
            throw "自动进程安全过滤失败"
        }
    }
    catch { $failures += $_.Exception.Message }

    $launchTestRoot = Join-Path $env:TEMP ("LeigodLaunchTrackerTest-" + [guid]::NewGuid().ToString("N"))
    $previousLogDirectory = $script:LogDirectory
    try {
        [void](New-Item -ItemType Directory -Path $launchTestRoot -Force)
        $script:LogDirectory = $launchTestRoot
        $launchLog = Join-Path $launchTestRoot "main-self-test.log"
        $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $dynamicLine = '[1][{0}] [info]  ipc handle launch-local-game with [{{"game_id":7,"launch_path":"test","game_process":"DynamicGame.exe,DynamicWorker.exe","timeout":10000}}]' -f $timestamp
        $splitAt = [int]($dynamicLine.Length / 2)
        [System.IO.File]::WriteAllText($launchLog, $dynamicLine.Substring(0, $splitAt), $utf8WithoutBom)
        $tracker = New-LeigodLaunchTracker -LogDirectory $launchTestRoot
        Update-LeigodLaunchTracker -Tracker $tracker
        if ($tracker.Sessions.Count -ne 0) {
            throw "增量日志读取错误处理了未完成行"
        }
        [System.IO.File]::AppendAllText($launchLog, $dynamicLine.Substring($splitAt) + "`r`n", $utf8WithoutBom)
        Update-LeigodLaunchTracker -Tracker $tracker
        if ($tracker.Sessions.Count -ne 1 -or
            $tracker.Sessions["7"].ProcessNames.Count -ne 2 -or
            $tracker.Sessions["7"].ProcessNames -notcontains "DynamicWorker") {
            throw "启动时半行恢复或多进程识别失败"
        }

        $stopLine = '[1][{0}] [info]  ipc handle launch-local-game with [{{"op":0,"game_id":7,"game_process":"DynamicGame.exe"}}]' -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff")
        [System.IO.File]::AppendAllText($launchLog, $stopLine + "`r`n", $utf8WithoutBom)
        Update-LeigodLaunchTracker -Tracker $tracker
        if ($null -eq $tracker.Sessions["7"].StopObservedAt -or
            $tracker.Sessions["7"].ProcessNames.Count -ne 2 -or
            $tracker.Sessions["7"].ProcessNames -notcontains "DynamicWorker") {
            throw "停止加速事件错误清除或缩窄了仍需监测的游戏目标"
        }

        $oldStopEvent = [pscustomobject]@{
            EventType = "Stop"
            Timestamp = ([datetime]$tracker.Sessions["7"].LastEventAt).AddMilliseconds(-1)
            GameId = [long]7
            ProcessNames = [string[]]@("DynamicGame")
            TimeoutSeconds = 90
        }
        $oldStopOutcome = Add-LeigodLaunchEventToTracker -Tracker $tracker -Event $oldStopEvent -Restore
        if ($oldStopOutcome -ne "OutOfOrder" -or $tracker.Sessions["7"].ProcessNames.Count -ne 2) {
            throw "乱序停止事件覆盖了较新的多进程目标"
        }
        Remove-InactiveLeigodLaunchSessions -Tracker $tracker
        if ($tracker.Sessions.Count -ne 0) {
            throw "已停止且未运行的动态目标未被清理"
        }

        $unknownLine = '[1][{0}] [info]  ipc handle launch-local-game with [{{"game_id":8,"launch_path":"test","game_process":"","timeout":10000}}]' -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff")
        [System.IO.File]::AppendAllText($launchLog, $unknownLine + "`r`n", $utf8WithoutBom)
        Update-LeigodLaunchTracker -Tracker $tracker
        if ($null -eq $tracker.Sessions["8"] -or -not $tracker.Sessions["8"].Unresolved) {
            throw "缺少进程名的启动事件未进入保守保护状态"
        }
    }
    catch { $failures += $_.Exception.Message }
    finally {
        $script:LogDirectory = $previousLogDirectory
        if (Test-Path -LiteralPath $launchTestRoot) {
            Remove-Item -LiteralPath $launchTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    try {
        $sample = '[1][2026-01-01] [get] "https://api2.leigod.com/client/pause/status?a=1&account_token=TEST_ACCOUNT_TOKEN&lang=zh_CN"'
        if ((Get-TokenFromText -Text $sample) -ne "TEST_ACCOUNT_TOKEN") {
            throw "token 提取失败"
        }
        $foreignSample = 'https://leigod.com.example.invalid/x?account_token=TEST_ACCOUNT_TOKEN'
        if ($null -ne (Get-TokenFromText -Text $foreignSample)) {
            throw "非雷神域名 token 未被拒绝"
        }
    }
    catch { $failures += $_.Exception.Message }

    try {
        $active = ConvertTo-AccountState -Response ([pscustomobject]@{ code = 0; msg = "ok"; data = [pscustomobject]@{ pause_status_id = 0 } })
        $paused = ConvertTo-AccountState -Response ([pscustomobject]@{ code = 0; msg = "ok"; data = [pscustomobject]@{ pause_status_id = 1 } })
        if ($active.State -ne "Active" -or $paused.State -ne "Paused") {
            throw "账号状态解析失败"
        }
    }
    catch { $failures += $_.Exception.Message }

    try {
        $countdown = Format-Countdown -Deadline (Get-Date).AddSeconds(120)
        if ($countdown -ne "02:00") {
            throw "倒计时格式化失败: $countdown"
        }
    }
    catch { $failures += $_.Exception.Message }

    try {
        $testMutexName = "Local\LeigodAutoPauseSelfTest-$([guid]::NewGuid().ToString('N'))"
        $testMutex = New-Object System.Threading.Mutex($false, $testMutexName)
        try {
            if (-not $testMutex.WaitOne(0, $false)) {
                throw "互斥锁自检失败"
            }
            $testMutex.ReleaseMutex()
        }
        finally {
            $testMutex.Dispose()
        }
    }
    catch { $failures += $_.Exception.Message }

    try {
        $invalidBooleanRejected = $false
        try {
            [void](Get-StrictBooleanProperty -Object ([pscustomobject]@{ enabled = "false" }) -Name "enabled" -DefaultValue $false)
        }
        catch {
            $invalidBooleanRejected = $true
        }
        if (-not $invalidBooleanRejected) {
            throw "配置布尔类型验证失败"
        }
    }
    catch { $failures += $_.Exception.Message }

    # 回归：空进程名曾经通过 TargetProcesses 泄漏，并让 Get-Process -Name "" 抛异常终止监控。
    try {
        if (@(Get-RunningConfiguredGames -ProcessNames ([string[]]@("", "  "))).Count -ne 0) {
            throw "空进程名未被安全跳过"
        }
        $mergeResult = @(Merge-ProcessNameList -NameList @("GameA", "", $null, "GameA", " GameB "))
        if ($mergeResult.Count -ne 2 -or
            $mergeResult -notcontains "GameA" -or
            $mergeResult -notcontains "GameB") {
            throw ("进程名合并未去空去重: [{0}]" -f ($mergeResult -join "|"))
        }
        $emptyTracker = [pscustomobject]@{ Sessions = @{} }
        $emptyConfig = [pscustomobject]@{ GameProcesses = [string[]]@("GameA"); AutoDetectLaunchedGames = $false }
        $emptyActivity = Get-GameActivity -Config $emptyConfig -LogDirectory $env:TEMP -Tracker $emptyTracker
        foreach ($targetName in @($emptyActivity.TargetProcesses)) {
            if ([string]::IsNullOrWhiteSpace([string]$targetName)) {
                throw "目标进程列表仍包含空字符串"
            }
        }
        if ($emptyActivity.TargetProcesses.Count -ne 1) {
            throw ("目标进程列表数量不正确: {0}" -f $emptyActivity.TargetProcesses.Count)
        }
    }
    catch { $failures += $_.Exception.Message }

    if ($failures.Count -gt 0) {
        throw ("自检失败: " + ($failures -join "; "))
    }
    Write-Host "SELF_TEST_OK"
}

function Start-LeigodMonitor {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$HttpLogDirectory,
        [Parameter(Mandatory = $true)][bool]$DryRunEnabled,
        [int]$CycleLimit = 0
    )

    $mutex = New-Object System.Threading.Mutex($false, $script:MonitorMutexName)
    $ownsMutex = $false
    try {
        $ownsMutex = $mutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $ownsMutex = $true
    }
    if (-not $ownsMutex) {
        Write-MonitorLog -Level "WARN" -Message "已有一个监控实例在运行，本实例退出。"
        $mutex.Dispose()
        return
    }

    try {
        if (Test-Path -LiteralPath $script:StopMarker) {
            Write-MonitorLog -Level "INFO" -Message "启动时发现停止标记，监控退出。"
            return
        }

        $state = "Idle"
        $deadline = $null
        $countdownToken = $null
        $token = $null
        $accountState = "Unknown"
        $lastLoggedAccountState = ""
        $lastStatusCheck = [datetime]::MinValue
        $lastClientRunning = Test-LeigodClientRunning
        $lastGameRunning = $false
        $clientSeenThisRun = $lastClientRunning
        $gameSessionConfirmedActive = $false
        $clientSessionConfirmedActive = $false
        $pendingClientExit = $false
        $gameExitObservedAt = $null
        $clientExitObservedAt = $null
        $eventRetentionSeconds = [math]::Max(300, ($Config.StatusPollSeconds * 3) + $Config.ExitGraceSeconds)
        $launchTracker = $(if ($Config.AutoDetectLaunchedGames) { New-LeigodLaunchTracker -LogDirectory $HttpLogDirectory } else { $null })
        $lastRuntimeSignature = ""
        $lastRuntimeWriteAt = [datetime]::MinValue
        $cycle = 0
        $unknownStatusChecks = 0
        $lastStatusMessage = ""
        # 倒计时开始后，失败重试允许的最晚时间；超过后放弃本次暂停，避免把很久以前的会话在数小时后补暂停。
        $pauseAttemptExpiresAt = $null
        $lastLogPruneDate = [datetime]::MinValue

        $manualSummary = $(if ($Config.GameProcesses.Count -gt 0) { $Config.GameProcesses -join ", " } else { "无" })
        Write-MonitorLog -Level "INFO" -Message ("监控已启动{0}。自动识别: {1}；手动补充: {2}" -f $(if ($DryRunEnabled) { "（dry-run）" } else { "" }), $(if ($Config.AutoDetectLaunchedGames) { "启用" } else { "关闭" }), $manualSummary)
        if ($null -ne $launchTracker) {
            $restoredProcesses = @(Get-AutomaticGameProcesses -Tracker $launchTracker)
            if ($restoredProcesses.Count -gt 0) {
                Write-MonitorLog -Level "INFO" -Message ("已恢复当前仍在启动或运行的雷神游戏: {0}" -f ($restoredProcesses -join ", "))
            }
        }

        $logRetentionDays = [int](Get-ObjectPropertyValue -Object $Config -Name "LogRetentionDays" -DefaultValue 30)
        Remove-ExpiredMonitorLogs -RetentionDays $logRetentionDays
        $lastLogPruneDate = (Get-Date).Date

        while ($true) {
            if (Test-Path -LiteralPath $script:StopMarker) {
                Write-MonitorLog -Level "INFO" -Message "收到停止标记，监控退出。"
                break
            }

            # 跨天后重新执行一次日志保留清理（长期运行的监控不会重启，启动时清一次不够）。
            if ($logRetentionDays -gt 0 -and (Get-Date).Date -ne $lastLogPruneDate) {
                Remove-ExpiredMonitorLogs -RetentionDays $logRetentionDays
                $lastLogPruneDate = (Get-Date).Date
            }

            $cycle++
            $now = Get-Date
            $identityChangedThisCycle = $false
            $clientRunning = Test-LeigodClientRunning
            if ($clientRunning) {
                $clientSeenThisRun = $true
            }
            if ($clientRunning -and -not $lastClientRunning) {
                if ($state -eq "StaleSession") {
                    Write-MonitorLog -Level "INFO" -Message "检测到雷神客户端已启动，取消遗留会话触发的自动暂停。"
                    $state = "Idle"
                    $deadline = $null
                    $countdownToken = $null
                }
                $token = $null
                $accountState = "Unknown"
                $lastStatusCheck = [datetime]::MinValue
                $gameSessionConfirmedActive = $false
                $clientSessionConfirmedActive = $false
                $pendingClientExit = $false
                $clientExitObservedAt = $null
                $identityChangedThisCycle = $true
            }
            if ($lastClientRunning -and -not $clientRunning -and $Config.PauseIfClientCloses -and $clientSessionConfirmedActive) {
                $pendingClientExit = $true
                $clientExitObservedAt = $now
            }
            if ($clientRunning -and ($pendingClientExit -or $state -eq "AfterClientExit")) {
                Write-MonitorLog -Level "INFO" -Message "检测到雷神客户端已重新启动，取消关闭客户端触发的自动暂停。"
                $pendingClientExit = $false
                $clientExitObservedAt = $null
                if ($state -eq "AfterClientExit") {
                    $state = "Idle"
                    $deadline = $null
                    $countdownToken = $null
                }
            }
            try {
                $activity = Get-GameActivity -Config $Config -LogDirectory $HttpLogDirectory -Tracker $launchTracker -RefreshTracker
            }
            catch {
                Write-MonitorLog -Level "WARN" -Message ("本轮游戏状态检查失败，跳过本周期: {0}" -f $_.Exception.Message)
                Start-Sleep -Seconds $Config.PollSeconds
                continue
            }
            $runningGames = @($activity.RunningGames)
            $gameRunning = $runningGames.Count -gt 0

            if ($gameRunning -and $state -ne "GameRunning") {
                Write-MonitorLog -Level "INFO" -Message ("检测到游戏运行: {0}" -f ($runningGames -join ", "))
                $state = "GameRunning"
                $deadline = $null
                $countdownToken = $null
                $gameSessionConfirmedActive = $false
                $gameExitObservedAt = $null
                $pendingClientExit = $false
                $clientExitObservedAt = $null
            }
            elseif ($activity.LaunchPending -and $state -ne "GameStarting") {
                Write-MonitorLog -Level "INFO" -Message "检测到雷神正在启动游戏，等待目标进程出现。"
                $state = "GameStarting"
                $deadline = $null
                $countdownToken = $null
                $gameSessionConfirmedActive = $false
                $gameExitObservedAt = $null
                $pendingClientExit = $false
                $clientExitObservedAt = $null
            }
            elseif ($lastGameRunning -and -not $gameRunning -and $state -eq "GameRunning") {
                $gameExitObservedAt = $now
            }

            # 账号状态巡检：单次失败时用 3 秒间隔快速重试，避免把一次网络抖动放大成
            # “Unknown → 等下个周期才恢复”的成对日志；连续失败才降级为 WARN。
            $statusInterval = [int]$Config.StatusPollSeconds
            if ($accountState -eq "Unknown" -and $unknownStatusChecks -lt 2) {
                $statusInterval = [math]::Min($statusInterval, 3)
            }
            $statusDue = ($now - $lastStatusCheck).TotalSeconds -ge $statusInterval
            $needsStatus = $cycle -eq 1 -or $clientRunning -or $gameRunning -or $activity.LaunchPending -or $state -ne "Idle"
            $finalCheckReady = $null -ne $deadline -and $now -ge $deadline -and $accountState -eq "Active" -and $token
            if ($needsStatus -and $statusDue -and -not $finalCheckReady) {
                $freshToken = Get-LatestAccountToken -HttpLogDirectory $HttpLogDirectory
                $statusMessage = ""
                if ($freshToken) {
                    if ($token -and
                        -not [string]::Equals($freshToken, $token, [System.StringComparison]::Ordinal)) {
                        Write-MonitorLog -Level "WARN" -Message "检测到当前登录凭据变化，已丢弃上一会话的确认状态。"
                        $gameSessionConfirmedActive = $false
                        $clientSessionConfirmedActive = $false
                        $pendingClientExit = $false
                        $gameExitObservedAt = $null
                        $clientExitObservedAt = $null
                        $clientSeenThisRun = $true
                        $countdownToken = $null
                        $identityChangedThisCycle = $true
                        if ($null -ne $deadline) {
                            $state = "Idle"
                            $deadline = $null
                        }
                    }
                    $token = $freshToken
                    $statusResult = Get-LeigodAccountState -Token $token
                    $accountState = $statusResult.State
                    $statusMessage = [string]$statusResult.Message
                    if ($statusResult.Code -eq $script:TokenInvalidCode) {
                        $token = $null
                    }
                }
                else {
                    $accountState = "Unknown"
                    $statusMessage = "未找到可用的账号凭据"
                }
                if ($accountState -eq "Unknown") {
                    $unknownStatusChecks++
                    $lastStatusMessage = $statusMessage
                }
                else {
                    $unknownStatusChecks = 0
                }
                $lastStatusCheck = $now

                if ($accountState -ne $lastLoggedAccountState) {
                    if ($accountState -eq "Unknown") {
                        # 单次失败通常下一个 3 秒重试就恢复，不值得写日志；连续失败才提示。
                        if ($unknownStatusChecks -ge 2) {
                            Write-MonitorLog -Level "WARN" -Message ("账号状态无法确认（连续 {0} 次）: {1}。" -f $unknownStatusChecks, $lastStatusMessage)
                            $lastLoggedAccountState = $accountState
                        }
                    }
                    else {
                        Write-MonitorLog -Level "INFO" -Message ("账号状态更新: {0}。" -f $accountState)
                        $lastLoggedAccountState = $accountState
                    }
                }
            }

            if ($accountState -eq "Active" -and -not $identityChangedThisCycle) {
                if ($gameRunning -and $activity.CanConfirmSession) {
                    $gameSessionConfirmedActive = $true
                }
                if ($clientRunning) {
                    $clientSessionConfirmedActive = $true
                }
            }

            if ($null -ne $gameExitObservedAt -and ((Get-Date) - $gameExitObservedAt).TotalSeconds -gt $eventRetentionSeconds) {
                Write-MonitorLog -Level "WARN" -Message "游戏退出事件等待账号状态恢复超时，已放弃本次自动暂停。"
                $state = "Idle"
                $deadline = $null
                $countdownToken = $null
                $gameSessionConfirmedActive = $false
                $gameExitObservedAt = $null
                Remove-InactiveLeigodLaunchSessions -Tracker $launchTracker
            }
            if ($pendingClientExit -and $null -ne $clientExitObservedAt -and ((Get-Date) - $clientExitObservedAt).TotalSeconds -gt $eventRetentionSeconds) {
                Write-MonitorLog -Level "WARN" -Message "客户端关闭事件等待账号状态恢复超时，已放弃本次自动暂停。"
                $pendingClientExit = $false
                $clientExitObservedAt = $null
                $clientSessionConfirmedActive = $false
            }

            if ($accountState -eq "Paused") {
                if (-not $gameRunning) {
                    if ($state -ne "Idle") {
                        Write-MonitorLog -Level "INFO" -Message "检测到账号已暂停，监控状态已复位。"
                    }
                    $state = "Idle"
                    $deadline = $null
                    $countdownToken = $null
                    if (-not $activity.UnresolvedLaunch) {
                        Clear-LeigodLaunchTracker -Tracker $launchTracker
                    }
                }
                $gameSessionConfirmedActive = $false
                $clientSessionConfirmedActive = $false
                $pendingClientExit = $false
                $gameExitObservedAt = $null
                $clientExitObservedAt = $null
            }
            elseif ($accountState -eq "Active") {
                if ($gameRunning) {
                    $deadline = $null
                    $countdownToken = $null
                }
                elseif ($state -eq "GameRunning") {
                    if ($gameSessionConfirmedActive -and $null -ne $gameExitObservedAt) {
                        $next = Start-CountdownState -NewState "AfterGameExit" -Seconds $Config.ExitGraceSeconds -Reason "检测到游戏进程已退出" -Config $Config
                        $state = $next.State
                        $deadline = $next.Deadline
                        $pauseAttemptExpiresAt = $next.Deadline.AddSeconds($eventRetentionSeconds)
                        $countdownToken = $token
                        $pendingClientExit = $false
                        $clientExitObservedAt = $null
                    }
                    else {
                        Write-MonitorLog -Level "WARN" -Message "检测到游戏退出，但本轮游戏运行期间未确认账号正在计时，本次不执行。"
                        $state = "Idle"
                        $deadline = $null
                        $countdownToken = $null
                        $gameSessionConfirmedActive = $false
                        $gameExitObservedAt = $null
                        Remove-InactiveLeigodLaunchSessions -Tracker $launchTracker
                    }
                }
                elseif ($state -eq "GameStarting" -and -not $activity.LaunchPending) {
                    Write-MonitorLog -Level "WARN" -Message "雷神启动等待已结束，但未确认目标游戏进程运行；将保留目标用于后续复核，本次不执行。"
                    $state = "Idle"
                    $deadline = $null
                    $countdownToken = $null
                    $gameSessionConfirmedActive = $false
                    $gameExitObservedAt = $null
                }
                elseif ($pendingClientExit -and -not $clientRunning -and $state -notin @("AfterGameExit", "AfterClientExit")) {
                    if ($activity.UnresolvedLaunch) {
                        Write-MonitorLog -Level "WARN" -Message "雷神客户端已关闭，但仍有无法确认进程名的游戏会话；为避免游戏运行中误暂停，本次不执行。"
                        $pendingClientExit = $false
                        $clientExitObservedAt = $null
                        $clientSessionConfirmedActive = $false
                    }
                    else {
                        $next = Start-CountdownState -NewState "AfterClientExit" -Seconds $Config.ExitGraceSeconds -Reason "检测到雷神客户端已关闭" -Config $Config
                        $state = $next.State
                        $deadline = $next.Deadline
                        $pauseAttemptExpiresAt = $next.Deadline.AddSeconds($eventRetentionSeconds)
                        $countdownToken = $token
                        $pendingClientExit = $false
                        $clientExitObservedAt = $null
                        $clientSessionConfirmedActive = $false
                    }
                }
                elseif ($state -eq "Idle" -and $clientRunning -and $Config.PauseIfGameNeverStarts -and -not $activity.UnresolvedLaunch) {
                    $next = Start-CountdownState -NewState "WaitingForGame" -Seconds $Config.StartupGraceSeconds -Reason "账号正在计时，但尚未检测到自动或手动目标游戏" -Config $Config
                    $state = $next.State
                    $deadline = $next.Deadline
                    $pauseAttemptExpiresAt = $next.Deadline.AddSeconds($eventRetentionSeconds)
                    $countdownToken = $token
                }
                elseif ($state -eq "Idle" -and -not $clientRunning -and $Config.PauseStaleSessionOnStart -and -not $clientSeenThisRun -and -not $activity.UnresolvedLaunch) {
                    $next = Start-CountdownState -NewState "StaleSession" -Seconds $Config.StartupGraceSeconds -Reason "检测到上次遗留的计时状态" -Config $Config
                    $state = $next.State
                    $deadline = $next.Deadline
                    $pauseAttemptExpiresAt = $next.Deadline.AddSeconds($eventRetentionSeconds)
                    $countdownToken = $token
                }

                # 重试窗口：倒计时到点后若因为凭据或接口问题一直无法完成，最多再等一个
                # eventRetentionSeconds 就放弃，避免几小时后对一次早已过期的会话补做暂停。
                if ($null -ne $deadline -and $null -ne $pauseAttemptExpiresAt -and $now -gt $pauseAttemptExpiresAt) {
                    Write-MonitorLog -Level "WARN" -Message "自动暂停重试已超过安全等待窗口，放弃本次暂停。"
                    $state = "Idle"
                    $deadline = $null
                    $countdownToken = $null
                    $pauseAttemptExpiresAt = $null
                    $gameSessionConfirmedActive = $false
                    $clientSessionConfirmedActive = $false
                    $pendingClientExit = $false
                    $gameExitObservedAt = $null
                    $clientExitObservedAt = $null
                }

                if ($null -ne $deadline -and $now -ge $deadline) {
                    if ($gameRunning) {
                        Write-MonitorLog -Level "INFO" -Message "最终检查发现游戏已重新运行，取消自动暂停。"
                        $state = "GameRunning"
                        $deadline = $null
                        $countdownToken = $null
                    }
                    elseif (-not $countdownToken) {
                        Write-MonitorLog -Level "WARN" -Message "倒计时结束，但无法取得当前登录凭据；本次不执行。"
                        $state = "Idle"
                        $deadline = $null
                        $countdownToken = $null
                    }
                    else {
                        $pauseOutcome = Invoke-PauseAfterFinalCheck -Token $countdownToken -HttpLogDirectory $HttpLogDirectory -DryRunEnabled $DryRunEnabled -Config $Config -LaunchTracker $launchTracker -CountdownState $state
                        if ($pauseOutcome -eq "Completed") {
                            $state = "Idle"
                            $deadline = $null
                            $countdownToken = $null
                            $gameSessionConfirmedActive = $false
                            $clientSessionConfirmedActive = $false
                            $pendingClientExit = $false
                            $gameExitObservedAt = $null
                            $clientExitObservedAt = $null
                            $accountState = $(if ($DryRunEnabled) { "Unknown" } else { "Paused" })
                            Clear-LeigodLaunchTracker -Tracker $launchTracker
                        }
                        elseif ($pauseOutcome -eq "GameRunning") {
                            $state = "GameRunning"
                            $deadline = $null
                            $countdownToken = $null
                            $latestActivity = Get-GameActivity -Config $Config -LogDirectory $HttpLogDirectory -Tracker $launchTracker
                            $gameSessionConfirmedActive = [bool]($accountState -eq "Active" -and $latestActivity.CanConfirmSession)
                            $gameExitObservedAt = $null
                        }
                        elseif ($pauseOutcome -eq "GameStarting") {
                            $state = "GameStarting"
                            $deadline = $null
                            $countdownToken = $null
                            $gameSessionConfirmedActive = $false
                            $gameExitObservedAt = $null
                        }
                        elseif ($pauseOutcome -eq "ClientRunning") {
                            $state = "Idle"
                            $deadline = $null
                            $countdownToken = $null
                            $pendingClientExit = $false
                            $clientExitObservedAt = $null
                            $clientSessionConfirmedActive = $true
                        }
                        elseif ($pauseOutcome -eq "UnresolvedGame") {
                            $state = "Idle"
                            $deadline = $null
                            $countdownToken = $null
                            $gameSessionConfirmedActive = $false
                            $clientSessionConfirmedActive = $false
                            $pendingClientExit = $false
                            $gameExitObservedAt = $null
                            $clientExitObservedAt = $null
                        }
                        elseif ($pauseOutcome -eq "Stopped") {
                            break
                        }
                        elseif ($pauseOutcome -eq "TokenChanged") {
                            $state = "Idle"
                            $deadline = $null
                            $countdownToken = $null
                            $token = $null
                            $accountState = "Unknown"
                            $gameSessionConfirmedActive = $false
                            $clientSessionConfirmedActive = $false
                            $pendingClientExit = $false
                            $gameExitObservedAt = $null
                            $clientExitObservedAt = $null
                        }
                        else {
                            $deadline = (Get-Date).AddSeconds($Config.StatusPollSeconds)
                        }
                    }
                }
            }

            if ($null -ne $deadline -and ($cycle % [math]::Max(1, [int](30 / $Config.PollSeconds))) -eq 0) {
                Write-MonitorLog -Level "INFO" -Message ("当前状态: {0}，剩余 {1}。" -f $state, (Format-Countdown -Deadline $deadline))
            }

            # 直接复用本周期开头的 $activity；这里原来又完整跑了一遍 Get-GameActivity
            # （进程枚举 + 加速状态文件读取），属于每个周期都重复一次的劳动。
            Write-MonitorRuntimeState -State $state -AccountState $accountState -Activity $activity -AutoDetectionEnabled $Config.AutoDetectLaunchedGames -Force $false -LastSignature ([ref]$lastRuntimeSignature) -LastWriteAt ([ref]$lastRuntimeWriteAt)
            $lastClientRunning = $clientRunning
            $lastGameRunning = $gameRunning
            if ($CycleLimit -gt 0 -and $cycle -ge $CycleLimit) {
                Write-MonitorLog -Level "INFO" -Message "已达到 MaxCycles，监控退出。"
                break
            }
            Start-Sleep -Seconds $Config.PollSeconds
        }
    }
    finally {
        Remove-MonitorRuntimeState
        if ($ownsMutex) {
            try { $mutex.ReleaseMutex() } catch { }
        }
        $mutex.Dispose()
    }
}

# 允许测试脚本用 “. .\LeigodAutoPause.ps1” 只加载函数而不启动监控，
# 这样 tools\Test.ps1 才能直接对纯函数做回归测试。
if ($MyInvocation.InvocationName -eq '.') {
    return
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

try {
    $config = Read-MonitorConfig -Path $ConfigPath
    $script:RuntimeStateMaxAgeSeconds = [math]::Max(20, $config.PollSeconds + 15)
    $leigodExecutable = Resolve-LeigodExecutable -Config $config
    $httpLogDirectory = Join-Path (Split-Path -Parent $leigodExecutable) "resources\llogs"

    if ($ValidateConfig) {
        Write-Output "CONFIG_OK"
        return
    }

    if ($Check -or $CheckJson) {
        Invoke-CheckMode -Config $config -LeigodExecutable $leigodExecutable -HttpLogDirectory $httpLogDirectory -JsonOutput ([bool]$CheckJson) -SensitiveDetailsEnabled ([bool]$IncludeSensitiveDetails)
        return
    }

    Start-LeigodMonitor -Config $config -HttpLogDirectory $httpLogDirectory -DryRunEnabled ([bool]$DryRun) -CycleLimit $MaxCycles
}
catch {
    if ($ValidateConfig) {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
    $failureLine = [int]$_.InvocationInfo.ScriptLineNumber
    $failureCommand = [string]$_.InvocationInfo.InvocationName
    $failureId = [string]$_.FullyQualifiedErrorId
    Write-MonitorLog -Level "ERROR" -Message ("监控异常退出: {0}；脚本行: {1}；命令: {2}；错误 ID: {3}" -f $_.Exception.GetType().Name, $failureLine, $failureCommand, $failureId)
    exit 1
}
