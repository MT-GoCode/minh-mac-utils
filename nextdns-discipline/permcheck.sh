#!/bin/bash
# Verify (default) or enforce (--enforce) ownership + permissions for every
# nextdns-discipline file. Idempotent: safe to run repeatedly.
#
#   sudo ./permcheck.sh             # report only (PASS/FAIL), changes nothing
#   sudo ./permcheck.sh --enforce   # fix anything wrong, then report
#
# Run with sudo: the credentials file lives inside a 0700 root directory, so a
# normal user cannot even stat it.
set -uo pipefail

ENFORCE=0
[ "${1:-}" = "--enforce" ] && ENFORCE=1

# path  owner  group  mode
ITEMS=(
    "/usr/local/etc/nextdns-discipline             root wheel 0700"
    "/usr/local/etc/nextdns-discipline/credentials root wheel 0600"
    "/usr/local/bin/nextdns-block                  root wheel 4711"
    "/usr/local/bin/nextdns-allow                  root wheel 0700"
    "/usr/local/bin/nextdns-test                   root wheel 0755"
)

if [ "$ENFORCE" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
    echo "--enforce must run as root: sudo $0 --enforce" >&2
    exit 1
fi

rc=0
for row in "${ITEMS[@]}"; do
    # shellcheck disable=SC2086
    set -- $row
    path="$1"; want_owner="$2"; want_group="$3"; want_mode="$4"

    if [ ! -e "$path" ]; then
        echo "MISSING  $path"
        rc=1
        continue
    fi

    if [ "$ENFORCE" -eq 1 ]; then
        chown "$want_owner:$want_group" "$path"
        chmod "$want_mode" "$path"
    fi

    owner=$(stat -f '%Su' "$path")
    group=$(stat -f '%Sg' "$path")
    mode=$(stat -f '%p' "$path"); mode=${mode: -4}   # last 4 octal digits = setuid+perms

    if [ "$owner" = "$want_owner" ] && [ "$group" = "$want_group" ] && [ "$mode" = "$want_mode" ]; then
        echo "OK       $path ($owner:$group $mode)"
    else
        echo "BAD      $path (have $owner:$group $mode, want $want_owner:$want_group $want_mode)"
        rc=1
    fi
done

[ "$rc" -eq 0 ] && echo "All good." || echo "Problems found (see BAD/MISSING above)."
exit $rc
