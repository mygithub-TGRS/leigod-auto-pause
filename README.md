# 雷神自动暂停（非官方）

一个仅在 Windows 用户设备上运行的开源工具：自动识别由雷神客户端发起启动的游戏，监控其进程，并在游戏退出且通过最终复核后请求暂停雷神加速器的账号时长。

> [!IMPORTANT]
> 本项目由第三方独立开发，与雷神加速器及其运营方不存在隶属、合作、授权或背书关系。项目维护者未提供已获得第三方接口自动化授权的证据。MIT 许可证只许可本仓库代码和文档，不授予使用第三方账号、客户端、接口、商标或服务的权利。公开发布或使用前请阅读[合规与法律说明](LEGAL.md)以及雷神官网当前公示的协议。

## 项目状态

- 适合以**源代码**形式纳入 Git 管理；
- 不建议把工作目录、ZIP 全目录或本地生成的 EXE 直接拖拽到 GitHub；
- 未签名 EXE 只作为本地构建产物，不纳入仓库；
- 第三方服务条款风险不能由 README、NOTICE 或 MIT 免责条款消除。公开分发前，取得运营方书面确认是风险最低的路径。

## 工作方式

1. 增量读取雷神客户端 `resources\llogs\main-*.log` 中新追加的 `launch-local-game` 事件，只提取 `game_id`、`game_process`、`timeout` 和操作类型；
2. 将事件里的一个或多个精确进程名与当前 Windows 登录会话中的实际进程匹配，并用雷神本地加速状态文件交叉确认当前 `game_id`；
3. 用户配置的 `game_processes` 作为可选兼容补充，与自动目标共同参与运行检查；
4. 从最近的 `resources\llogs\http-*.log` 中解析 HTTPS `leigod.com` 域名 URL 里的 `account_token`，并查询账号是否正在计时；
5. 只有游戏真实运行期间同时确认过当前加速项和账号 `Active`，退出后才进入宽限期；缺少可用进程名的启动事件会保留为不确定会话并阻止自动暂停；
6. 在真正暂停前再次检查新启动事件、完整的多进程目标集合、登录凭据、账号状态，并在适用规则中复核客户端；
7. 仅在状态仍为 `Active` 时向 `https://webapi.leigod.com/api/user/pause` 发送暂停请求，并复核结果。

正常打开控制台时也会进行账号状态查询，随后约每 30 秒刷新一次。项目不运营维护者控制的后端、遥测或自动更新服务，也不会下载并执行远程代码。

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

## 首次运行

在项目根目录执行：

```powershell
powershell.exe -STA -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\app\LeigodAutoPause.UI.ps1
```

首次运行会从 `app\config.example.json` 创建本机专用的 `app\config.json`。实际配置已经被 `.gitignore` 排除。自动识别默认开启；控制台的“规则设置”页可以添加识别失败时使用的兼容进程名，并修改宽限时间。

`-ExecutionPolicy Bypass` 只应用于这次新建的 PowerShell 进程，但仍应先审阅源码，并只从可信仓库获取本项目。

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

该脚本覆盖 PS 5.1 语法、启动事件解析和增量读取、自动/手动配置边界、示例配置、JSON/XAML、脱敏诊断和启动器构建；GitHub Actions 运行同一脚本。

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

必须使用 Git 索引生成上传集合，不要使用网页拖拽整个工作目录：

```powershell
git init -b main
git add .
git status --short --ignored
git diff --cached --name-only
git ls-files -- app/config.json app/logs LeigodAutoPause.exe
```

检查结果必须满足：

- `app/config.json`、`monitor-*.log`、`http-*.log`、`main-*.log`、截图、内存转储、PFX/私钥、PDB 和本地 EXE 均未暂存；
- `app/logs` 下只有 `.gitkeep` 被跟踪；
- `git diff --cached` 中没有账号、Token、本机绝对路径或使用时间线；
- Git 作者邮箱使用 GitHub 提供的 `noreply` 地址；
- 已启用 GitHub Private Vulnerability Reporting，或在 `SECURITY.md` 提供可用的私密渠道。

## 仓库结构

```text
app/                         监控、控制台、自启动与本地配置模板
  ui/MainWindow.xaml        WPF 界面
  logs/.gitkeep             运行日志目录占位文件
src/                         无控制台启动器源码与 manifest
tools/Build.ps1              本地构建脚本
tools/Test.ps1               不联网发布自检
.github/workflows/ci.yml     Windows PowerShell 5.1 CI
LEGAL.md                     合规与法律边界
PRIVACY.md                   数据处理与清理说明
SECURITY.md                  安全策略和漏洞报告
NOTICE.md                    非官方、商标与第三方权利声明
LICENSE                      MIT License
```

## 已知限制

- 雷神客户端日志格式、域名或接口发生变化时，本工具可能失效；
- 自动识别只处理雷神客户端记录的 `launch-local-game` 事件；直接从 Steam、桌面快捷方式或其他平台启动且未经过雷神启动按钮的游戏，需要手动补充进程名；
- 雷神未提供进程名、只提供平台启动器、当前 `game_id` 无法交叉确认或目标进程未实际出现时，本工具会保留不确定状态并阻止自动暂停；可以在规则设置中添加精确进程名，或关闭自动识别后仅使用手动目标；
- 只应操作使用者本人、本机当前合法登录的账号，不支持共享或代管账号；
- 进程判断限于当前 Windows 登录会话，并按雷神事件或手动补充中的精确进程名识别；同一会话中的同名进程会影响判断；
- 本工具不能保证暂停请求成功，也不能避免第三方依据其协议采取账号措施；
- 首次启动监控前已经结束的游戏会话无法追溯；
- 本地日志按 `log_retention_days` 自动清理，但当前不做大小上限或压缩；
- 多份安装使用同名本地互斥锁，不建议同时运行。

## 许可证与声明

本项目原创代码和文档以 [MIT License](LICENSE) 发布。第三方名称、商标、客户端、日志格式、接口和服务不属于该许可范围。请同时阅读 [NOTICE.md](NOTICE.md)、[LEGAL.md](LEGAL.md) 和 [PRIVACY.md](PRIVACY.md)。

在适用法律允许的最大范围内，本软件按现状提供，不保证兼容性、持续可用性、暂停结果或第三方服务稳定性；本说明不排除或限制依法不得排除或限制的责任。
