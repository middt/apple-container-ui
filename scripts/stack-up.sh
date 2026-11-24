#!/usr/bin/env bash
# Headless "Stack Up": imports a Compose file into Vessel and deploys it on apple/container,
# through the same code path as the "Stack Up" button.
#
#   ./scripts/stack-up.sh examples/vnext-runtime/vnext-infra/docker-compose.yml
#
# The stack is stored in Vessel's settings, so it also appears in the app (restart Vessel).
set -euo pipefail
cd "$(dirname "$0")/.."
FILE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
VESSEL_STACK_UP="${FILE}" exec ./scripts/test.sh --filter StackUpTool
