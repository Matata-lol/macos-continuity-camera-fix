#!/bin/bash
# macos-continuity-camera-fix — MIT License. Requires Apple's Bash 3.2+.
# No downloads, telemetry, private API calls, service termination, or SIP changes.

VERSION='1.0.0'
DOMAIN='com.apple.cmio.registerassistantservice'
KEY='global/continuitycapture/enabled-on-mac'
STORE='/private/var/db/macos-continuity-camera-fix'
OWNER_UID=0
LANGUAGE=en
case "${LC_ALL:-${LANG:-}}" in zh*) LANGUAGE=zh ;; esac
YES=0
DRY_RUN=0
SHOW_LOGS=0
LOCK_HELD=0
SCRATCH=''
TRANSACTION=''

say() { if [[ "$LANGUAGE" == zh ]]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }
error() { say "$1" "$2" >&2; }
root_user() { [[ "$EUID" -eq 0 ]]; }

usage() {
    cat <<'USAGE'
macos-continuity-camera-fix 1.0.0
Usage: bash macos-camera-fix.sh [check|repair|backups|rollback ID] [options]
  check       Read-only checks (default). Use sudo for the root preference.
  repair      Back up, then change an EXISTING Boolean false to true only.
  backups     List this tool's local transaction IDs (administrator access).
  rollback ID Restore ONLY the target key from a validated transaction.
Options:
  --lang en|zh   Output language / 输出语言
  --dry-run     Preview repair/rollback; no preference or journal changes
  --yes         Skip the repair/rollback confirmation (not safety checks)
  --logs        With check only: summarize recent log markers, without raw logs
  --help        Show this help
  --version     Show version
Exit: 0 completed/no-op; 1 operation/verification error; 2 usage/platform;
      3 refused/unknown state; 4 cancelled; 5 transaction lock held.
USAGE
}

# These narrow adapters are replaced by in-memory/scratch fixtures in tests.
# There is deliberately no production environment-variable override for tools,
# preference domains, keys, backup paths, privilege, or platform detection.
platform_check() {
    [[ "$(/usr/bin/uname -s)" == Darwin ]] || { error 'macOS only.' '仅支持 macOS。'; return 2; }
    local version major
    version=$(/usr/bin/sw_vers -productVersion) || return 2
    major=${version%%.*}
    [[ "$major" =~ ^[0-9]+$ ]] && [[ "$major" -ge 13 ]] || {
        error 'Requires macOS 13 or later. No changes made.' '需要 macOS 13 或更新版本，未进行更改。'; return 2;
    }
    [[ -x /usr/bin/plutil && -x /usr/bin/defaults ]] || return 2
}

scratch_init() {
    if [[ -z "$SCRATCH" ]]; then
        # A fixed system temp parent, never a caller-controlled TMPDIR.
        SCRATCH=$(/usr/bin/mktemp -d /private/var/tmp/macos-camera-fix.XXXXXX) || return 1
        /bin/chmod 700 "$SCRATCH" || return 1
    fi
}

cleanup() {
    if [[ "$LOCK_HELD" == 1 ]]; then
        /bin/rm -f "$STORE/lock/pid"
        /bin/rmdir "$STORE/lock" 2>/dev/null || true
        LOCK_HELD=0
    fi
    if [[ -n "$SCRATCH" && "$SCRATCH" == /private/var/tmp/macos-camera-fix.* && -d "$SCRATCH" ]]; then
        /bin/rm -f "$SCRATCH/current.plist" "$SCRATCH/markers.log"
        /bin/rmdir "$SCRATCH" 2>/dev/null || true
    fi
}

plist_state() {
    local file=$1 value
    /usr/bin/plutil -lint "$file" >/dev/null 2>&1 || { printf 'unknown\n'; return; }
    value=$(/usr/bin/plutil -extract "$KEY" raw -expect bool -o - "$file" 2>/dev/null) || {
        printf 'unknown\n'; return;
    }
    case "$value" in true|false) printf '%s\n' "$value" ;; *) printf 'unknown\n' ;; esac
}

