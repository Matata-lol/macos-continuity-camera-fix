#!/bin/bash
# Finder launcher: Terminal provides the sudo password and change confirmation.
cd "$(/usr/bin/dirname "$0")" || exit 1
/bin/bash ./macos-camera-fix.sh repair
result=$?
printf '\nExit code / 退出码: %s\nPress Return to close / 按回车关闭\n' "$result"
IFS= read -r
exit "$result"
