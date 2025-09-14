#!/usr/bin/env bash
# Delegatecall scanner — stable macOS Bash 3.2 version.
# - No `set -e` or `pipefail` (so one bad file can't kill the whole run)
# - Loops in current shell (no subshell var scope issues)
# - Resilient to empty/odd JSON fields
# - Prints a summary every time
#
# Flags:
#   --all          : show all artifacts, even without any DELEGATECALL
#   --only-deleg   : show only artifacts that contain DELEGATECALL (default)
#   --strict       : only print risk=LIKELY-REACHABLE (implies --only-deleg)
#   --debug        : verbose trace to stderr
#
# Notes:
#   - Strips Solidity metadata tail (CBOR) beginning at marker "a2646970667358"
#     before disassembly, to avoid false positives in unreachable metadata.
#   - Adds META_ONLY column (yes/no): DELEGATECALL present only in metadata tail.

# -------------------- args --------------------
ART_DIR="out"
MODE="only-deleg"  # default behavior
STRICT=""
DEBUG=""

for arg in "$@"; do
  case "$arg" in
    --all) MODE="all" ;;
    --only-deleg) MODE="only-deleg" ;;
    --strict) STRICT=1; MODE="only-deleg" ;;
    --debug) DEBUG=1 ;;
    *) ART_DIR="$arg" ;;
  esac
done

dbg() { [ -n "$DEBUG" ] && printf '[DBG] %s\n' "$*" >&2; }

# -------------------- deps --------------------
need() { command -v "$1" >/dev/null 2>&1; }
if ! need jq; then echo "Error: jq not found (brew install jq)" >&2; exit 127; fi
if ! need cast; then echo "Error: foundry 'cast' not found. Install foundry (foundryup)." >&2; exit 127; fi
USE_RG=""
if need rg; then USE_RG="1"; fi

# -------------------- banners --------------------
echo "==> Scanning artifacts in: ${ART_DIR}"
echo
echo "RUNTIME_F4 CREATION_F4 META_ONLY ABI_FWD ABI_FALL SRC_DELEG RISK_HINT SOURCE_PATH CONTRACT"
echo "---------- ---------- --------- ------ ------- -------- ---------- ---------- ----------------"

# -------------------- helpers --------------------

lower_hex () { tr 'A-F' 'a-f'; }

strip_metadata_hex () {
  # stdin: hex string (with or without 0x). stdout: hex with metadata tail removed.
  # Implementation: find marker index of "a2646970667358" (ipfs/CBOR header) and cut before it.
  local hex lc marker="a2646970667358" pos
  hex="$(cat)"
  # remove leading 0x and quotes if present
  hex="$(printf '%s' "$hex" | sed -e 's/^"//' -e 's/"$//' -e 's/^0x//')"
  lc="$(printf '%s' "$hex" | lower_hex)"
  case "$lc" in
    *$marker*)
      pos="$(awk -v s="$lc" -v m="$marker" 'BEGIN{
        for(i=1;i<=length(s)-length(m)+1;i++){ if(substr(s,i,length(m))==m){ print i; exit } }
        print 0
      }')"
      if [ "$pos" -gt 0 ]; then
        awk -v s="$hex" -v p="$pos" 'BEGIN{ if(p>1) print substr(s,1,p-1); else print "" }'
        return 0
      fi
      ;;
  esac
  printf '%s' "$hex"
}

disasm_hex () {
  # stdin: hex string (with or without 0x) -> disassembly (metadata STRIPPED)
  local out
  out="$( { strip_metadata_hex | cast disassemble 2>/dev/null; } || true )"
  printf '%s' "$out"
}

disasm_hex_full () {
  # stdin: hex string (with or without 0x) -> disassembly (FULL, metadata INCLUDED)
  local hex out
  hex="$(cat)"
  hex="$(printf '%s' "$hex" | sed -e 's/^"//' -e 's/"$//' )"
  out="$( { printf '%s' "$hex" | cast disassemble 2>/dev/null; } || true )"
  printf '%s' "$out"
}

has_delegate_in_hex () {
  # stdin: hex -> returns 0 if STRIPPED disassembly contains DELEGATECALL
  local out
  out="$(disasm_hex)"
  [ -n "$out" ] && printf '%s\n' "$out" | grep -qi 'DELEGATECALL'
}

has_delegate_in_hex_full () {
  # stdin: hex -> returns 0 if FULL disassembly contains DELEGATECALL (incl. metadata)
  local out
  out="$(disasm_hex_full)"
  [ -n "$out" ] && printf '%s\n' "$out" | grep -qi 'DELEGATECALL'
}

has_delegate_runtime () {
  local jf="$1" hex
  hex="$(jq -r '.deployedBytecode?.object // .deployedBytecode // ""' "$jf" 2>/dev/null)"
  [ -z "$hex" -o "$hex" = "0x" ] && return 1
  printf '%s' "$hex" | has_delegate_in_hex
}