preference_export() { /usr/bin/defaults export "$DOMAIN" - > "$1" 2>/dev/null; }
preference_state() {
    root_user || { printf 'unreadable\n'; return; }
    # SCRATCH must be initialized in the parent shell, not a command substitution.
    preference_export "$SCRATCH/current.plist" || { printf 'unknown\n'; return; }
    plist_state "$SCRATCH/current.plist"
}
preference_write() {
    case "$1" in true|false) /usr/bin/defaults write "$DOMAIN" "$KEY" -bool "$1" ;; *) return 1 ;; esac
}

camera_policy_clear() {
    local file=$1 type value xml
    [[ -f "$file" && ! -L "$file" ]] || return 1
    /usr/bin/plutil -lint "$file" >/dev/null 2>&1 || return 1
    xml=$(/usr/bin/plutil -convert xml1 -o - "$file" 2>/dev/null) || return 1
    [[ "$xml" == *$'<plist version="1.0">\n<dict'* ]] || return 1
    # An unrelated Screen Time payload does not imply a camera prohibition.
    type=$(/usr/bin/plutil -type allowCamera "$file" 2>/dev/null) || return 0
    [[ "$type" == bool ]] || return 1
    value=$(/usr/bin/plutil -extract allowCamera raw -expect bool -o - "$file" 2>/dev/null) || return 1
    [[ "$value" == true ]]
}

management_clear() {
    local status file
    status=$(/usr/bin/profiles status -type enrollment 2>/dev/null) || return 1
    [[ "$status" == *'Enrolled via DEP: No'* && "$status" == *'MDM enrollment: No'* ]] || return 1
    # Never edit managed preferences. Check Apple's allowCamera restriction;
    # unfamiliar managed camera-service domains are conservatively refused.
    for file in /Library/Managed\ Preferences/com.apple.{applicationaccess,cameracapture,cmio.registerassistantservice}.plist \
        /Library/Managed\ Preferences/*/com.apple.{applicationaccess,cameracapture,cmio.registerassistantservice}.plist; do
        if [[ -e "$file" || -L "$file" ]]; then
            case "$file" in
                */com.apple.applicationaccess.plist) camera_policy_clear "$file" || return 1 ;;
                *) return 1 ;;
            esac
        fi
    done
}

background_agents() {
    local console_uid processes
    console_uid=$(/usr/bin/stat -f '%u' /dev/console) || return 1
    [[ "$console_uid" =~ ^[0-9]+$ && "$console_uid" -ge 500 ]] || return 1
    processes=$(/bin/ps -axo uid=,comm=) || return 1
    printf '%s\n' "$processes" | /usr/bin/awk -v current="$console_uid" '
        $2 == "/usr/libexec/ContinuityCaptureAgent" && $1 != current { owners[$1] = 1 }
        END { for (u in owners) n++; print n+0 }'
}

safety_gate() {
    management_clear || {
        error 'Managed/policy configuration found, or management status is unknown. Automatic repair refused.' \
            '发现管理/策略配置，或无法确定管理状态。已拒绝自动修复。'; return 3;
    }
    local count
    count=$(background_agents) || {
        error 'Cannot verify the active GUI session. Run from a logged-in Mac desktop.' '无法确认当前图形会话。请在已登录的 Mac 桌面中运行。'; return 3;
    }
    [[ "$count" == 0 ]] || {
        error 'Another user has a camera agent. Save their work, fully log out that user, then retry. Fast user switching is insufficient.' \
            '后台用户仍运行相机服务。请保存其工作并完整注销该用户后重试；仅切换用户不够。'; return 3;
    }
}

confirm_change() {
    [[ "$YES" == 1 ]] && return 0
    [[ -t 0 ]] || { error 'Interactive confirmation required; automation must explicitly pass --yes.' '需要交互确认；自动运行必须明确添加 --yes。'; return 4; }
    local answer
    say 'Type YES to apply this exact change:' '输入 YES 确认执行上述更改：'
    IFS= read -r answer || return 4
    [[ "$answer" == YES ]] || return 4
}

