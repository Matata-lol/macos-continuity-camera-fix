# macOS 连续互通相机修复工具

[English](README.md) · [安全与回滚](docs/SAFETY.zh-CN.md) · [故障案例](docs/CASE-STUDY.zh-CN.md)

针对 **Mac 摄像头列表完全找不到 iPhone** 的问题，提供一条命令完成检测和特定原因的修复：重新打开被明确关闭的 macOS 连续互通相机主机开关。包含受保护备份、单项回滚、Finder 双击入口，以及多用户会话检查。

搜索关键词：macOS Continuity Camera not working、iPhone webcam not showing、Mac mini camera、连续互通相机、连续互通摄像头。

**这是范围有限的实验性修复，不是 Apple 官方工具，也不是万能修复器。** 该偏好是未公开的内部配置。最初案例在 macOS 27.2 的 Mac mini 上修复成功，其他系统版本尚未完成真实相机验证。脚本要求 macOS 13+，但只有找到完全匹配、已存在的布尔值 `false` 才允许写入。**缺失值不等于功能被禁用。**

## 快速使用

在 GitHub 点击 **Code → Download ZIP**，解压后在该目录打开终端。运行工具不需要安装 Homebrew、Python、Ruby、Xcode 或其他运行时。已安装 Git 的用户也可以执行：

```sh
git clone https://github.com/Matata-lol/macos-continuity-camera-fix.git
cd macos-continuity-camera-fix
```

授予管理员权限前，请查看[脚本](macos-camera-fix.sh)和[安全说明](docs/SAFETY.zh-CN.md)。然后运行：

```sh
bash macos-camera-fix.sh repair --lang zh
```

脚本会检查存储值，按需通过 `sudo` 请求管理员权限，显示具体改动，再要求输入 `YES`。真正写入前必须先成功生成并校验备份。密码由本机 `sudo` 处理，无需发送给任何人。已为 `true` 时不做修改。

如需 Finder 快捷入口，请先在项目目录运行一次 `chmod +x Run.command`，再双击 **Run.command** 进入相同的终端交互流程。网页上传和部分 ZIP 解压工具不保留可执行权限。如果 macOS 阻止打开下载的启动器，请使用审阅后的上述终端命令；不需要关闭 Gatekeeper 或 SIP。终端命令不依赖可执行标记。

## 命令

| 命令 | 用途 |
| --- | --- |
| `bash macos-camera-fix.sh` | 默认只读检测；无管理员权限时不读取 root 偏好 |
| `sudo bash macos-camera-fix.sh check --lang zh` | 只读检测，包含 root 服务偏好 |
| `sudo bash macos-camera-fix.sh check --logs --lang zh` | 同时统计近期相关日志标记，不输出原始日志 |
| `bash macos-camera-fix.sh repair --dry-run --lang zh` | 预演修复，不修改偏好或事务记录 |
| `bash macos-camera-fix.sh repair --lang zh` | 确认、备份、开启并校验存储值 |
| `bash macos-camera-fix.sh backups --lang zh` | 列出受保护的备份 ID 和事务状态 |
| `bash macos-camera-fix.sh rollback ID --lang zh` | 根据有效备份仅恢复目标开关 |
| `bash macos-camera-fix.sh rollback ID --dry-run --lang zh` | 预演回滚 |

`--lang en` 切换英文输出。`repair` 和 `rollback` 支持 `--yes`，用于明确授权的自动运行；它只跳过确认，不跳过安全检查。非交互运行时必须已有有效的 `sudo` 授权。预演仍可能需要管理员权限读取真实偏好，并会使用临时本地文件，但不更改偏好或持久事务记录。

`check` 返回成功仅表示完成了检查，**不代表相机已能使用**。详见[退出码](docs/SAFETY.zh-CN.md#退出码)。

## 修改范围

仅修改 root 用户偏好域中的一项：

```text
偏好域：com.apple.cmio.registerassistantservice
键：    global/continuitycapture/enabled-on-mac
变化：  已存在的布尔值 false → 布尔值 true
```

脚本不会创建缺失的键，不会把字符串或整数强行转换为布尔值，不会恢复整个偏好域，不调用私有框架 setter，不重置 TCC，不杀服务，不强制注销或重启。不修改 Apple 账户、网络、受管理策略、防火墙、SIP 或 Gatekeeper。运行时不联网、不上传信息、不录制音视频。

发现 MDM/DEP 注册、注册状态未知、明确或类型异常的 `allowCamera` 限制、不熟悉的受管理相机服务偏好、备份目录不安全、图形会话未知，或后台用户仍运行相机服务时，自动修复会停止。这些检查采取保守策略，并不等同于完整的 macOS 策略审计。

## 修复后如何验证

1. 保存工作，正常重启 Mac，让受保护服务重新加载配置。
2. 若其他用户仍保持登录，保存他们的工作并通过苹果菜单完整**注销**。切换回自己的账户不会结束后台用户的服务。脚本只能将后台相机服务作为线索，不能据此断言你的 Mac 也存在案例中的路由异常。
3. 检查 Apple 的使用条件，将 iPhone 锁屏、放稳，在 FaceTime 的“视频”菜单中选择它。如出现系统首次使用引导，请完成引导。
4. 确认真正出现实时视频预览。开关为 `true`、日志显示发布了设备，或仅出现 iPhone 麦克风，都不能单独证明视频已恢复。

Apple 要求使用兼容的 iPhone 和 Mac、同一个开启双重认证的 Apple 账户，并满足 Wi-Fi、蓝牙和连续互通相机设置要求。通过 USB 使用还需要信任 Mac。完整条件和常规排查步骤请参阅 [Apple 连续互通相机指南](https://support.apple.com/zh-cn/102546)。

如果存储开关已经开启，本工具不再提供其他自动配置修改。请按照会话提示和 Apple 指南排查，避免反复删除偏好或强制重启受保护服务。

## 备份和回滚

备份仅保存在本机：

```text
/private/var/db/macos-continuity-camera-fix/<事务 ID>/
```

每个事务包含修改前的偏好域导出、SHA-256 完整性记录、格式版本和状态记录。目录由 root 持有、权限为 `700`，文件为 `600`。完整偏好域可能含有私人设置，**不要把备份上传到 GitHub**。

```sh
bash macos-camera-fix.sh backups --lang zh
bash macos-camera-fix.sh rollback 20261107T000000Z.ABC123 --lang zh
```

请将示例 ID 替换为工具实际输出的 ID。回滚会校验所有者、权限、软硬链接、格式、校验和、原始布尔值、事务状态和当前值，**只把目标开关恢复为原始 `false`**，保留修复后其他偏好的改动。回滚会重新关闭该功能，不是进一步修复的步骤。

重复执行成功的修复或回滚会保持幂等。中断或失败的操作会保留事务记录以便恢复。但断电、磁盘故障、其他进程并发写入或备份损坏等情况无法做到绝对无风险，请阅读[恢复限制与遗留锁处理](docs/SAFETY.zh-CN.md)。本项目不承诺在所有系统故障下都能保证恢复。

## 开发与测试

```sh
/bin/bash -n macos-camera-fix.sh
/bin/bash -n Run.command
/bin/bash tests/run.sh
```

回归测试无需 `sudo`，所有偏好读写都替换为临时测试数据；真实测试 macOS plist 解析、权限、备份校验和，以及拒绝条件、写入失败、恢复、幂等和单项回滚。不会修改测试机器的真实相机开关。CI 在 macOS 运行器中执行；CI 通过不等于已经验证了真实 iPhone。

贡献前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。采用 [MIT 许可证](LICENSE)。本项目与 Apple 无关联，未获 Apple 背书。