has_delegate_runtime_full () {
  local jf="$1" hex
  hex="$(jq -r '.deployedBytecode?.object // .deployedBytecode // ""' "$jf" 2>/dev/null)"
  [ -z "$hex" -o "$hex" = "0x" ] && return 1
  printf '%s' "$hex" | has_delegate_in_hex_full
}

has_delegate_creation () {
  local jf="$1" hex
  hex="$(jq -r '.bytecode?.object // .bytecode // ""' "$jf" 2>/dev/null)"
  [ -z "$hex" -o "$hex" = "0x" ] && return 1
  printf '%s' "$hex" | has_delegate_in_hex
}

has_delegate_creation_full () {
  local jf="$1" hex
  hex="$(jq -r '.bytecode?.object // .bytecode // ""' "$jf" 2>/dev/null)"
  [ -z "$hex" -o "$hex" = "0x" ] && return 1
  printf '%s' "$hex" | has_delegate_in_hex_full
}

primary_source_for_artifact () {
  local jf="$1"
  jq -r '
    (.contractName // "UNKNOWN") as $cn
    | if .metadata.settings.compilationTarget then
        (.metadata.settings.compilationTarget | to_entries[]? | select(.value==$cn) | .key)
      elif .sourceName then .sourceName
      elif .sourcePath then .sourcePath
      else
        (.metadata.sources // {} | to_entries | map(.key) | .[0] // empty)
      end
  ' "$jf" 2>/dev/null
}

contract_name_for_artifact () {
  local jf="$1"
  jq -r '.contractName // ((.metadata.settings.compilationTarget // {} | to_entries[0]?.value) // "UNKNOWN")' "$jf" 2>/dev/null
}

abi_marks () {
  # prints: "", "FWD", "FALL", or "FWD,FALL"
  local jf="$1" saw_fwd=0 saw_fall=0 enc obj typ name mut inputs
  while IFS= read -r enc; do
    [ -z "$enc" ] && continue
    obj="$(printf '%s' "$enc" | base64 --decode 2>/dev/null || true)"
    [ -z "$obj" ] && { dbg "empty/undecodable ABI entry: $jf"; continue; }

    typ="$(printf '%s' "$obj" | jq -r '.type // ""' 2>/dev/null || echo "")"
    name="$(printf '%s' "$obj" | jq -r '.name // ""' 2>/dev/null || echo "")"
    mut="$(printf '%s' "$obj" | jq -r '.stateMutability // ""' 2>/dev/null || echo "")"
    inputs="$(printf '%s' "$obj" | jq -r '(.inputs // []) | map(.type // "") | join(",")' 2>/dev/null || echo "")"

    dbg "ABI typ=$typ name=$name mut=$mut inputs=$inputs"

    if [ "$typ" = "fallback" ] || [ "$typ" = "receive" ]; then
      saw_fall=1
      continue
    fi
    [ "$typ" = "function" ] || continue
    [ "$mut" = "pure" -o "$mut" = "view" ] && continue

    case "$name" in
      upgrade|upgradeTo|upgradeToAndCall|upgradeImplementation|upgradeImpl|setImplementation|setCode|setCodeAndCall|execute|forward|delegateCall|delegateExecute|routerExecute|multicallDelegate|impl|implementation)
        saw_fwd=1 ;;
      *) : ;;
    esac
    if printf '%s' "$inputs" | grep -q 'address' && printf '%s' "$inputs" | grep -q 'bytes'; then
      saw_fwd=1
    fi
    case "$inputs" in
      address|bytes|"bytes,bytes") saw_fwd=1 ;;
    esac
  done < <(jq -r '.abi // [] | .[]? | @base64' "$jf" 2>/dev/null)

  if [ $saw_fwd -eq 1 ] && [ $saw_fall -eq 1 ]; then
    echo "FWD,FALL"
  elif [ $saw_fwd -eq 1 ]; then
    echo "FWD"
  elif [ $saw_fall -eq 1 ]; then
    echo "FALL"
  else
    echo ""
  fi
}

src_has_delegate_patterns () {
  # crude source hint only (not authoritative)
  local src="$1"
  [ -z "$src" ] && return 1
  if [ -f "$src" ]; then
    if [ -n "$USE_RG" ]; then
      rg -n --no-heading -e '\.delegatecall\s*\(' -e 'functionDelegateCall\s*\(' -e 'assembly\s*\{[^}]*delegatecall' "$src" >/dev/null 2>&1
    else
      grep -nE '\.delegatecall\s*\(|functionDelegateCall\s*\(|assembly\s*\{[^}]*delegatecall' "$src" >/dev/null 2>&1
    fi
  else
    local base; base="$(basename "$src")"
    if [ -n "$USE_RG" ]; then
      rg -n --no-heading -e '\.delegatecall\s*\(' -e 'functionDelegateCall\s*\(' -e 'assembly\s*\{[^}]*delegatecall' --glob "**/$base" >/dev/null 2>&1
    else
      grep -R -nE '\.delegatecall\s*\(|functionDelegateCall\s*\(|assembly\s*\{[^}]*delegatecall' . 2>/dev/null | grep "/$base:" >/dev/null 2>&1
    fi
  fi
}

