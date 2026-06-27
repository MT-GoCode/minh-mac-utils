#!/bin/bash
# Convenience wrapper.  Run:  sudo ./install.sh [--login]
exec "$(cd "$(dirname "$0")" && pwd)/install/install.sh" "$@"
