#!/bin/sh
# platforms.yml's self-test: the OS argument and the resolved profile arrive.
set -eu
os=$1
case "$os" in ubuntu|macos|windows) ;; *) echo "::error::os is '$os'"; exit 1 ;; esac
case "${R_ACTIONS_PROFILE:-}" in quick|full) ;; *) echo "::error::R_ACTIONS_PROFILE is '${R_ACTIONS_PROFILE:-}'"; exit 1 ;; esac
echo "platform.sh ran on $os at profile $R_ACTIONS_PROFILE"
