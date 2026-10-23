## 这个 PR 做了什么

<!-- 一两句话说清动机与范围。 -->

## 行为变化

<!-- 用户能感知到的变化；没有就写“无”。涉及“什么情况下会自动暂停”的改动必须在这里明确说明。 -->

## 验证方式

<!-- 贴出实际跑过的命令与结果，例如：
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test.ps1
→ SELF_TEST_OK / REGRESSION_TESTS_OK / BUILD_TESTS_OK / UI_SNAPSHOT_OK / RELEASE_TESTS_OK
-->

- [ ] `tools\Test.ps1` 全绿（或说明跳过了哪一步、为什么）
- [ ] `tools\Verify-Upload.ps1` 输出 `UPLOAD_READY`
- [ ] 手动启动过一次控制台，确认界面与本机状态显示正常

## 约定检查

- [ ] 新增/修改的 `.ps1` 保存为 **UTF-8 with BOM**
- [ ] `src/*.cs` 只使用 **C# 5** 语法（无 `?.` / `$""` / `nameof` / 表达式体成员 / `out var`）
- [ ] 改过 `app/ui/MainWindow.xaml` 时，控件名与资源 key 的改动同步到了 C#
- [ ] 没有提交 `app/config.json`、`app/logs/*`、`*.snapshot.png`、`*.exe`、证书私钥或本机路径
- [ ] PR 内容不含 Token、Cookie、雷神客户端原始日志或账号信息
- [ ] 涉及安全问题的改动已按 `SECURITY.md` 走私密渠道沟通
