#!/bin/bash
# No sudo. All preference reads/writes are replaced before any operation runs.
# Real plist parsing, journals, digests, permissions and transaction logic are tested.
# shellcheck source-path=SCRIPTDIR
# Adapters below are called indirectly by the sourced production functions.
# shellcheck disable=SC2329
set -u
cd "$(/usr/bin/dirname "$0")/.." || exit 1
REPO=$PWD
[[ "$(uname -s)" == Darwin ]] || { echo 'Integration fixtures require macOS plutil/stat.'; exit 2; }
TEST_ROOT=$(mktemp -d /private/var/tmp/macos-camera-fix-tests.XXXXXX) || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT
passed=0
failed=0

setup() {
    # shellcheck source=../macos-camera-fix.sh
    source "$REPO/macos-camera-fix.sh"
    umask 077
    CASE_DIR=$(mktemp -d "$TEST_ROOT/case.XXXXXX") || exit 1
    STORE="$CASE_DIR/store"
    SCRATCH="$CASE_DIR/scratch"
    mkdir -m 700 "$SCRATCH"
    STATE_FILE="$CASE_DIR/preference"
    WRITES="$CASE_DIR/writes"
    printf 'false\n' > "$STATE_FILE"
    : > "$WRITES"
    OWNER_UID=$EUID
    YES=1
    FAIL_WRITE=''
    EXPORT_FAIL=0
    CORRUPT_AFTER_WRITE=0
    MANAGED=0
    OTHER_USERS=0
    REJECT_CONFIRM=0
    root_user() { return 0; }
    management_clear() { [[ "$MANAGED" == 0 ]]; }
    background_agents() { [[ "$OTHER_USERS" != unknown ]] || return 1; printf '%s\n' "$OTHER_USERS"; }
    preference_state() { cat "$STATE_FILE"; }
    preference_export() {
        [[ "$EXPORT_FAIL" == 0 ]] || return 1
        local state
        state=$(cat "$STATE_FILE")
        /usr/bin/plutil -create xml1 "$1" || return 1
        /usr/bin/plutil -insert "$KEY" -bool "$state" "$1" || return 1
        /usr/bin/plutil -insert unrelated -string 'preserve me' "$1"
    }
    preference_write() {
        printf '%s\n' "$1" >> "$WRITES"
        [[ "$FAIL_WRITE" != "$1" && "$FAIL_WRITE" != all ]] || return 1
        printf '%s\n' "$1" > "$STATE_FILE"
        if [[ "$CORRUPT_AFTER_WRITE" == 1 && "$1" == true ]]; then printf 'unknown\n' > "$STATE_FILE"; fi
    }
    # Only the fixed system ancestors are omitted for these temporary stores.
    # The production owner/mode/ACL/symlink validators still validate all files.
    store_validate() { secure_directory "$STORE" 700; }
    store_init() {
        if [[ ! -e "$STORE" && ! -L "$STORE" ]]; then mkdir -m 700 "$STORE" || return 3; fi
        store_validate
    }
    confirm_change() { [[ "$REJECT_CONFIRM" == 0 ]] || return 4; }
}

expect_exit() {
    local expected=$1 actual
    shift
    "$@" > "$CASE_DIR/output" 2>&1
    actual=$?
    [[ "$actual" == "$expected" ]] || { cat "$CASE_DIR/output"; echo "expected exit $expected, got $actual"; return 1; }
}
is_state() { [[ "$(cat "$STATE_FILE")" == "$1" ]]; }
no_writes() { [[ ! -s "$WRITES" ]]; }
write_count() { [[ "$(wc -l < "$WRITES" | tr -d ' ')" == "$1" ]]; }
unlock() { rm -f "$STORE/lock/pid"; rmdir "$STORE/lock"; LOCK_HELD=0; }

test_case() {
    local label=$1 fn=$2
    if (setup; trap show_failure_output EXIT; "$fn"); then passed=$((passed+1)); printf 'ok %s - %s\n' "$((passed+failed))" "$label";
    else failed=$((failed+1)); printf 'not ok %s - %s\n' "$((passed+failed))" "$label"; fi
}
show_failure_output() {
    local test_exit=$?
    if [[ "$test_exit" != 0 && -f "$CASE_DIR/output" ]]; then cat "$CASE_DIR/output"; fi
}