list_delegate_imports_csv () {
  local jf="$1" out="" first=1 sp
  while IFS= read -r sp; do
    case "$sp" in
      *.sol)
        if src_has_delegate_patterns "$sp"; then
          if [ $first -eq 1 ]; then out="$sp"; first=0; else out="$out,$sp"; fi
        fi
      ;;
    esac
  done < <(jq -r '.metadata.sources // {} | keys[]?' "$jf" 2>/dev/null)
  printf '%s' "$out"
}

# -------------------- collect file list --------------------
files=()
while IFS= read -r -d '' f; do files[${#files[@]}]="$f"; done < <(find "$ART_DIR" -type f -name '*.json' -print0 2>/dev/null)

scanned=0
with_deployed=0
printed=0
found_any=""

# -------------------- main loop --------------------
for jf in "${files[@]}"; do
  scanned=$((scanned+1))

  if ! jq -e '.deployedBytecode? // .deployedBytecode?.object? // empty' "$jf" >/dev/null 2>&1; then
    dbg "skip(no deployedBytecode): $jf"
    continue
  fi
  with_deployed=$((with_deployed+1))

  # disassembly-based checks (STRIPPED and FULL)
  runtime_f4="no"; creation_f4="no"; meta_only="no"

  if has_delegate_runtime "$jf"; then runtime_f4="yes"; fi
  if has_delegate_creation "$jf"; then creation_f4="yes"; fi

  # if no hits in stripped but present in full → metadata-only
  rt_full="no"; cr_full="no"
  if has_delegate_runtime_full "$jf"; then rt_full="yes"; fi
  if has_delegate_creation_full "$jf"; then cr_full="yes"; fi
  if [ "$runtime_f4" = "no" ] && [ "$rt_full" = "yes" ]; then meta_only="yes"; fi
  if [ "$creation_f4" = "no" ] && [ "$cr_full" = "yes" ]; then meta_only="yes"; fi

  # filtering
  if [ "$MODE" = "only-deleg" ] && [ "$runtime_f4" != "yes" ] && [ "$creation_f4" != "yes" ]; then
    dbg "skip(no delegatecall in stripped creation/runtime): $jf"
    continue
  fi

  src="$(primary_source_for_artifact "$jf")"
  cn="$(contract_name_for_artifact "$jf")"

  marks="$(abi_marks "$jf")"
  abi_fwd="no"; abi_fall="no"
  case "$marks" in
    *FWD*)  abi_fwd="yes" ;;
  esac
  case "$marks" in
    *FALL*) abi_fall="yes" ;;
  esac

  src_hit="no"
  if src_has_delegate_patterns "$src"; then src_hit="yes"; fi

  imports="$(list_delegate_imports_csv "$jf")"

  # risk hint (based on STRIPPED results)
  risk="LOW"
  if [ "$runtime_f4" = "yes" ] && { [ "$abi_fwd" = "yes" ] || [ "$abi_fall" = "yes" ]; } && { [ "$src_hit" = "yes" ] || [ -n "$imports" ]; }; then
    risk="LIKELY-REACHABLE"
  elif [ "$runtime_f4" = "yes" ] && { [ "$abi_fwd" = "yes" ] || [ "$src_hit" = "yes" ] || [ -n "$imports" ]; }; then
    risk="MEDIUM"
  else
    risk="LOW"
  fi

  if [ -n "$STRICT" ] && [ "$risk" != "LIKELY-REACHABLE" ]; then
    dbg "skip(strict mode): $jf risk=$risk"
    continue
  fi

  found_any="yes"
  printed=$((printed+1))

  printf "%-10s %-10s %-9s %-6s %-7s %-8s %-16s %-10s %s\n" \
    "$runtime_f4" "$creation_f4" "$meta_only" "$abi_fwd" "$abi_fall" "$src_hit" "$risk" "${src:-<unknown>}" "${cn:-UNKNOWN}"

  if [ -n "$imports" ]; then
    echo "FROM_IMPORTS[${imports}]"
  fi
done

# -------------------- footer --------------------
if [ -z "$found_any" ] && [ "$MODE" = "only-deleg" ]; then
  echo
  echo "No delegatecall found in creation/runtime."
fi

echo
echo "Summary: scanned=$scanned artifacts, with_deployed=$with_deployed, printed=$printed"
echo
echo "Legend:"
echo "  RUNTIME_F4 : runtime contains a real DELEGATECALL (metadata stripped)"
echo "  CREATION_F4: creation contains a DELEGATECALL (metadata stripped)"
echo "  META_ONLY  : DELEGATECALL exists only in metadata tail (unreachable)"
echo "  ABI_FWD    : ABI exposes forward/upgrader-like fn (attacker-steerable)"
echo "  ABI_FALL   : ABI has fallback/receive"
echo "  SRC_DELEG  : primary source contains delegatecall patterns"
echo "  RISK_HINT  : LIKELY-REACHABLE > MEDIUM > LOW (combination of the above)"
