# 安全策略

## 支持范围

安全修复只针对默认分支的最新源码。仓库尚未发布稳定版本前，不承诺维护旧副本、第三方分支或非官方二进制。

## 信任模型

- 项目逻辑在当前 Windows 用户上下文运行，不请求管理员权限；
- 正常控制台会联网查询账号状态，后台监控可能发送暂停请求；
- Token 只应来自 HTTPS `leigod.com` 域名的客户端日志 URL，请求目标固定写在源码中；
- 开机自启会隐藏启动 PowerShell，因此只允许从没有向普通本机用户开放写权限的目录安装；
- `leigod_executable` 和快捷方式目标只接受本地磁盘上的 `leigod.exe`；
- 本地构建的 EXE 未签名，不应被当作来源可信证明。

## 敏感信息

请勿在 Issue、Discussion、Pull Request、截图或日志中提交：

- `account_token`、Cookie、账号、手机号或设备标识；
- 雷神客户端的 `resources\llogs\http-*.log` 或 `main-*.log`；
- 本项目完整的 `app\config.json` 或 `app\logs\monitor-*.log`；
- 使用 `-IncludeSensitiveDetails` 生成的原始诊断输出；
- 私钥、PFX、内存转储或任何能够关联个人身份、设备和使用时间的信息。

雷神客户端日志本身已在磁盘保存 Token。本工具不会把提取出的 Token 再写入自己的配置、日志或诊断输出，但会在当前进程内处理，并发送到源码列明的雷神 HTTPS 端点。

## 报告漏洞

发布仓库后应启用 GitHub Private Vulnerability Reporting，并优先通过该功能提交：

- 受影响版本或提交；
- 不含真实 Token 的最小复现；
- 影响、前置条件和建议修复；
- 必要时使用明显无效的测试数据。

若 Private Vulnerability Reporting 尚未启用，只能创建一个**不含漏洞细节和敏感信息**的公开 Issue，请维护者建立私密沟通渠道。不要为了证明问题而上传完整客户端日志或可用 Token。

## 凭据疑似泄露

1. 立即删除公开内容和仓库附件；
2. 不要在新的公开评论中再次粘贴泄露值；
3. 通过雷神官方客户端或客服采取账号保护措施；
4. 如内容已经进入 Git 历史，应重写历史并视为凭据已泄露，而不是只新增一个删除提交；
5. 核对 GitHub 缓存、Release、Actions 日志、Issue 附件和分支副本。

项目维护者不应索取用户的真实 Token、完整 `http-*.log` 或账号密码。
