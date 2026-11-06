# Case study: two independent blockers

[简体中文](CASE-STUDY.zh-CN.md) · [README](../README.md)

This project grew out of a local Mac mini investigation on macOS 27.2. The iPhone worked as a camera on another Mac, but was absent from this Mac's camera list even over trusted USB. A second local account with another phone reproduced the absence. Personal identifiers and raw logs are intentionally omitted.

## 1. An explicit host-side disabled preference

The camera agent logged `Continuity Camera is disabled on the host side`. Read-only runtime investigation found the host-enable getter false while the relevant feature flag remained enabled.

Tracing the getter's backend led to `CMIOProprietaryDefaultsSource` and the root `com.apple.cmio.registerassistantservice` service. Its preference handler routed keys with the `global/` prefix to the server's standard defaults. A root `defaults read` confirmed that `global/continuitycapture/enabled-on-mac` was `0`; the exported plist confirmed an actual Boolean false, not an absent/defaulted value.

The original root domain was backed up and that one key changed to Boolean true. The runtime getter became true and remained true after reboot. Apple's first-use Continuity Camera UI was completed, and the current user's camera agent published the phone camera and Desk View.

Earlier investigations of `com.apple.cameracapture` and the per-user secure Control Center `.av` plist did not locate the actual macOS backend. This project does not edit those stores. A private setter rejected the caller for missing entitlements; the shipped tool does not call that setter, patch binaries, or bypass entitlements.

## 2. A client connected to the inactive user's agent

Video discovery still returned zero devices. Two local users were simultaneously logged in. Logs correlated new enumeration requests from the active user with client connections at the inactive user's ContinuityCaptureAgent. That agent declined to publish cameras because it was not the console user, while the active user's agent was publishing the phone.

After saving work and fully logging out the inactive user, enumeration requests reached the active user's agent. The system camera list immediately included the iPhone camera. FaceTime subsequently logged its first received preview frame with 1920×1080 video attributes. This confirmed delivery of video data beyond a mere microphone listing or device-publication message.

This supports a multiuser registration/routing problem in that incident. The presence of several agents alone is not sufficient to prove the same bug on another Mac; the tool gives guidance and declines automatic repair until the user resolves the session condition. It never logs out another user.

## What remains unknown

- Who or what originally wrote false, and why.
- Whether all macOS versions use the same internal preference semantics.
- Whether the multiuser issue recurs consistently after logging both accounts in again.
- Whether this workflow helps a device whose exact typed preference is absent or already true.

An attempted privileged `launchctl kickstart` of protected system camera services was rejected by SIP. The investigation used a normal restart instead; the project does not include these commands or suggest disabling SIP. The exported backup, account names, phone names/UUIDs, and raw diagnostics from the incident are not part of this repository.

For ordinary setup and device requirements, use [Apple's Continuity Camera guide](https://support.apple.com/en-us/102546). For the documented managed camera restriction, see [Apple's Restrictions schema](https://github.com/apple/device-management/blob/release/mdm/profiles/com.apple.applicationaccess.yaml). These sources describe supported setup/policy; they do not endorse this project's undocumented preference repair.
