#!/usr/bin/env bash
set -euo pipefail

if ! command -v roc >/dev/null 2>&1; then
  echo "Error: roc not found in PATH. Install Roc or add it to PATH before running ci/all_tests.sh." >&2
  exit 1
fi

echo "Using $(roc version)"

# Skip zig build if SKIP_ZIG_BUILD is set (useful when a caller only needs Roc bootstrapping)
if [ -z "${SKIP_ZIG_BUILD:-}" ]; then
  echo ""
  echo "Building platform..."
  zig build

  echo ""
  echo "Running tests..."
  zig build test -- --verbose

  echo ""
  echo "Running bundle..."
  BUNDLE_OUTPUT=$(./bundle.sh 2>&1)
  echo "$BUNDLE_OUTPUT"
  BUNDLE_PATH=$(echo "$BUNDLE_OUTPUT" | awk '/^Created:/ { print $2; exit }')

  if [ -z "$BUNDLE_PATH" ]; then
    echo "Error: Could not extract bundle path from output"
    exit 1
  fi

  echo ""
  echo "Running tests with bundled platform..."
  ci/test_bundled_examples.sh "$BUNDLE_PATH"
fi
