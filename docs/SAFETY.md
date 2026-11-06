# Safety, rollback, and limits

[简体中文](SAFETY.zh-CN.md) · [README](../README.md)

## Trust boundary

Review the local script before running it with sudo. The tool uses Apple's system executables and Bash, never downloads or executes remote code, and never sends telemetry. Environment variables cannot redirect the privileged domain, key, store, or system-command paths. Do not run an untrusted modified copy or a copy another local user can edit while you run it. The tool cannot defend against an already-compromised root account or operating system.

The preference is undocumented. Utility compatibility with macOS 13+ is not a promise that the same internal setting exists or has the same meaning on every release. Actual video recovery has been observed in one macOS 27.2 incident. Unknown/missing/malformed values cause refusal, not speculative writes.

## Write conditions

Repair requires all of the following:

- macOS 13+ and administrator access to the root service preference.
- An existing, typed Boolean `false` exported by `defaults`.
- No DEP/MDM enrollment, with a readable enrollment result. The English output is parsed with `LC_ALL=C`; unfamiliar output causes refusal.
- No known camera denial in managed `com.apple.applicationaccess` files (`allowCamera=false`, or a malformed type), and no managed `com.apple.cameracapture` / `com.apple.cmio.registerassistantservice` file. Unrelated Screen Time keys do not count as camera restrictions. This is a conservative guard, not a complete policy engine.
- A recognizable local GUI console user and no ContinuityCaptureAgent owned by another user.
- Safe, root-owned backup directories, with no group/world write access on the fixed system ancestors; mode `700` and no ACL entries on the store/transaction directories.
- No unfinished/invalid transaction or competing lock, explicit confirmation (or `--yes`), and a fully validated backup.

These checks are repeated at relevant points after confirmation. There is no documented atomic compare-and-swap API for this preference. Another privileged process could still change it between the final read and write. Avoid concurrent settings tools.

## Backup format

`/private/var/db/macos-continuity-camera-fix/YYYYMMDDTHHMMSSZ.XXXXXX/`

| File | Meaning |
| --- | --- |
| `before.plist` | Original root preference domain; potentially private; never published |
| `before.sha256` | SHA-256 of the export; detects corruption, not a signature against root tampering |
| `format` | Currently `1` |
| `status` | `prepared`, `applied`, `recovered`, `recovery-required`, or `rolled-back` |

The validated files must be root-owned, mode `600`, regular files with one hard link and no ACL entries or symbolic links. Journal status updates use rename within the protected directory. A lock directory serializes operations from this tool. Backups are retained; the script has no purge command.

A backup is validated before the preference write. If the write fails, or its stored value cannot be verified, recovery is attempted **only when the value is still a recognized Boolean**. Unknown state stops further automatic writes and retains the journal. SIGINT/SIGTERM normally release the lock; interruption after a write can leave a `prepared` transaction, which can be rolled back. The journal is for recovery and is not an atomic filesystem/preference transaction; power loss and hardware failure remain limitations.

## Rollback semantics

Run `bash macos-camera-fix.sh backups`, then `bash macos-camera-fix.sh rollback ID`.

Only IDs in this tool's fixed store are accepted; arbitrary paths and imported plist files are rejected. The tool checks the digest, original `false`, metadata, current type, and journal. It writes just the target key, never uses `defaults import`, and therefore does not restore unrelated settings from an old full-domain snapshot.

If the current value is already `false`, rollback can close the transaction without writing it again. A completed rollback/recovery ID cannot be reused to undo a later repair. Unknown or non-Boolean current values are refused. A valid Boolean `true` written later by some other tool is indistinguishable from this tool's `true`: review the change history before rolling back. This is a documented conflict-detection limit.

Rollback does not require the repair policy/session gate: it only restores the validated original disabled state, so a user can undo an earlier repair even after the environment changes. It never alters policy files. Restart normally afterward if services cache the value.

## Interrupted operations and stale locks

First stop and read the output. Do not delete the store or import the entire backup domain.

1. List transactions with `bash macos-camera-fix.sh backups`.
2. For `prepared` or `recovery-required`, try `rollback ID`; a valid Boolean state is required. Preserve an `INVALID` transaction for investigation. An incomplete export before any write can leave an invalid transaction that intentionally blocks a new repair.
3. If a lock blocks recovery, read its PID locally:

   ```sh
   sudo cat /private/var/db/macos-continuity-camera-fix/lock/pid
   ps -p PID -o pid,etime,command
   ```

   Replace `PID` with the number. If an operation is active, let it finish. A PID may be reused; inspect the command. **Only after confirming that no instance of this tool is running**, remove the stale lock, not any backups:

   ```sh
   sudo rm /private/var/db/macos-continuity-camera-fix/lock/pid
   sudo rmdir /private/var/db/macos-continuity-camera-fix/lock
   ```

   If the PID file is absent after a crash, the first command may report no such file. Do not force-remove a nonempty lock directory. Retry `rollback ID`.

4. If validation or rollback still fails, retain the backup, note the exit code and redacted summary, and seek review. The program deliberately has no `--force` or “repair unknown defaults” override.

The script does not reverse a manual logout, restart, phone trust decision, or Apple's onboarding flow. Its rollback covers its one preference mutation.

## Privacy

Default diagnostics print tool/macOS versions, the stored switch status, management assessment, and a count of background camera-agent owners. They do not print usernames, phone names, device UUIDs, Apple Accounts, or serial numbers.

`check --logs` reads a narrow 10-minute unified-log slice into a temporary protected file and prints counts for host-disabled, console-mismatch, and device-published markers. It never uploads or prints the raw slice. Temporary files are removed on normal exit; SIGKILL/power loss can leave a mode-700 temporary directory in `/private/var/tmp`. Root check/repair/rollback also use a temporary domain export. Protected long-term backups intentionally remain on disk.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Check completed, successful operation, preview/dry-run completed, or no-op; not proof of working video |
| 1 | Operation, backup, verification, or recovery error; inspect output/journal |
| 2 | Invalid arguments or unsupported platform |
| 3 | Refused because evidence, policy, session, or backup validation is unsafe/unknown |
| 4 | Confirmation cancelled or unavailable |
| 5 | Concurrent operation or stale lock |
| 130 / 143 | Interrupted by signal; inspect the journal |

`sudo` itself can return its own authentication/authorization error before the script runs with privilege.
