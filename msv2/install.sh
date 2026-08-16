#!/bin/bash
exec "$(cd "$(dirname "$0")/.." && pwd)/scripts/install-app.sh" "$(cd "$(dirname "$0")" && pwd)"