secure_directory() {
    local path=$1 exact=${2:-} uid mode acl
    [[ -d "$path" && ! -L "$path" ]] || return 1
    uid=$(/usr/bin/stat -f '%u' "$path") || return 1
    mode=$(/usr/bin/stat -f '%Lp' "$path") || return 1
    [[ "$uid" == "$OWNER_UID" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
    [[ -z "$exact" || "$mode" == "$exact" ]] || return 1
    acl=$(/bin/ls -lde "$path") || return 1
    [[ "${acl%% *}" != *+* ]] || return 1
}

secure_file() {
    local file=$1
    [[ -f "$file" && ! -L "$file" ]] || return 1
    [[ "$(/usr/bin/stat -f '%u:%Lp:%l' "$file")" == "$OWNER_UID:600:1" ]] || return 1
    local acl
    acl=$(/bin/ls -le "$file") || return 1
    [[ "${acl%% *}" != *+* ]]
}

store_validate() {
    local path
    for path in /private /private/var /private/var/db; do secure_directory "$path" || return 3; done
    secure_directory "$STORE" 700 || return 3
}

store_init() {
    local path
    for path in /private /private/var /private/var/db; do secure_directory "$path" || return 3; done
    if [[ ! -e "$STORE" && ! -L "$STORE" ]]; then /bin/mkdir -m 700 "$STORE" || return 3; fi
    store_validate || { error 'Unsafe backup directory; refusing to use it.' '备份目录权限或类型不安全，拒绝使用。'; return 3; }
}

lock_acquire() {
    /bin/mkdir -m 700 "$STORE/lock" 2>/dev/null || {
        error 'Another operation or a stale lock exists. See docs/SAFETY.md; no preference changed.' '存在并发操作或遗留锁。请查看 docs/SAFETY.zh-CN.md；未更改偏好。'; return 5;
    }
    LOCK_HELD=1
    printf '%s\n' "$$" > "$STORE/lock/pid" || return 1
}

valid_id() { [[ "$1" =~ ^[0-9]{8}T[0-9]{6}Z\.[A-Za-z0-9]{6}$ ]]; }
transaction_status() { /bin/cat "$1/status"; }
transaction_mark() {
    printf '%s\n' "$2" > "$1/status.next" && /bin/mv -f "$1/status.next" "$1/status"
}

no_unfinished_transaction() {
    local dir state
    for dir in "$STORE"/*; do
        [[ "$dir" == "$STORE/lock" ]] && continue
        [[ -e "$dir" || -L "$dir" ]] || continue
        if ! valid_id "${dir##*/}" || ! transaction_validate "$dir"; then
            error 'An invalid transaction exists. Inspect the backup store before continuing.' '存在无效事务。请检查备份目录后再继续。'; return 3;
        fi
        state=$(transaction_status "$dir") || return 3
        case "$state" in
            rolled-back|recovered) ;;
            *) error "Unresolved transaction: ${dir##*/}. Use rollback with this ID first." "存在未结束事务：${dir##*/}。请先对该 ID 执行 rollback。"; return 3 ;;
        esac
    done
}

transaction_create() {
    TRANSACTION=$(/usr/bin/mktemp -d "$STORE/$(/bin/date -u +%Y%m%dT%H%M%SZ).XXXXXX") || return 1
    preference_export "$TRANSACTION/before.plist" || return 1
    /bin/chmod 600 "$TRANSACTION/before.plist" || return 1
    [[ "$(plist_state "$TRANSACTION/before.plist")" == false ]] || return 3
    (cd "$TRANSACTION" && /usr/bin/shasum -a 256 before.plist > before.sha256) || return 1
    printf '1\n' > "$TRANSACTION/format" || return 1
    transaction_mark "$TRANSACTION" prepared || return 1
    transaction_validate "$TRANSACTION"
}

