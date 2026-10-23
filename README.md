# 雷神自动暂停（非官方）

一个仅在 Windows 用户设备上运行的开源工具：自动识别由雷神客户端发起启动的游戏，监控其进程，并在游戏退出且通过最终复核后请求暂停雷神加速器的账号时长。

> [!IMPORTANT]
> 本项目由第三方独立开发，与雷神加速器及其运营方不存在隶属、合作、授权或背书关系。项目维护者未提供已获得第三方接口自动化授权的证据。MIT 许可证只许可本仓库代码和文档，不授予使用第三方账号、客户端、接口、商标或服务的权利。公开发布或使用前请阅读[合规与法律说明](LEGAL.md)以及雷神官网当前公示的协议。

## 功能特性

- **自动识别**：增量读取雷神客户端日志里的 `launch-local-game` 事件，自动拿到当前游戏的精确进程名，无需手填；
- **只在真正该暂停时暂停**：游戏运行期间必须同时确认过加速项和账号 `Active`，退出后经过宽限期还会再做一轮完整复核；
- **保守失败**：缺少进程名、`game_id` 无法交叉确认、凭据变化、客户端重启、检测到新启动事件时，一律阻止自动暂停而不是猜测；
- **本地优先**：没有维护者后端、遥测或自动更新，全部逻辑只在本机 PowerShell 进程内完成；
- **可审计**：运行日志保留最近 30 天（可配置），诊断输出默认脱敏；
- **界面 + 开机自启**：WPF 控制台可启停监控、改规则、看日志；开机自启走当前用户 Startup 快捷方式并做 ACL 前置校验。

## 工作方式

1. 增量读取雷神客户端 `resources\llogs\main-*.log` 中新追加的 `launch-local-game` 事件，只提取 `game_id`、`game_process`、`timeout` 和操作类型；
2. 将事件里的一个或多个精确进程名与当前 Windows 登录会话中的实际进程匹配，并用雷神本地加速状态文件交叉确认当前 `game_id`；
3. 用户配置的 `game_processes` 作为可选兼容补充，与自动目标共同参与运行检查；
4. 从最近的 `resources\llogs\http-*.log` 中解析 HTTPS `leigod.com` 域名 URL 里的 `account_token`，并查询账号是否正在计时；
5. 只有游戏真实运行期间同时确认过当前加速项和账号 `Active`，退出后才进入宽限期；缺少可用进程名的启动事件会保留为不确定会话并阻止自动暂停；
6. 在真正暂停前再次检查新启动事件、完整的多进程目标集合、登录凭据、账号状态，并在适用规则中复核客户端；
7. 仅在状态仍为 `Active` 时向 `https://webapi.leigod.com/api/user/pause` 发送暂停请求，并复核结果。

后台监控按 `poll_seconds` 做本地检查、按 `status_poll_seconds` 查询账号状态；单次查询失败会先按 3 秒间隔快速重试，连续失败才记一条警告。暂停请求在倒计时到点后如果一直无法通过复核，最多再等 `max(300, 3 × status_poll_seconds + exit_grace_seconds)` 秒就会放弃，不会在几小时后对一次过期会话补做暂停。

项目不运营维护者控制的后端、遥测或自动更新服务，也不会下载并执行远程代码。

## 安全与隐私边界

- 雷神客户端日志本身已在磁盘保存 Token；本工具不会把提取出的 Token 再写入自己的配置、日志或诊断输出；
- Token 在当前 PowerShell 进程内处理，并作为 HTTPS 请求体发送到上述固定主机；系统代理、操作系统和第三方客户端自身的行为不由本项目控制；
- 本项目日志位于 `app\logs`，以本地明文记录时间、游戏进程、客户端/账号状态、倒计时、接口结果代码和错误类别；默认只保留最近 30 天（`log_retention_days`，设为 `0` 关闭自动清理）；
- `app\config.json` 可能包含游戏名称和本机安装路径；
- 维护者不会自动收到配置、Token 或日志。不要在 Issue、Discussion、Pull Request、截图中公开这些内容。

