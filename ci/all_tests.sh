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
echo "Running \`roc test\` examples..."
roc test examples/tests.roc

echo ""
echo "Building examples with roc build..."

# Detect platform for executable extension
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
  EXE_EXT=".exe"
else
  EXE_EXT=""
fi

mkdir -p build-output

# Build and run simple examples
for example in hello hello_world fizzbuzz match sum_fold; do
  echo ""
  echo "Building: $example"
  roc build "./examples/$example.roc" --output "build-output/$example$EXE_EXT" --no-cache
  echo "Running compiled: $example"
  "./build-output/$example$EXE_EXT"
done

# Test exit.roc (expects exit code 23)
echo ""
echo "Building: exit"
roc build "./examples/exit.roc" --output "build-output/exit$EXE_EXT" --no-cache
set +e
"./build-output/exit$EXE_EXT"
EXIT_CODE=$?
set -e
if [ "$EXIT_CODE" -eq 23 ]; then
  echo "exit example correctly returned exit code 23"
else
  echo "ERROR: exit returned $EXIT_CODE, expected 23"
  exit 1
fi

# Test echo.roc with piped input
echo ""
echo "Building: echo"
roc build "./examples/echo.roc" --output "build-output/echo$EXE_EXT" --no-cache
echo "Running compiled: echo (with piped input)"
echo "test input" | "./build-output/echo$EXE_EXT"

# Test stderr.roc
echo ""
echo "Building: stderr"
roc build "./examples/stderr.roc" --output "build-output/stderr$EXE_EXT" --no-cache
echo "Running compiled: stderr"
"./build-output/stderr$EXE_EXT"

rm -rf build-output

echo ""
echo "Running bundle..."
./bundle.sh