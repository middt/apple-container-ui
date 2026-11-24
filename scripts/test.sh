#!/usr/bin/env bash
# Runs the unit tests (Swift Testing) with only CommandLineTools installed.
#
# SwiftPM in CommandLineTools does not always pass the Swift Testing macro plugin to the
# compiler, which fails with "plugin for module 'TestingMacros' not found". Passing the
# plugin directory explicitly makes the build deterministic. With a full Xcode install the
# extra flag is harmless.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVELOPER_DIR_PATH="$(xcode-select -p)"
PLUGIN_DIR="${DEVELOPER_DIR_PATH}/usr/lib/swift/host/plugins/testing"

if [ -d "${PLUGIN_DIR}" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "${PLUGIN_DIR}" "$@"
else
    exec swift test "$@"
fi
