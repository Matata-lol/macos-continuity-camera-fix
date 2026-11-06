# Contributing / 参与贡献

Please keep fixes narrow and evidence-based. Preserve macOS Bash 3.2 compatibility, absolute paths for privileged system commands, strict Boolean type checks, backup-before-write, targeted rollback, and fail-closed behavior. Add regression coverage for changes to any mutation or recovery path. Update both language editions together.

Run `bash tests/run.sh` on macOS without sudo. The suite must never access the real root camera preference. CI hardware cannot verify a phone; report physical-device testing separately with macOS version/build, architecture, symptom, tool version, outcome, and whether multiple users were logged in.

Do not submit raw unified logs, preference exports, phone UUIDs, Apple Account identifiers, serial numbers, real usernames, or private filesystem paths. Use the issue template and review any command output before sharing. The script never uploads diagnostics automatically.

请保持修复范围明确且有证据支持。保留 Bash 3.2 兼容性、特权命令绝对路径、布尔类型检查、先备份后写入、单项回滚及未知状态停止处理的原则。涉及写入或恢复流程的更改必须附回归测试，中英文文档同步更新。

在 macOS 中以普通用户运行 `bash tests/run.sh`，测试不得读取或更改真实 root 相机偏好。CI 不能验证真实手机；实际设备结果请单独说明系统版本/构建号、架构、症状、工具版本、结果和多用户登录情况。

请勿上传原始日志、偏好备份、设备 UUID、Apple 账户、序列号、真实用户名或私人路径。使用 Issue 模板并自行审查输出。本工具不会自动上传诊断信息。
