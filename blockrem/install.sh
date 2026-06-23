#!/bin/bash
# Convenience wrapper.  Run:  sudo ./install.sh
# Builds + signs (or deploys the prebuilt dist/ bundle), then installs and loads everything.
exec "$(cd "$(dirname "$0")" && pwd)/install/install.sh" "$@"
