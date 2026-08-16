#!/bin/bash
# Remove the retired setuid `sudome` binary and its credentials. demonlock now grants/revokes admin
# itself (Admin.swift), so a leftover setuid-root sudome would be a parallel, delay-free path to admin
# that defeats the release valve. Safe to run repeatedly. Run: sudo ./uninstall.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo $0"; exit 1; }

removed=0
if [ -e /usr/local/bin/sudome ]; then rm -f /usr/local/bin/sudome; echo "removed /usr/local/bin/sudome"; removed=1; fi
if [ -d /usr/local/etc/sudome ]; then rm -rf /usr/local/etc/sudome; echo "removed /usr/local/etc/sudome"; removed=1; fi
# Drop any per-user sudome NOPASSWD override it may have left.
for f in /etc/sudoers.d/sudome-*; do [ -e "$f" ] && { rm -f "$f"; echo "removed $f"; removed=1; }; done

[ "$removed" = 1 ] && echo "✓ sudome fully removed." || echo "✓ nothing to remove — sudome is not installed."