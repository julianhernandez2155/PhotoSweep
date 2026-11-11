#!/bin/zsh
# Runs the tests from a fresh build of the test target.
#
# With only the Command Line Tools installed (seen on Swift 6.4), rebuilding the test target on
# top of an earlier build can fail with "plugin for module 'TestingMacros' not found". Building
# it fresh avoids that. With full Xcode, plain `swift test` works as well.
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ -d .build ]]; then
    find .build -type d -name 'SweepCoreTests*.build' -prune -exec rm -rf {} + 2>/dev/null || true
fi
swift test "$@"
