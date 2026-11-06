# macOS Continuity Camera Fix

[简体中文](README.zh-CN.md) · [Safety & rollback](docs/SAFETY.md) · [Case study](docs/CASE-STUDY.md)

Diagnose an **iPhone missing from the Mac camera list** and safely repair one confirmed cause: an explicitly disabled macOS Continuity Camera host preference. Includes a one-command repair, protected backups, targeted rollback, a Finder launcher, and multiuser-session checks.

Search terms: macOS Continuity Camera not working, iPhone webcam not showing, Mac mini camera, 连续互通相机、连续互通摄像头。

**Experimental, narrow repair — not an Apple-supported or universal fix.** The preference is undocumented. The original incident was resolved on a Mac mini running macOS 27.2; other macOS versions have not been verified with real cameras. The tool supports macOS 13+ system utilities, but only offers a write when the exact existing Boolean `false` is found. A missing value is **not** treated as disabled.

## Quick start

Download the repository using **Code → Download ZIP**, extract it, and open Terminal in that directory. No Homebrew, Python, Ruby, Xcode, or third-party runtime is needed to run the tool. Git users can instead run:

```sh
git clone https://github.com/Matata-lol/macos-continuity-camera-fix.git
cd macos-continuity-camera-fix
```

Read [the script](macos-camera-fix.sh) and [the safety model](docs/SAFETY.md) before granting administrator access. Then run:

```sh
bash macos-camera-fix.sh repair
```

This checks the stored setting, requests `sudo` if needed, prints the exact proposed change, and asks you to type `YES`. It creates a protected backup before making a change. It does not ask you to send anyone your password. If the value is already `true`, it makes no change.

Alternatively, double-click **Run.command** in Finder to run the same interactive workflow in Terminal. If macOS blocks a downloaded launcher, use the reviewed Terminal command above; this project does not require disabling Gatekeeper or SIP. The launcher may not retain its executable bit after some ZIP extraction tools; the Terminal command works without it.

## Commands

| Command | Purpose |
| --- | --- |
| `bash macos-camera-fix.sh` | Read-only check; root preference reported as unreadable without privilege |
| `sudo bash macos-camera-fix.sh check` | Read-only check including the root service preference |
| `sudo bash macos-camera-fix.sh check --logs` | Also count relevant recent log markers; no raw log output |
| `bash macos-camera-fix.sh repair --dry-run` | Evaluate proposed repair without changing preferences or journals |
| `bash macos-camera-fix.sh repair` | Confirm, back up, enable, and verify the stored Boolean |
| `bash macos-camera-fix.sh backups` | List protected transaction IDs and status |
| `bash macos-camera-fix.sh rollback ID` | Restore only the one target preference from a validated transaction |
| `bash macos-camera-fix.sh rollback ID --dry-run` | Preview rollback |

Use `--lang zh` or `--lang en` for output language. `repair` and `rollback` accept `--yes` for explicitly authorized unattended use; it skips confirmation only, never the safety checks. A noninteractive `sudo` session must already be authorized. `--dry-run` can require administrator access to read the real root preference, and uses temporary local files, but does not write preferences or durable transaction records.

The exit code of `check` indicates that the check ran, **not** that the camera works. See [exit codes](docs/SAFETY.md#exit-codes).

## What gets changed?

Exactly one root-owned preference:

```text
Domain: com.apple.cmio.registerassistantservice
Key:    global/continuitycapture/enabled-on-mac
Change: existing Boolean false → Boolean true
```

The script does not create an absent key, coerce a string/integer, import a whole preference domain, call private framework setters, reset TCC, kill services, force a logout, or restart the computer. It does not alter Apple Account, network, managed policy, firewall, SIP, or Gatekeeper settings. It makes no network requests and records no video/audio.

Automatic repair refuses MDM/DEP enrollment, unknown enrollment status, an explicit or malformed `allowCamera` restriction, unfamiliar managed camera-service preferences, unsafe backup storage, unknown GUI sessions, or camera agents owned by background users. These checks are conservative and are not a complete macOS policy audit.

## After repair

1. Save your work and restart the Mac normally so protected services reload their preferences.
2. If other users remain logged in, save their work and fully **Log Out** those users. Switching to your account leaves their services running. The script reports background camera agents as a clue; it does not prove that your Mac has the routing bug seen in the case study.
3. Check Apple's requirements, lock and securely position the iPhone, and select it in FaceTime's **Video** menu. Complete Apple's first-use prompt if it appears.
4. Verify an actual live preview. A `true` preference, a published-device log, or a listed microphone alone does not prove that video works.

Apple requires a compatible iPhone and Mac, the same Apple Account with two-factor authentication, and the appropriate Wi-Fi/Bluetooth and Continuity Camera settings. USB use also requires trusting the Mac. Follow [Apple's current Continuity Camera guide](https://support.apple.com/en-us/102546) for the complete requirements and ordinary troubleshooting.

If the stored value is already enabled, this tool has no further automatic setting change to offer. Follow the session guidance and Apple troubleshooting; do not repeatedly delete preferences or force protected daemons to restart.

## Backups and rollback

Backups stay on this Mac under:

```text
/private/var/db/macos-continuity-camera-fix/<transaction-ID>/
```

Each transaction contains the original domain export, a SHA-256 integrity record, a format version, and a status journal. Directories are root-owned with mode `700`; files have mode `600`. The original domain export may contain private settings: do not upload it to GitHub.

```sh
bash macos-camera-fix.sh backups
bash macos-camera-fix.sh rollback 20261107T000000Z.ABC123
```

Replace the example ID with the actual one printed by the tool. Rollback checks ownership, permissions, symlinks/hardlinks, format, checksum, original Boolean, journal state, and the current value. It restores **only the target key to its original `false`**. Unrelated settings changed after repair remain untouched. Rollback intentionally disables this feature again; it is not an additional repair step.

Successful repeated repair/rollback requests are no-ops. Interrupted or failed operations retain a journal for recovery. A power loss, disk failure, concurrent external writer, or corrupted backup cannot be made risk-free; [read the recovery limits and stale-lock procedure](docs/SAFETY.md). No software can guarantee recovery under every system failure.

## Development

```sh
/bin/bash -n macos-camera-fix.sh
/bin/bash -n Run.command
/bin/bash tests/run.sh
```

The regression suite runs without `sudo`, redirects all preference access to temporary fixtures, and exercises real macOS plist parsing, permissions, backup hashes, refusal paths, write failure, recovery, idempotence, and targeted rollback. It never changes the host camera preference. CI runs the suite on macOS runners; passing CI does not verify a physical iPhone.

See [CONTRIBUTING.md](CONTRIBUTING.md) for privacy and scope rules. Licensed under [MIT](LICENSE). Not affiliated with or endorsed by Apple.
