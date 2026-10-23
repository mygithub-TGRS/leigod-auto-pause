# 变更日志

结构参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号参考 [语义化版本](https://semver.org/lang/zh-CN/)。

2.0.0 之前的版本由 PowerShell 承载 WPF 控制台，仓库没有维护变更日志；本文件从 2.0.0 开始记录。

## [未发布]

## [2.0.0] - 2026-10-23

控制台从“PowerShell 承载的 WPF 窗口”改为原生 C# / WPF 应用；后台监控与业务脚本保持不变。

### 新增

- `LeigodAutoPause.exe` 现在是控制台本体的进程：拥有独立的 AppUserModelID、图标与版本信息，可固定到任务栏、可签名；
- 任务栏跳转列表：概览 / 规则设置 / 运行日志 / 诊断 / 打开日志目录；
- 单实例激活：再次启动会把已打开的窗口切到指定面板并带到前台，不再只弹一句“控制台已经打开”；
- 命令行参数：`--panel`（初始面板）、`--snapshot`（渲染界面快照后退出）、`--auto-close`（到点关闭）；
- `app/Set-AutoStart.ps1`：开机自启开关的独立入口，复用 `SecurityHelpers.ps1` 的 ACL 闸门；
- 启动或界面快照失败时写入 `app/logs/ui-error.log`（仅本机，不外发）；
- `tools/Package.ps1`：生成 `dist/LeigodAutoPause-<版本>-win-x64.zip` 与 SHA256；
- `tools/Sign.ps1`：对 EXE 做 Authenticode 签名并验证结果；
- `src/AssemblyInfo.cs`：版本号单源，构建、打包、CI 产物名都从它派生；
- CI 在测试通过后产出可发布的二进制包 artifact。

### 变更

- 界面加载方式不变（运行时加载 `app/ui/MainWindow.xaml`），但全部绑定与刷新逻辑改写为 C#：状态判定、文案、刷新节奏、失败处理与原实现逐条对齐；
- 开机自启开关改为后台线程执行，ACL 校验期间界面不再假死；失败时把开关拨回真实状态并在页脚给出原因；
- `tools/Test.ps1` 增加两道防线：XAML ↔ C# 的控件/资源契约检查、真实启动控制台渲染一帧的界面冒烟测试；
- `app/Install-AutoStart.ps1` 支持发布包布局（没有 `src`/`tools` 时不再要求构建脚本）；
- 控制台声明系统 DPI 感知与 Windows 10/11 兼容性清单。

### 移除

- 删除 `app/LeigodAutoPause.UI.ps1`（1448 行 PowerShell 界面）与旧启动器 `src/Launcher.cs`。

### 已知限制

- 控制台已是原生进程，但后台监控仍是隐藏的 `powershell.exe`；严格单进程需要把监控也迁到 C#；
- 未签名的二进制仍会触发 SmartScreen 或“无法验证发布者”提示；签名证书需自备，仓库不提供。

## 版本号约定

- `MAJOR`：界面承载方式、配置文件结构或本地数据布局发生不兼容变化；
- `MINOR`：新增功能且保持向后兼容；
- `PATCH`：修复缺陷、调整文案与内部实现。