happy() {
    expect_exit 0 repair && is_state true && write_count 1 &&
    transaction_validate "$TRANSACTION" && [[ "$(transaction_status "$TRANSACTION")" == applied ]] &&
    [[ "$(/usr/bin/plutil -extract unrelated raw -o - "$TRANSACTION/before.plist")" == 'preserve me' ]] &&
    unlock && expect_exit 0 rollback "${TRANSACTION##*/}" && is_state false && write_count 2 &&
    [[ "$(transaction_status "$TRANSACTION")" == rolled-back ]]
}
already_enabled() { echo true > "$STATE_FILE"; expect_exit 0 repair && no_writes && [[ ! -e "$STORE" ]]; }
enabled_with_background_user() { echo true > "$STATE_FILE"; OTHER_USERS=1; expect_exit 0 repair && no_writes && grep -q 'fully log out' "$CASE_DIR/output"; }
unknown() { echo unknown > "$STATE_FILE"; expect_exit 3 repair && no_writes; }
unreadable() { echo unreadable > "$STATE_FILE"; expect_exit 3 repair && no_writes; }
dry_run() { DRY_RUN=1; expect_exit 0 repair && no_writes && [[ ! -e "$STORE" ]]; }
managed() { MANAGED=1; expect_exit 3 repair && no_writes && [[ ! -e "$STORE" ]]; }
background_user() { OTHER_USERS=1; expect_exit 3 repair && no_writes; }
no_gui() { OTHER_USERS=unknown; expect_exit 3 repair && no_writes; }
cancel() { REJECT_CONFIRM=1; expect_exit 4 repair && no_writes && [[ ! -e "$STORE" ]]; }
backup_failure() { EXPORT_FAIL=1; expect_exit 1 repair && no_writes && is_state false; }
write_failure() { FAIL_WRITE=true; expect_exit 1 repair && is_state false && [[ "$(transaction_status "$TRANSACTION")" == recovered ]]; }
unknown_after_write() { CORRUPT_AFTER_WRITE=1; expect_exit 1 repair && is_state unknown && write_count 1 && [[ "$(transaction_status "$TRANSACTION")" == recovery-required ]]; }
partial_write() {
    preference_write() { printf '%s\n' "$1" >> "$WRITES"; printf '%s\n' "$1" > "$STATE_FILE"; [[ "$1" != true ]]; }
    expect_exit 1 repair && is_state false && write_count 2 && [[ "$(transaction_status "$TRANSACTION")" == recovered ]]
}
failed_recovery() {
    preference_write() { printf '%s\n' "$1" >> "$WRITES"; [[ "$1" != true ]] || echo true > "$STATE_FILE"; return 1; }
    expect_exit 1 repair && is_state true && [[ "$(transaction_status "$TRANSACTION")" == recovery-required ]]
}
lock_collision() { store_init; mkdir "$STORE/lock"; expect_exit 5 repair && no_writes; }
store_symlink() { mkdir "$CASE_DIR/elsewhere"; ln -s "$CASE_DIR/elsewhere" "$STORE"; expect_exit 3 repair && no_writes; }
store_permissions() { mkdir -m 777 "$STORE"; expect_exit 3 repair && no_writes; }
changed_at_confirmation() { confirm_change() { echo true > "$STATE_FILE"; }; expect_exit 3 repair && no_writes; }
policy_at_confirmation() { confirm_change() { MANAGED=1; }; expect_exit 3 repair && no_writes; }
rollback_unknown() { expect_exit 0 repair && unlock || return; echo unknown > "$STATE_FILE"; expect_exit 3 rollback "${TRANSACTION##*/}" && write_count 1; }
rollback_dry() { expect_exit 0 repair && unlock || return; DRY_RUN=1; expect_exit 0 rollback "${TRANSACTION##*/}" && is_state true && write_count 1 && [[ "$(transaction_status "$TRANSACTION")" == applied ]]; }
rollback_idempotent() { happy && unlock && expect_exit 0 rollback "${TRANSACTION##*/}" && write_count 2; }
rollback_already_false() { expect_exit 0 repair && unlock || return; echo false > "$STATE_FILE"; expect_exit 0 rollback "${TRANSACTION##*/}" && write_count 1; }
rollback_cancel() { expect_exit 0 repair && unlock || return; REJECT_CONFIRM=1; expect_exit 4 rollback "${TRANSACTION##*/}" && is_state true && write_count 1; }
rollback_write_failure() { expect_exit 0 repair && unlock || return; FAIL_WRITE=false; expect_exit 1 rollback "${TRANSACTION##*/}" && is_state true && [[ "$(transaction_status "$TRANSACTION")" == applied ]]; }
rollback_changed_at_confirmation() { expect_exit 0 repair && unlock || return; confirm_change() { echo unknown > "$STATE_FILE"; }; expect_exit 3 rollback "${TRANSACTION##*/}" && write_count 1; }
path_traversal() { expect_exit 2 rollback '../../etc/passwd' && no_writes; }
missing_backup() { store_init; expect_exit 3 rollback '20260101T000000Z.ABCDEF' && no_writes; }
tampered_backup() { expect_exit 0 repair && unlock || return; /usr/bin/plutil -replace unrelated -string modified "$TRANSACTION/before.plist"; expect_exit 3 rollback "${TRANSACTION##*/}" && write_count 1; }
symlink_backup() { expect_exit 0 repair && unlock || return; mv "$TRANSACTION/before.plist" "$CASE_DIR/outside.plist"; ln -s "$CASE_DIR/outside.plist" "$TRANSACTION/before.plist"; expect_exit 3 rollback "${TRANSACTION##*/}" && write_count 1; }
hardlink_backup() { expect_exit 0 repair && unlock || return; ln "$TRANSACTION/before.plist" "$CASE_DIR/alias.plist"; expect_exit 3 rollback "${TRANSACTION##*/}" && write_count 1; }
loose_backup() { expect_exit 0 repair && unlock || return; chmod 644 "$TRANSACTION/before.plist"; expect_exit 3 rollback "${TRANSACTION##*/}" && write_count 1; }
invalid_format() { expect_exit 0 repair && unlock || return; echo 999 > "$TRANSACTION/format"; expect_exit 3 rollback "${TRANSACTION##*/}" && write_count 1; }
invalid_status() { expect_exit 0 repair && unlock || return; echo nonsense > "$TRANSACTION/status"; expect_exit 3 rollback "${TRANSACTION##*/}" && write_count 1; }
interrupted_transaction() { store_init && transaction_create || return; expect_exit 3 repair && no_writes && expect_exit 0 rollback "${TRANSACTION##*/}" && is_state false; }
undone_id_cannot_undo_new_change() { happy && unlock || return; echo true > "$STATE_FILE"; expect_exit 0 rollback "${TRANSACTION##*/}" && is_state true && write_count 2; }
repeat_repair() { expect_exit 0 repair && expect_exit 0 repair && write_count 1; }
rollback_preserves_other_settings() {
    # A write adapter that maintains a full mock domain demonstrates that only
    # the one target key is sent to the production write abstraction.
    local domain="$CASE_DIR/mock.plist"
    preference_export "$domain" || return
    preference_state() { plist_state "$domain"; }
    preference_export() { cp "$domain" "$1"; }
    preference_write() { /usr/bin/plutil -replace "$KEY" -bool "$1" "$domain"; }
    expect_exit 0 repair && unlock || return
    /usr/bin/plutil -replace unrelated -string 'changed after repair' "$domain"
    expect_exit 0 rollback "${TRANSACTION##*/}" && [[ "$(/usr/bin/plutil -extract unrelated raw -o - "$domain")" == 'changed after repair' ]]
}
typed_plists() {
    local f="$CASE_DIR/typed.plist"
    /usr/bin/plutil -create xml1 "$f"
    [[ "$(plist_state "$f")" == unknown ]] || return 1
    /usr/bin/plutil -insert "$KEY" -string false "$f"
    [[ "$(plist_state "$f")" == unknown ]] || return 1
    /usr/bin/plutil -replace "$KEY" -integer 0 "$f"
    [[ "$(plist_state "$f")" == unknown ]] || return 1
    /usr/bin/plutil -replace "$KEY" -bool false "$f"
    [[ "$(plist_state "$f")" == false ]] || return 1
    /usr/bin/plutil -replace "$KEY" -bool true "$f"
    [[ "$(plist_state "$f")" == true ]] || return 1
    echo 'broken plist' > "$f"
    [[ "$(plist_state "$f")" == unknown ]]
}
owner_guard() { OWNER_UID=0; secure_directory /private/var/db && ! secure_directory "$CASE_DIR"; }
policy_types() {
    local f="$CASE_DIR/policy.plist"
    /usr/bin/plutil -create xml1 "$f"
    /usr/bin/plutil -insert allowSiri -bool false "$f"
    camera_policy_clear "$f" || return 1
    /usr/bin/plutil -insert allowCamera -bool false "$f"
    ! camera_policy_clear "$f" || return 1
    /usr/bin/plutil -replace allowCamera -bool true "$f"
    camera_policy_clear "$f" || return 1
    /usr/bin/plutil -replace allowCamera -string true "$f"
    ! camera_policy_clear "$f" || return 1
    echo broken > "$f"
    ! camera_policy_clear "$f"
}
help_no_sudo() { expect_exit 0 /bin/bash ./macos-camera-fix.sh --help; }
invalid_options() { expect_exit 2 /bin/bash ./macos-camera-fix.sh check --yes && expect_exit 2 /bin/bash ./macos-camera-fix.sh repair --logs && expect_exit 2 /bin/bash ./macos-camera-fix.sh rollback ../bad; }
environment_ignored() {
    # The child shell must expand these variables, not this test process.
    # shellcheck disable=SC2016
    expect_exit 0 /usr/bin/env DOMAIN=evil KEY=evil STORE=/tmp/evil OWNER_UID=502 /bin/bash -c 'source ./macos-camera-fix.sh; [[ "$DOMAIN" == com.apple.cmio.registerassistantservice && "$KEY" == global/continuitycapture/enabled-on-mac && "$STORE" == /private/var/db/macos-continuity-camera-fix && "$OWNER_UID" == 0 ]]'
}

