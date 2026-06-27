#!/bin/bash
# Convenience wrapper.  Run:  sudo ./uninstall.sh
exec "$(cd "$(dirname "$0")" && pwd)/install/uninstall.sh" "$@"
