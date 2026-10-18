#!/bin/sh
# Run the Forge suite (unit + integration + invariants). Used by .githooks and CI.
# Usage: scripts/forge-gate.sh            run everything
#        scripts/forge-gate.sh --if-changed <git diff args>
#                                         run only if contracts/ changed in that diff
set -e
cd "$(git rev-parse --show-toplevel)"

if [ "$1" = "--if-changed" ]; then
  shift
  if [ -z "$(git diff --name-only "$@" -- contracts/ 2>/dev/null)" ]; then
    exit 0
  fi
fi

FORGE="$(command -v forge || echo "$HOME/.foundry/bin/forge")"
if [ ! -x "$FORGE" ]; then
  echo "forge-gate: forge not found. Install: curl -L https://foundry.paradigm.xyz | bash && foundryup" >&2
  exit 1
fi

if [ ! -f contracts/lib/forge-std/src/Test.sol ]; then
  git submodule update --init --recursive
fi

echo "forge-gate: running contract tests (unit + integration + invariants)..."
cd contracts && "$FORGE" test
