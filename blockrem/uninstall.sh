#!/bin/bash
# Convenience wrapper.  Run:  sudo ./uninstall.sh [--purge]
exec "$(cd "$(dirname "$0")" && pwd)/install/uninstall.sh" "$@"