完整数据说明见 [PRIVACY.md](PRIVACY.md)，漏洞报告方法见 [SECURITY.md](SECURITY.md)。

## 环境要求

- Windows 10 或 Windows 11；
- Windows PowerShell 5.1；
- 已安装并登录雷神加速器；
- 构建启动器时需要系统自带的 .NET Framework 4.x C# 编译器；
- WPF、Windows Forms、`WScript.Shell` 等 Windows 系统组件。

不支持 PowerShell 7、macOS 或 Linux。

> 所有 `.ps1` 必须以 UTF-8 BOM 保存：Windows PowerShell 5.1 靠 BOM 识别中文，缺 BOM 会让提示文案变乱码甚至产生语法错误。`tools\Test.ps1` 会把缺 BOM 当成失败。

## 首次运行

在项目根目录执行：

```powershell
powershell.exe -STA -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\app\LeigodAutoPause.UI.ps1
```

首次运行会从 `app\config.example.json` 创建本机专用的 `app\config.json`。实际配置已经被 `.gitignore` 排除。自动识别默认开启；控制台的“规则设置”页可以添加识别失败时使用的兼容进程名，并修改宽限时间。

`-ExecutionPolicy Bypass` 只应用于这次新建的 PowerShell 进程，但仍应先审阅源码，并只从可信仓库获取本项目。

## 控制台

控制台分三页，全部逻辑通过 `$window.FindName` 绑定，界面只负责呈现：

- **概览**：hero 区先用一句话回答「我现在安全吗」（后台未运行 / 计时中且退出会自动暂停 / 账号在计时但本次会话未确认 / 已暂停安全 / 账号状态无法确认），并显示状态数据的新鲜度与倒计时；下方是雷神客户端 / 账号时长 / 目标游戏三个实时指标、最近活动、最近一次暂停结论与当前规则摘要；
- **规则设置**：手动补充进程、游戏退出宽限、启动观察期、自动识别与四个触发开关；保存前会先跑一次配置校验（校验失败会把监控器的原始报错带回界面），失败则不覆盖旧配置，且不会丢弃配置文件里已有的其他字段；
- **运行日志**：最近 200 行本地日志，支持关键字搜索、按级别过滤（全部 / 仅提醒 / 仅错误 / 仅决策）、复制当前视图、显示来源文件名与命中行数；日志未变化时不会重写文本框，滚动位置和选区不会被定时刷新打断；
- **诊断**：一键读取「登录凭据 / 账号时长 / 雷神客户端 / 目标游戏」四项本机事实，并按结果给出具体原因与下一步建议（例如凭据未找到、客户端未运行、没有任何目标游戏、账号不在计时）；「复制排障报告」可把结果连同时间与监控状态复制走，不需要公开原始日志。

后台监控运行时，控制台直接读 `app\logs\runtime-state.json` 里监控写入的短期状态，不再单独起 PowerShell 子进程查询账号；只有该文件过期（监控卡住或刚重启）时才由控制台自己探测兜底。

> 从控制台之外启动后台监控时请注意：如果通过某些终端工具（例如带进程作业对象的 IDE 或编排器）间接启动，监控进程可能随该工具退出而被一并结束。日常使用请直接运行 `app\Install-AutoStart.ps1`、桌面快捷方式或本机终端里的 `Restart-Monitor.ps1`。

需要给文档或截图留档时，可以生成一张本地界面截图（文件名必须以 `.snapshot.png` 结尾，产物被 `.gitignore` 排除，避免把本机游戏名和时间线带进仓库）：

```powershell
powershell.exe -STA -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\app\LeigodAutoPause.UI.ps1 -SnapshotPath .\docs\overview.snapshot.png -InitialPanel Overview
```

