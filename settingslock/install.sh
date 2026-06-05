#!/bin/bash
# settingslock one-command installer. Run as your normal user (not sudo):
#     ./install.sh
exec "$(cd "$(dirname "$0")" && pwd)/install/install.sh" "$@"
