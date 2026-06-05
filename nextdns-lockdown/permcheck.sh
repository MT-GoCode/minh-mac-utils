#!/bin/bash
#
# permcheck.sh — audit (and optionally fix) ownership/permissions of installed files.
#   sudo ./permcheck.sh            # report
#   sudo ./permcheck.sh --enforce  # fix to expected owner/group/mode
#
# Mirrors the tuple-list audit pattern used by nextdns-discipline/permcheck.sh.
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root:  sudo ./permcheck.sh" >&2; exit 1; }

ENFORCE=0; [ "${1:-}" = "--enforce" ] && ENFORCE=1

# path  owner group mode
ITEMS=(
    "/usr/local/etc/nextdns-lockdown                       root wheel 0700"
    "/usr/local/etc/nextdns-lockdown/nextdns-lockdown.conf root wheel 0644"
    "/usr/local/etc/nextdns-lockdown/doh-blocklist.txt     root wheel 0644"
    "/usr/local/etc/nextdns-lockdown/tor-dirauth.txt       root wheel 0644"
    "/usr/local/etc/nextdns-lockdown/dns-allow.txt         root wheel 0644"
    "/usr/local/bin/nextdns-lockdown                       root wheel 0755"
    "/usr/local/bin/nextdns-lockdownd                      root wheel 0700"
    "/Library/LaunchDaemons/com.nextdnslockdown.enforcerd.plist root wheel 0644"
    "/Library/Application Support/NextDNSLockdown          root wheel 0755"
)

rc=0
for row in "${ITEMS[@]}"; do
    set -- $row; path="$1"; o="$2"; g="$3"; m="$4"
    if [ ! -e "$path" ]; then echo "MISSING  $path"; rc=1; continue; fi
    cur_o="$(stat -f '%Su' "$path")"; cur_g="$(stat -f '%Sg' "$path")"; cur_m="$(stat -f '%Lp' "$path")"
    if [ "$cur_o:$cur_g" = "$o:$g" ] && [ "$cur_m" = "${m#0}" -o "$cur_m" = "$m" ]; then
        echo "ok       $path ($cur_o:$cur_g $cur_m)"
    else
        echo "MISMATCH $path (have $cur_o:$cur_g $cur_m, want $o:$g $m)"; rc=1
        if [ "$ENFORCE" = 1 ]; then chown "$o:$g" "$path"; chmod "$m" "$path"; echo "         -> fixed"; fi
    fi
done
exit $rc
