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

# Skip zig build if SKIP_ZIG_BUILD is set (used in release testing)
if [ -z "${SKIP_ZIG_BUILD:-}" ]; then
  zig build
fi

echo ""
echo "Checking examples..."
for example in $(ls examples/*.roc); do
  echo "Running: roc check $example"
  roc check "$example" --no-cache
done

echo ""
echo "Running examples..."

examples_to_run=("hello" "hello_world" "fizzbuzz" "match" "stderr" "sum_fold")
for example in "${examples_to_run[@]}"; do
  echo ""
  echo "Running: $example"
  roc "./examples/$example.roc" --no-cache
done

echo ""
echo "Running echo example..."
echo "yoo" | roc examples/echo.roc --no-cache

echo ""
echo "Running echo_multiline example..."
printf "line one\nline two\nline three\n" | roc examples/echo_multiline.roc --no-cache

echo ""
echo "Running \`roc test\` examples..."
roc test examples/tests.roc

echo ""
echo "Running bundle..."
./bundle.sh