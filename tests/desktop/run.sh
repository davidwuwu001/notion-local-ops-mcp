#!/bin/bash
set -euo pipefail
# Runtime fixtures must not inherit the user's exported service configuration.
for variable in "${!NOTION_LOCAL_OPS_@}"; do unset "$variable"; done
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="$(mktemp -d -t notion-ops-runtime-test)"
trap 'rm -rf "$BUILD_DIR"' EXIT
swiftc -parse-as-library "$REPO_DIR/desktop/Runtime.swift" "$REPO_DIR/tests/desktop/RuntimeSelfTest.swift" -o "$BUILD_DIR/RuntimeSelfTest"
"$BUILD_DIR/RuntimeSelfTest"
swiftc "$REPO_DIR/desktop/ConsoleTypes.swift" "$REPO_DIR/tests/desktop/ConsoleTypesCheck.swift" -o "$BUILD_DIR/ConsoleTypesCheck"
"$BUILD_DIR/ConsoleTypesCheck"
