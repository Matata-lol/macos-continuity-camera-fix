# 故障案例：两个独立问题叠加

[English](CASE-STUDY.md) · [说明文档](../README.zh-CN.md)

本项目来自一次 macOS 27.2 Mac mini 的本地排查。iPhone 在另一台 Mac 上能作为相机使用，但在这台 Mac 上即使通过 USB 连接并信任设备，仍完全不出现在摄像头列表中。另一个本地账户和另一台手机也能复现。本文有意省略个人标识和原始日志。

## 一、明确存在的主机禁用偏好

相机服务记录了 `Continuity Camera is disabled on the host side`。只读运行时检查发现，相关功能标志已启用，但主机开关 getter 返回 false。

继续追踪读取路径，定位到 `CMIOProprietaryDefaultsSource` 和以 root 运行的 `com.apple.cmio.registerassistantservice`。该服务将 `global/` 前缀的键交给服务端标准 defaults 读取。以 root 执行 `defaults read` 确认 `global/continuitycapture/enabled-on-mac` 为 `0`，导出的 plist 进一步确认它是实际存储的布尔值 false，而非缺失值或默认回退。

备份原始 root 偏好域后，仅将这个键改为布尔值 true。运行时 getter 随即返回 true，重启后仍保持。完成 Apple 首次使用引导后，当前用户的相机服务开始发布手机相机和桌上视角设备。

此前检查 `com.apple.cameracapture` 和用户安全控制中心 `.av` plist 并未找到实际的 macOS 后端，本项目不修改这些位置。私有 setter 曾因调用方缺少 entitlement 被拒绝；发布的工具不调用该 setter，不修改系统二进制，也不绕过 entitlement。

## 二、客户端连接到了非当前用户的相机服务

此时视频设备枚举仍返回零个设备。两个本地用户同时保持登录，日志显示：当前用户的新枚举请求连接到了后台用户的 ContinuityCaptureAgent；该进程因为不是控制台用户而停止发布相机。与此同时，当前用户的服务却已发布了手机相机。

保存工作并完整注销后台用户后，新请求连接到当前用户的服务，系统设备列表立即出现 iPhone 摄像头。随后 FaceTime 记录收到首帧预览，视频属性为 1920×1080。这证明视频数据已送达，而不只是出现麦克风或设备发布日志。

这些证据支持该案例中存在多用户注册/路由异常，但仅凭多个服务进程并不能证明其他 Mac 也有相同错误。工具只提供提示，并在后台相机用户未退出时拒绝自动修复；绝不会强制注销其他用户。

## 仍未确定的事项

- 最初是谁或哪个进程将开关写成 false，以及原因。
- 是否所有 macOS 版本都采用相同的内部配置语义。
- 两个账户重新同时登录后是否会稳定复现多用户问题。
- 对目标偏好缺失或已经为 true 的机器是否有帮助。

曾尝试使用管理员权限 `launchctl kickstart` 重启受保护相机服务，但被 SIP 拒绝。最终通过正常重启完成刷新；项目不包含这些命令，也不建议关闭 SIP。原始备份、账户名称、手机名称/UUID 和原始诊断日志均未纳入仓库。

正常配置和设备要求请参考 [Apple 连续互通相机指南](https://support.apple.com/zh-cn/102546)；受管理的相机限制参考 [Apple Restrictions 配置定义](https://github.com/apple/device-management/blob/release/mdm/profiles/com.apple.applicationaccess.yaml)。这些资料说明官方使用条件与策略，不代表 Apple 支持本项目使用的内部偏好修复方法。