test_case 'repair and targeted rollback with validated backup' happy
test_case 'already enabled is a no-op' already_enabled
test_case 'enabled preference still reports background-user guidance' enabled_with_background_user
test_case 'unknown value refused' unknown
test_case 'unreadable value refused' unreadable
test_case 'dry run makes no store or preference writes' dry_run
test_case 'management policy refused' managed
test_case 'background user requires logout' background_user
test_case 'unknown GUI session refused' no_gui
test_case 'cancelled repair makes no writes' cancel
test_case 'backup failure prevents preference write' backup_failure
test_case 'write failure retains original setting' write_failure
test_case 'unknown verification state avoids blind recovery' unknown_after_write
test_case 'partial write failure recovers original false' partial_write
test_case 'failed recovery retains actionable journal' failed_recovery
test_case 'concurrent or stale lock prevents writes' lock_collision
test_case 'symlink backup store refused' store_symlink
test_case 'writable backup store refused' store_permissions
test_case 'preference rechecked after confirmation' changed_at_confirmation
test_case 'policy rechecked after confirmation' policy_at_confirmation
test_case 'rollback rejects unknown current state' rollback_unknown
test_case 'rollback dry run preserves state' rollback_dry
test_case 'rollback is idempotent' rollback_idempotent
test_case 'rollback recognizes externally restored false' rollback_already_false
test_case 'rollback cancellation preserves state' rollback_cancel
test_case 'failed rollback remains retryable' rollback_write_failure
test_case 'rollback rechecks after confirmation' rollback_changed_at_confirmation
test_case 'rollback rejects path traversal' path_traversal
test_case 'missing backup refused' missing_backup
test_case 'changed backup digest refused' tampered_backup
test_case 'symlink backup refused' symlink_backup
test_case 'hardlink backup refused' hardlink_backup
test_case 'insecure backup permissions refused' loose_backup
test_case 'unknown backup format refused' invalid_format
test_case 'invalid journal status refused' invalid_status
test_case 'prepared transaction blocks a new repair and can be undone' interrupted_transaction
test_case 'old rollback ID does not undo later state' undone_id_cannot_undo_new_change
test_case 'repeat repair does not duplicate writes' repeat_repair
test_case 'rollback preserves unrelated concurrent preferences' rollback_preserves_other_settings
test_case 'real plist parser distinguishes Boolean, integer, string and absent' typed_plists
test_case 'camera policy parser distinguishes unrelated, allowed, denied and invalid' policy_types
if [[ "$EUID" != 0 ]]; then test_case 'production directory owner guard' owner_guard; fi
test_case 'help needs no privilege' help_no_sudo
test_case 'invalid command options rejected before privilege' invalid_options
test_case 'environment cannot redirect privileged targets' environment_ignored
printf '1..%s\nPassed: %s; failed: %s\n' "$((passed+failed))" "$passed" "$failed"
[[ "$failed" == 0 ]]
