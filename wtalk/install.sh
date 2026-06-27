#!/bin/bash
# Convenience wrapper.  Run:  sudo ./install.sh
exec "$(cd "$(dirname "$0")" && pwd)/install/install.sh" "$@"
