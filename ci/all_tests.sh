#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "roc-src" ]; then
  echo "Building roc from pinned commit..."
  ROC_COMMIT=$(python3 ci/get_roc_commit.py)

  git init roc-src
  cd roc-src
  git remote add origin https://github.com/roc-lang/roc
  git fetch --depth 1 origin "$ROC_COMMIT"
  git checkout --detach "$ROC_COMMIT"

  zig build roc

  # Add to GITHUB_PATH if running in CI, otherwise add to local PATH
  if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$(pwd)/zig-out/bin" >> "$GITHUB_PATH"
  else
    export PATH="$(pwd)/zig-out/bin:$PATH"
  fi

  cd ..
else
  echo "roc-src already exists, skipping roc build"
fi

# Ensure roc is in PATH for local runs
export PATH="$(pwd)/roc-src/zig-out/bin:$PATH"

zig build

for example in examples/*.roc; do
  # Skip stdin examples except echo.roc which we handle separately
  if grep -q "Stdin" "$example" && [[ "$example" != "examples/echo.roc" ]]; then
    echo "Skipping $example (contains Stdin)"
    continue
  fi

  # Handle echo.roc separately to provide input
  if [[ "$example" == "examples/echo.roc" ]]; then
    echo ""
    echo "==== Running $example (with piped input) ===="
    roc check "$example"
    echo "test input" | roc "$example" --no-cache
    echo "✓ $example completed successfully"
    continue
  fi

  # Handle exit.roc separately to check exit code
  if [[ "$example" == "examples/exit.roc" ]]; then
    echo ""
    echo "==== Running $example (expecting exit code 23) ===="
    roc check "$example"
    # Capture exit code without triggering set -e
    EXIT_CODE=0
    roc "$example" || EXIT_CODE=$?
    if [ $EXIT_CODE -eq 23 ]; then
      echo "✓ $example returned expected exit code 23"
    else
      echo "✗ $example returned exit code $EXIT_CODE (expected 23)"
      exit 1
    fi
    continue
  fi

  echo ""
  echo "==== Running $example ===="
  roc check "$example"
  roc "$example"
done

./bundle.sh