## 配置

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `auto_detect_launched_games` | `true` | 是否从雷神本地启动事件自动取得当前游戏进程 |
| `game_processes` | 空数组 | 可选兼容补充；关闭自动识别时至少需要一个完整进程名 |
| `poll_seconds` | `2` | 本地进程检查间隔，范围 1-60 秒 |
| `status_poll_seconds` | `20` | 账号状态检查间隔，范围 1-600 秒 |
| `startup_grace_seconds` | `300` | 启动观察期，范围 10-7200 秒 |
| `exit_grace_seconds` | `120` | 游戏退出后的复核宽限期，范围 10-3600 秒 |
| `pause_if_client_closes` | `true` | 已确认计时后，客户端退出是否触发暂停；存在无法识别进程的游戏会话时不会执行 |
| `pause_if_game_never_starts` | `false` | 客户端计时但未检测到游戏时是否触发暂停 |
| `pause_stale_session_on_start` | `false` | 是否处理启动监控前遗留的计时状态 |
| `notifications` | `true` | 是否显示 Windows 通知 |
| `log_retention_days` | `30` | `monitor-*.log` 的保留天数，范围 0-3650；`0` 表示不自动清理 |
| `leigod_executable` | 空 | 可选；只接受本地磁盘上的 `leigod.exe` |
| `leigod_shortcut` | 官方快捷方式常见路径 | 只接受本地 `.lnk`，且目标必须是 `leigod.exe` |

本工具没有稳定账号标识，不能可靠判断两个 Token 是否属于同一账号；宽限期内发现 Token 变化时会取消本轮暂停。切换账号后仍应重启雷神客户端和本工具，并先使用演练或人工方式确认目标账号。

## 本地验证

不会联网或发送暂停请求的自检：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\app\LeigodAutoPause.ps1 -SelfTest
```

验证当前配置和客户端路径，不查询账号：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\app\LeigodAutoPause.ps1 -ValidateConfig
```

`-Check` 和 `-CheckJson` 会读取 Token 并实际联网查询账号状态。它们默认隐藏完整路径和进程明细；只应在本机排障时显式增加 `-IncludeSensitiveDetails`，不要把原始输出公开。

提交前可以一次运行全部不联网发布测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test.ps1
```

该脚本覆盖：PS 5.1 语法与 UTF-8 BOM、启动事件解析与增量读取、自动/手动配置边界、示例配置、JSON/XAML 结构、脱敏诊断输出、启动器构建，外加一组纯函数回归测试（空进程名、进程名合并、目标列表、日志保留、配置边界）。GitHub Actions 运行同一脚本。

## 构建启动器

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Build.ps1
.\LeigodAutoPause.exe
```

生成的 `LeigodAutoPause.exe` 只负责启动 `app\LeigodAutoPause.UI.ps1`，并不是独立安装包。EXE 依赖完整的 `app` 目录，未签名，可能触发 Windows SmartScreen 或安全软件提示。

## 开机自启

开机自启会隐藏运行 PowerShell 脚本。安装脚本只接受本地固定磁盘上、整条路径不含重解析点且实际所有者可信的执行链；如果 `Everyone`、`Authenticated Users` 或普通 `Users` 可以修改或替换关键文件，安装会被拒绝。请把项目放在当前用户专属目录，例如：

```text
%LOCALAPPDATA%\Programs\LeigodAutoPause
```

该路径只是常见选择，不保证每台机器的 ACL 都安全。如果检查被拒绝，说明当前目录或其祖先仍可被其他主体修改或替换；不要通过扩大白名单绕过检查，应由管理员修正目录权限，或不启用开机自启。升级代码不会自动删除旧版本已经创建的 Startup 快捷方式。

安装或刷新开机自启和桌面入口：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\app\Install-AutoStart.ps1
```

停止后台监控并移除开机自启：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\app\Uninstall-AutoStart.ps1
```

卸载自启不会删除 `app\config.json`、`app\logs` 或桌面入口。

## 上传 GitHub 前

**不要用网页拖拽整个工作目录**：工作目录里有本机配置、运行日志和未签名 EXE。上传集合必须以 Git 索引为准。

