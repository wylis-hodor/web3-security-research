#!/usr/bin/env bash
# Check for DELEGATECALL in a contract's *runtime* bytecode and print matches + count.
# For: GNU bash, version 3.2.57(1)-release (x86_64-apple-darwin20)
#
# Usage:
#   ./check_delegatecall.sh [--show N] <solidity-path> <contract-name>
# Example:
#   ./check_delegatecall.sh --show 5 src/factories/ComponentBeaconFactory.sol ComponentBeaconFactory
#
# Notes:
# - Strips Solidity metadata (CBOR) tail beginning at the "a2646970667358" marker before disassembly.
# - If no DELEGATECALL is found in reachable code but exists in the full bytecode, a note is printed.

set -euo pipefail

SHOW=0

# Parse optional --show
if [[ "${1:-}" == "--show" ]]; then
  if [[ $# -lt 3 ]]; then
    echo "Usage: $0 [--show N] <solidity-path> <contract-name>" >&2
    exit 1
  fi
  SHOW="$2"
  shift 2
fi

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 [--show N] <solidity-path> <contract-name>" >&2
  exit 1
fi

SOL_PATH="$1"
CONTRACT_NAME="$2"
TARGET="${SOL_PATH}:${CONTRACT_NAME}"

command -v forge >/dev/null || { echo "missing: forge" >&2; exit 1; }
command -v cast  >/dev/null || { echo "missing: cast"  >&2; exit 1; }

# Get deployed (runtime) bytecode, strip surrounding quotes if present.
BYTECODE="$(forge inspect "$TARGET" deployedBytecode | sed -e 's/^"//' -e 's/"$//')"

# Strip Solidity metadata tail starting at the CBOR/ipfs marker "a2646970667358" (case-insensitive).
# Use awk (POSIX + tolower) to find marker position and cut.
STRIPPED_BYTECODE="$(
  printf '%s' "$BYTECODE" | awk '{
    lc=$0
    # lowercase for robust search (BSD awk supports tolower)
    for (i=1;i<=length($0);i++) { c=substr($0,i,1); lc=(lc==""?tolower(c):lc) }
  }' 2>/dev/null
)"

# The above trick isn’t great on BSD awk; use a simpler two-pass:
# 1) Make a lowercase copy
lc="$(printf '%s\n' "$BYTECODE" | tr 'A-F' 'a-f')"
# 2) Find marker index (1-based); if present, cut the original string to keep case
marker="a2646970667358"
pos=0
case "$lc" in
  *$marker*)
    # Use awk substr with recorded index
    pos="$(awk -v s="$lc" -v m="$marker" 'BEGIN{
      # find 1-based index of m in s
      for(i=1;i<=length(s)-length(m)+1;i++){
        if(substr(s,i,length(m))==m){print i; exit}
      }
      print 0
    }')"
    ;;
esac

if [[ "$pos" -gt 0 ]]; then
  # Keep everything before marker (pos-1)
  STRIPPED_BYTECODE="$(awk -v s="$BYTECODE" -v p="$pos" 'BEGIN{
    if(p>1) print substr(s,1,p-1); else print ""
  }')"
else
  STRIPPED_BYTECODE="$BYTECODE"
fi

# Disassemble full and stripped once each.
tmp_full="$(mktemp)"; tmp_stripped="$(mktemp)"
trap 'rm -f "$tmp_full" "$tmp_stripped"' EXIT

cast disassemble <<<"$BYTECODE" > "$tmp_full"
cast disassemble <<<"$STRIPPED_BYTECODE" > "$tmp_stripped"

echo "cast disassemble (reachable code; metadata stripped):"
if [[ "$SHOW" -eq 0 ]]; then
  grep -n -i '\<DELEGATECALL\>' "$tmp_stripped" || true
else
  MATCHES=$(grep -n -i '\<DELEGATECALL\>' "$tmp_stripped" | cut -d: -f1 || true)
  i=1
  for line in $MATCHES; do
    echo "---- match $i ----"
    start=$(( line - SHOW ))
    if [[ $start -lt 1 ]]; then start=1; fi
    end=$(( line + SHOW ))
    sed -n "${start},${end}p" "$tmp_stripped"
    i=$(( i + 1 ))
  done
fi

REACHABLE_COUNT="$(grep -i -c '\<DELEGATECALL\>' "$tmp_stripped" || true)"
echo "DELEGATECALL count (reachable): $REACHABLE_COUNT"

# If none in reachable code, but present in full (likely only in metadata), print a helpful note.
if [[ "$REACHABLE_COUNT" -eq 0 ]]; then
  FULL_COUNT="$(grep -i -c '\<DELEGATECALL\>' "$tmp_full" || true)"
  if [[ "$FULL_COUNT" -gt 0 ]]; then
    echo "Note: DELEGATECALL appears only in the metadata tail (unreachable)."
  fi
fi