transaction_validate() {
    local dir=$1 file expected actual state
    valid_id "${dir##*/}" && [[ "$dir" == "$STORE/"* ]] || return 3
    secure_directory "$dir" 700 || return 3
    for file in before.plist before.sha256 format status; do secure_file "$dir/$file" || return 3; done
    [[ "$(/bin/cat "$dir/format")" == 1 ]] || return 3
    expected=$(/bin/cat "$dir/before.sha256") || return 3
    actual=$(cd "$dir" && /usr/bin/shasum -a 256 before.plist) || return 3
    [[ "$expected" == "$actual" && "$(plist_state "$dir/before.plist")" == false ]] || return 3
    state=$(transaction_status "$dir") || return 3
    case "$state" in prepared|applied|rolled-back|recovered|recovery-required) ;; *) return 3 ;; esac
}

recover_failed_write() {
    local state
    state=$(preference_state)
    case "$state" in
        false) transaction_mark "$TRANSACTION" recovered || true ;;
        true)
            if preference_write false && [[ "$(preference_state)" == false ]]; then
                transaction_mark "$TRANSACTION" recovered || true
                error 'Verification failed; the original Boolean false was restored.' '校验失败；已恢复原始布尔值 false。'
            else
                transaction_mark "$TRANSACTION" recovery-required || true
                error 'Automatic recovery failed. Keep the backup and run rollback with its ID.' '自动恢复失败。请保留备份并使用其 ID 执行 rollback。'
            fi ;;
        *)
            transaction_mark "$TRANSACTION" recovery-required || true
            error 'State is now unknown; refusing another blind write. Backup retained for recovery.' '当前状态未知，拒绝再次盲目写入。备份已保留用于恢复。' ;;
    esac
    return 1
}

repair() {
    local state
    state=$(preference_state)
    case "$state" in
        true)
            say 'The stored switch is already true. No change or backup needed; this does not prove video works.' '已存储的开关已经为 true，无需更改或备份；这不代表视频已正常工作。'
            check
            return 0 ;;
        false) ;;
        *) error 'No existing Boolean false was confirmed. Missing, unreadable, or non-Boolean values are not repaired.' '未确认存在布尔值 false。缺失、无法读取或非布尔值均不自动修复。'; return 3 ;;
    esac
    safety_gate || return $?
    say "Proposed change: root $DOMAIN / $KEY: false -> true." "拟更改：root 用户的 ${DOMAIN} / ${KEY}：false -> true。"
    say "Backup and recovery journal: $STORE (root-only)." "备份和恢复记录：${STORE}（仅 root 可访问）。"
    if [[ -e "$STORE" || -L "$STORE" ]]; then
        store_validate && no_unfinished_transaction || return 3
    fi
    [[ "$DRY_RUN" == 0 ]] || { say 'Dry run complete. No preference or journal changes.' '预演完成，未更改偏好或事务记录。'; return 0; }
    confirm_change || return $?
    store_init && lock_acquire || return $?
    no_unfinished_transaction || return $?
    # Re-check after confirmation/locking; no atomic CAS API is available.
    safety_gate || return $?
    [[ "$(preference_state)" == false ]] || { error 'Preference changed during confirmation. Aborting.' '确认期间偏好发生变化，已停止。'; return 3; }
    transaction_create || { error 'Backup failed validation. No preference write attempted.' '备份未通过校验，未尝试更改偏好。'; return 1; }
    say "Recovery ID: ${TRANSACTION##*/}" "恢复 ID：${TRANSACTION##*/}"
    [[ "$(preference_state)" == false ]] || return 3
    if ! preference_write true; then recover_failed_write; return 1; fi
    if [[ "$(preference_state)" != true ]]; then recover_failed_write; return 1; fi
    transaction_mark "$TRANSACTION" applied || { error 'Preference enabled, but journal update failed. Use the printed recovery ID.' '开关已开启，但事务记录更新失败。请保留已输出的恢复 ID。'; return 1; }
    say 'Stored Boolean verified: true. Restart the Mac normally, then verify the iPhone preview in FaceTime.' '已验证存储值为布尔值 true。请正常重启 Mac，再在 FaceTime 中验证 iPhone 预览。'
    say "Undo: bash macos-camera-fix.sh rollback ${TRANSACTION##*/}" "撤销：bash macos-camera-fix.sh rollback ${TRANSACTION##*/}"
}