一条命令自检（只读，不修改任何文件）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Verify-Upload.ps1
# 需要同时检查整个提交历史时：
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Verify-Upload.ps1 -IncludeHistory
```

输出 `UPLOAD_READY` 即表示：索引里没有 `app/config.json`、没有 `app/logs` 下的日志、没有 EXE/PDB/DMP/截图/私钥、内容里没有疑似凭据或本机绝对路径；提交作者邮箱非 `noreply` 时只提示不阻断。任何一项不满足都会列出具体文件并以非零码退出。

需要人工复核时，等价的手工检查是：

```powershell
git status --short --ignored
git diff --cached --name-only
git ls-files -- app/config.json app/logs LeigodAutoPause.exe
git log --format='%an <%ae>' | Sort-Object -Unique
```

检查结果必须满足：

- `app/config.json`、`monitor-*.log`、`http-*.log`、`main-*.log`、截图、内存转储、PFX/私钥、PDB 和本地 EXE 均未暂存；
- `app/logs` 下只有 `.gitkeep` 被跟踪；
- `git diff --cached` 中没有账号、Token、本机绝对路径或使用时间线；
- Git 作者邮箱使用 GitHub 提供的 `noreply` 地址（提交前可临时指定：`git -c user.email=<id>@users.noreply.github.com commit ...`）；
- 已启用 GitHub Private Vulnerability Reporting，或在 `SECURITY.md` 提供可用的私密渠道。

## 仓库结构

```text
app/                         监控、控制台、自启动与本地配置模板
  ui/MainWindow.xaml         WPF 界面（纯样式，无 code-behind）
  logs/.gitkeep              运行日志目录占位文件
src/                         无控制台启动器源码与 manifest
tools/Build.ps1              本地构建脚本
tools/Test.ps1               不联网发布自检 + 纯函数回归测试
tools/Verify-Upload.ps1      上传前隐私与入库集合自检
.github/workflows/ci.yml     Windows PowerShell 5.1 CI
LEGAL.md                     合规与法律边界
PRIVACY.md                   数据处理与清理说明
SECURITY.md                  安全策略和漏洞报告
NOTICE.md                    非官方、商标与第三方权利声明
LICENSE                      MIT License
```

`app/config.json`、`app/logs/*`、`LeigodAutoPause.exe`、`*.snapshot.png` 等本机产物由 `.gitignore` 排除，不会进入仓库。

## 已知限制

- 雷神客户端日志格式、域名或接口发生变化时，本工具可能失效；
- 自动识别只处理雷神客户端记录的 `launch-local-game` 事件；直接从 Steam、桌面快捷方式或其他平台启动且未经过雷神启动按钮的游戏，需要手动补充进程名；
- 雷神未提供进程名、只提供平台启动器、当前 `game_id` 无法交叉确认或目标进程未实际出现时，本工具会保留不确定状态并阻止自动暂停；可以在规则设置中添加精确进程名，或关闭自动识别后仅使用手动目标；
- 只应操作使用者本人、本机当前合法登录的账号，不支持共享或代管账号；
- 进程判断限于当前 Windows 登录会话，并按雷神事件或手动补充中的精确进程名识别；同一会话中的同名进程会影响判断；
- 本工具不能保证暂停请求成功，也不能避免第三方依据其协议采取账号措施；
- 首次启动监控前已经结束的游戏会话无法追溯；
- 本地日志按 `log_retention_days` 自动清理，但当前不做大小上限或压缩；
- 界面截图需要在本机生成（`-SnapshotPath`），仓库不内置截图，避免泄露本机游戏名与使用时间；
- 多份安装使用同名本地互斥锁，不建议同时运行。

## 许可证与声明

本项目原创代码和文档以 [MIT License](LICENSE) 发布。第三方名称、商标、客户端、日志格式、接口和服务不属于该许可范围。请同时阅读 [NOTICE.md](NOTICE.md)、[LEGAL.md](LEGAL.md) 和 [PRIVACY.md](PRIVACY.md)。

在适用法律允许的最大范围内，本软件按现状提供，不保证兼容性、持续可用性、暂停结果或第三方服务稳定性；本说明不排除或限制依法不得排除或限制的责任。
