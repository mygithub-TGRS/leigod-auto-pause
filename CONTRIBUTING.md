# 贡献指南

感谢你愿意改进这个项目。本项目只在 Windows 10/11 上以当前用户身份运行，不需要管理员权限，也不接入任何维护者服务器。

提交改动前请先阅读 [NOTICE.md](NOTICE.md)、[LEGAL.md](LEGAL.md)、[SECURITY.md](SECURITY.md) 和 [PRIVACY.md](PRIVACY.md)。本项目是非官方工具，不接受把项目描述为“官方/已授权集成”的改动，也不接受新增遥测、云同步、远程诊断或自动更新服务。

## 环境

- Windows 10 或 Windows 11；
- Windows PowerShell 5.1（不支持 PowerShell 7）；
- .NET Framework 4.8（系统自带）与系统自带的 `csc.exe`，无需安装 SDK；
- 已安装并登录雷神加速器（部分测试需要能定位到 `leigod.exe`）。

## 构建与测试

```powershell
# 编译控制台 -> LeigodAutoPause.exe
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Build.ps1

# 不联网的发布自检（语法/BOM、XAML↔C# 契约、监控器自检、回归测试、构建、界面快照）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test.ps1

# 生成可发布二进制包 -> dist\LeigodAutoPause-<版本>-win-x64.zip
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Package.ps1

# 上传前隐私与入库集合自检
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Verify-Upload.ps1
```

没有交互式桌面的环境（部分容器/CI）可以用 `-SkipUiSnapshot` 跳过界面快照那一步。

## 硬性约定

1. **所有 `.ps1` 必须保存为带 UTF-8 BOM**：Windows PowerShell 5.1 靠 BOM 识别中文。`Test.ps1` 会把缺 BOM 当成失败。
2. **`src/*.cs` 只能用 C# 5 语法**：编译器是系统自带的旧版 `csc.exe`，不支持 `?.`、`$""`、`nameof`、表达式体成员、`out var`、属性初始化器。这是为了不给用户增加 .NET 运行时安装成本。
3. **XAML 与 C# 的控件契约不能破坏**：C# 用 `Require<TextBlock>("HeaderStatusText")` 绑定控件、用 `Brush("GreenBrush")` 取资源。改 `app/ui/MainWindow.xaml` 时，`Test.ps1` 会静态比对两边；不要为了绕过测试而放宽这条检查。
4. **不要把本机数据提交进仓库**：`app/config.json`、`app/logs/*`、`*.snapshot.png`、`*.exe`、证书私钥都不行。提交前跑 `tools/Verify-Upload.ps1`。
5. **不要在 Issue / PR / 截图里公开**：`account_token`、Cookie、雷神客户端原始日志、完整 `config.json`、`-IncludeSensitiveDetails` 的输出。
6. **业务判定保持保守**：涉及“什么情况下允许自动暂停”的改动必须更保守或等价，不能为了少点一次鼠标而放宽复核条件。
7. **中文文案**：界面与提示使用简体中文，错误信息要说明“发生了什么 + 用户可以怎么做”。

## 提交与 PR

- 一个 PR 只做一件可描述的事；同时包含重构与行为变更时请说明边界；
- 提交信息用“类型: 摘要”，类型取 `feat` / `fix` / `docs` / `chore` / `refactor` / `test`；
- PR 描述里写清：动机、行为变化、验证方式（跑了哪些命令、结果如何）、是否影响隐私与安全边界；
- 涉及安全问题的修复请**先**按 [SECURITY.md](SECURITY.md) 走私密渠道，不要直接开公开 PR。

## 版本与发布

- 版本号只改 `src/AssemblyInfo.cs`（`AssemblyVersion` / `AssemblyFileVersion` / `AssemblyInformationalVersion`），构建与打包都从它读取；
- 同时更新 [CHANGELOG.md](CHANGELOG.md)；
- 发布流程见 [README.md](README.md) 的「发布」小节。