rollback() {
    local id=$1 dir state status
    valid_id "$id" || { error 'Invalid recovery ID. Supply an ID, not a path.' '恢复 ID 无效。请提供 ID，而非路径。'; return 2; }
    store_validate || return 3
    dir="$STORE/$id"
    transaction_validate "$dir" || { error 'Backup validation failed. Nothing restored.' '备份校验失败，未执行恢复。'; return 3; }
    status=$(transaction_status "$dir") || return 3
    case "$status" in rolled-back|recovered) say 'This transaction is already undone. No change.' '该事务已经撤销，未更改。'; return 0 ;; esac
    state=$(preference_state)
    case "$state" in true|false) ;; *) error 'Current value is unknown/non-Boolean. Refusing to overwrite it.' '当前值未知或非布尔值，拒绝覆盖。'; return 3 ;; esac
    say 'Rollback restores only the target Boolean to false. Other preferences are preserved.' '回滚仅将本工具修改的布尔开关恢复为 false，保留其他偏好。'
    [[ "$DRY_RUN" == 0 ]] || { say 'Dry run complete. No changes.' '预演完成，未更改。'; return 0; }
    confirm_change || return $?
    lock_acquire || return $?
    transaction_validate "$dir" || return 3
    status=$(transaction_status "$dir") || return 3
    case "$status" in rolled-back|recovered) return 0 ;; esac
    state=$(preference_state)
    case "$state" in
        true) preference_write false || return 1 ;;
        false) ;;
        *) return 3 ;;
    esac
    [[ "$(preference_state)" == false ]] || { error 'Rollback verification failed. Backup retained.' '回滚校验失败，备份已保留。'; return 1; }
    transaction_mark "$dir" rolled-back || return 1
    say 'Rollback verified: false. Restart normally if the running camera service has cached the old value.' '已验证回滚为 false。如果运行中的相机服务仍缓存旧值，请正常重启。'
}

list_backups() {
    local dir
    [[ -e "$STORE" || -L "$STORE" ]] || { say 'No backups from this tool.' '没有本工具创建的备份。'; return 0; }
    store_validate || return 3
    for dir in "$STORE"/*; do
        [[ "$dir" == "$STORE/lock" ]] && continue
        [[ -e "$dir" || -L "$dir" ]] || continue
        if transaction_validate "$dir"; then printf '%s  %s\n' "${dir##*/}" "$(transaction_status "$dir")";
        else printf '%s  INVALID\n' "${dir##*/}"; fi
    done
}

log_summary() {
    # Explicit opt-in. Raw lines are temporary, local, mode 600; never printed/uploaded.
    if ! /usr/bin/log show --last 10m --style compact --info \
        --predicate 'process == "ContinuityCaptureAgent" AND (eventMessage CONTAINS "disabled on the host side" OR eventMessage CONTAINS "mismatched console user" OR eventMessage CONTAINS "Publish Device")' \
        > "$SCRATCH/markers.log" 2>/dev/null; then
        say 'Recent logs unavailable.' '无法读取近期日志。'; return;
    fi
    /usr/bin/awk '
        /disabled on the host side/ { disabled++ }
        /mismatched console user/ { mismatch++ }
        /Publish Device/ { publish++ }
        END { printf "Recent log markers (10 min): host_disabled=%d console_mismatch=%d published=%d\n", disabled, mismatch, publish }' "$SCRATCH/markers.log"
    say 'Historical markers are clues, not proof of the current state or a successful preview.' '历史日志标记仅供排查，不能证明当前状态或预览成功。'
}

