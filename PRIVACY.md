# 隐私说明

最后更新：2026-08-30

## 摘要

本项目在用户的 Windows 设备上运行，不运营由项目维护者控制的后端、遥测、广告或自动更新服务。维护者不会自动收到用户的 Token、配置或运行日志。

当前版本会读取雷神客户端本地日志中的 `account_token`，并将其发送到源码固定列明的雷神 HTTPS 主机，以查询账号状态和执行暂停。打开控制台后会立即查询一次，正常打开期间约每 30 秒再次查询；启动后台监控后，会按配置的状态轮询间隔查询。

## 处理的数据

| 数据 | 来源 | 用途 | 本项目存储 | 发送目标 |
| --- | --- | --- | --- | --- |
| `account_token` | 雷神客户端 `resources\llogs\http-*.log` | 查询账号状态、请求暂停 | 不写入本项目配置或日志；运行时在进程内存处理 | `webapi.leigod.com` 的状态和暂停端点 |
| 游戏 ID、启动操作、游戏进程名 | 雷神客户端 `resources\llogs\main-*.log`、本地加速状态文件及用户兼容配置 | 识别由雷神启动的当前游戏并判断是否运行 | `app\config.json`（仅用户兼容配置）、本项目运行日志和短期 `app\logs\runtime-state.json`；不保存原始雷神日志行 | 不发送给项目维护者；当前接口请求体不包含游戏信息 |
| 账号状态 | 雷神接口响应 | 决定是否可以安全暂停 | 本项目运行日志记录 `Active`、`Paused` 或 `Unknown` | 不发送给项目维护者 |
| 时间、客户端/游戏事件、倒计时、结果代码、错误类别 | 本机运行过程 | 状态显示和故障排查 | `app\logs\monitor-YYYY-MM-DD.log` | 不发送给项目维护者 |
| 客户端和配置路径 | 本机配置 | 定位客户端日志和配置 | `app\config.json`；诊断默认只显示末级名称 | 不发送给项目维护者 |
| 网络元数据（源 IP、TLS/HTTP 元数据、默认 User-Agent 等） | 操作系统网络栈和 PowerShell | 建立 HTTPS 请求 | 本项目不主动保存 | 雷神端点可见；代理或其他网络中介按环境可见 |
| Windows 通知内容 | 本工具状态事件 | 提示倒计时或暂停结果 | 本项目不另行保存；Windows 可能保留通知历史 | 不发送给项目维护者 |

雷神客户端原始日志由第三方客户端生成，可能包含本项目没有创建的其他账号或设备信息。本工具只读取最近 5 个 `http-*.log` 文件各自末尾最多 5000 行，并只接受 HTTPS `leigod.com` 域名 URL 中符合长度限制的 `account_token`。自动识别还会读取最近的 `main-*.log` 尾部并持续读取新增完整行，但只解析结构匹配的 `launch-local-game` 事件；事件外的原始字段不会写入本项目文件。

## 网络请求

当前源码中的业务端点只有：

- `https://webapi.leigod.com/api/user/info`
- `https://webapi.leigod.com/api/user/pause`

请求通过 Windows PowerShell `Invoke-RestMethod` 发出，使用基础解析并禁止 HTTP 重定向，同时使用操作系统的证书信任和网络配置。系统代理、企业 TLS 检查、DNS、操作系统日志以及雷神服务端如何处理请求，不受本项目维护者控制。

项目没有证书固定机制。域名、日志格式或接口变化时，工具应当安全失败，但不能保证第三方行为或网络环境。

## 本地保存与清理

- `app\config.json`：持续保留，直到用户删除；
- `app\logs\monitor-*.log`：按日创建并追加，当前没有自动删除或保留期限；
- `app\logs\runtime-state.json`：后台监控运行时保存不含 Token 和本机路径的界面状态，正常退出时删除，异常退出后会因超时失效；
- `app\.stop`：停止监控时创建，重新启动监控时删除；
- `LeigodAutoPause.exe`：本地构建产物，不含账号配置，但未签名；
- Windows 通知：启用通知时，标题和状态摘要可能进入系统通知历史；清理方式由 Windows 设置控制；
- 卸载开机自启不会删除配置、日志或桌面入口。

停止监控后，可以按需删除本项目的本地数据：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\app\Stop-Monitor.ps1
Remove-Item -Path .\app\logs\monitor-*.log -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath .\app\logs\runtime-state.json -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath .\app\config.json -Force -ErrorAction SilentlyContinue
```

删除 `config.json` 后，下次运行会从公开模板重新创建默认配置。上述操作不会删除雷神客户端自己的日志；其清理方式和影响应以雷神官方说明为准。

## 公开报告前的脱敏

不要在 GitHub Issue、Discussion、Pull Request、聊天记录或截图中提交：

- `account_token`、Cookie、手机号、账号标识；
- 雷神客户端的完整 `http-*.log` 或 `main-*.log`；
- 本项目的完整 `config.json` 或 `monitor-*.log`；
- `-IncludeSensitiveDetails` 的原始诊断输出；
- 含用户名、盘符目录、精确使用时间或游戏偏好的截图。

只提交最小复现步骤、版本、经过脱敏的错误类别和必要的局部日志。项目维护者不应要求用户公开完整 Token 或原始客户端日志。

## 分支与再发布版本

任何修改版如果新增遥测、云同步、远程诊断、崩溃上传、账号托管或维护者服务器，必须在启用前明确说明数据目的、类型、接收方、保存期限和关闭方式，并重新评估适用的个人信息保护义务。不得沿用本文件声称“维护者不会收到数据”。
