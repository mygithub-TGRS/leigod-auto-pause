using System.Reflection;

// 产品元数据与版本号的唯一来源。
// tools\Build.ps1 和 tools\Package.ps1 会从这里读取 AssemblyVersion 作为发布版本，
// 所以这里改一次就够了：EXE 的文件版本、发布包文件名、CI 产物名都会跟着变。
// 注意：这是 C# 源码，按 UTF-8 编译（Build.ps1 显式传 /codepage:65001）。
[assembly: AssemblyTitle("雷神自动暂停（非官方）")]
[assembly: AssemblyDescription("雷神加速器游戏退出自动暂停控制台（非官方）")]
[assembly: AssemblyCompany("Leigod Auto Pause contributors")]
[assembly: AssemblyProduct("Leigod Auto Pause")]
[assembly: AssemblyCopyright("MIT License - unofficial tool")]
[assembly: AssemblyVersion("2.0.0.0")]
[assembly: AssemblyFileVersion("2.0.0.0")]
[assembly: AssemblyInformationalVersion("2.0.0")]