check() {
    local state count
    printf 'macos-continuity-camera-fix %s | macOS %s\n' "$VERSION" "$(/usr/bin/sw_vers -productVersion)"
    state=$(preference_state)
    printf 'Stored host switch: %s\n' "$state"
    case "$state" in
        unreadable) say 'For the root service preference, run: sudo bash macos-camera-fix.sh check' '如需读取 root 服务偏好，请运行：sudo bash macos-camera-fix.sh check' ;;
        unknown) say 'Missing/unreadable/wrong type: no safe automatic repair is established.' '缺失、无法读取或类型不符：尚无可靠的自动修复依据。' ;;
        false) say 'An explicit disabled switch exists; repair will check policy/session safety before offering a change.' '存在明确关闭的开关；repair 会先检查策略及会话条件，再提供修复。' ;;
        true) say 'Stored switch enabled. This is not a runtime/preview test.' '存储开关已开启；这不是运行时或视频预览测试。' ;;
    esac
    if management_clear; then say 'Management guard: no blocking enrollment/policy file detected.' '管理检查：未发现阻止修复的注册状态或策略文件。';
    else say 'Management guard: managed/policy configuration or unknown status. Automatic repair will refuse.' '管理检查：存在管理/策略配置或状态未知，将拒绝自动修复。'; fi
    if count=$(background_agents); then
        printf 'Background camera-agent owners: %s\n' "$count"
        if [[ "$count" != 0 ]]; then say 'Save work and fully log out other users before testing. Their background agents can be a clue, not proof of a routing bug.' '请保存工作并完整注销其他用户后再测试。后台相机服务是排查线索，不代表一定存在路由错误。'; fi
    else say 'GUI session: unknown (use the local desktop).' '图形会话：未知（请使用本机桌面）。'; fi
    [[ "$SHOW_LOGS" == 0 ]] || log_summary
    say 'Next: lock/mount the iPhone, check Apple prerequisites, and choose it in FaceTime. See README.md.' '下一步：锁屏并放稳 iPhone，检查 Apple 使用条件，在 FaceTime 中选择相机。详见 README.zh-CN.md。'
}

main() {
    export PATH='/usr/bin:/bin:/usr/sbin:/sbin'
    export LC_ALL=C
    umask 077
    local command=check recovery_id='' script_path
    local original_args=("$@")
    if [[ $# -gt 0 && "$1" != --* ]]; then command=$1; shift; fi
    if [[ "$command" == rollback ]]; then [[ $# -gt 0 ]] || { usage; return 2; }; recovery_id=$1; shift; fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --lang) [[ $# -ge 2 && ( "$2" == en || "$2" == zh ) ]] || return 2; LANGUAGE=$2; shift ;;
            --yes) YES=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --logs) SHOW_LOGS=1 ;;
            --help) usage; return 0 ;;
            --version) printf '%s\n' "$VERSION"; return 0 ;;
            *) usage; return 2 ;;
        esac
        shift
    done
    case "$command" in check|repair|backups|rollback) ;; *) usage; return 2 ;; esac
    [[ "$SHOW_LOGS" == 0 || "$command" == check ]] || return 2
    [[ ( "$YES" == 0 && "$DRY_RUN" == 0 ) || "$command" == repair || "$command" == rollback ]] || return 2
    if [[ "$command" == rollback ]]; then valid_id "$recovery_id" || return 2; fi
    platform_check || return $?
    if [[ "$command" != check ]] && ! root_user; then
        say 'Administrator access is needed to inspect/change the root camera-service preference and protected backups.' '需要管理员权限才能读取/更改 root 相机服务偏好及受保护备份。'
        script_path=$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && printf '%s/%s' "$PWD" "$(/usr/bin/basename "${BASH_SOURCE[0]}")") || return 1
        if [[ -t 0 ]]; then /usr/bin/sudo -- /bin/bash "$script_path" "${original_args[@]}" --lang "$LANGUAGE";
        else /usr/bin/sudo -n -- /bin/bash "$script_path" "${original_args[@]}" --lang "$LANGUAGE"; fi
        return $?
    fi
    scratch_init || return 1
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    case "$command" in
        check) check ;;
        repair) repair ;;
        backups) list_backups ;;
        rollback) rollback "$recovery_id" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; exit $?; fi
