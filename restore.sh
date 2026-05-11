#!/usr/bin/env bash
# restore.sh — Reverse a quarantine.sh move using moves-{run_id}.jsonl.
# See docs/archive-quarantine-design.md §6. Dry-run is the default.

set -euo pipefail

VERSION="0.1.0"

# ---------- defaults ----------
MOVES=""
ALL=false
MATCH=""
EXECUTE=false
VERIFY_SHA=true
LOG_DIR="./logs"

# ---------- helpers ----------
err() { echo "ERROR: $*" >&2; }
info() { echo "$*" >&2; }
die() { err "$*"; exit 1; }

print_help() {
  cat <<EOF
restore.sh ${VERSION} — Replay a quarantine.sh move log in reverse.

USAGE
  restore.sh --moves PATH [--all | --match PATTERN] [--execute] [options]

REQUIRED
  --moves PATH         Path to moves-{run_id}.jsonl produced by quarantine.sh

SELECTION (one is required for --execute)
  --all                Restore every move in the log
  --match PATTERN      Restore only entries whose src_rel matches the shell glob.
                       Examples:
                         --match 'icjia/pdf/Bulletins/Repeat Offenders in Illinois.pdf'
                         --match 'icjia/pdf/Bulletins/*'
                         --match '*Recidivism*'
                       Note: glob is applied with bash extglob; quote it.

OPTIONS
  --execute            Actually move files back. Without this flag the script
                       only reports what would be restored.
  --no-verify-sha      Skip the SHA-256 verification before restoring.
                       (Default: verify; defends against tampering or corruption.)
  --log-dir PATH       Where to write the restore log. Default: ./logs
  -h, --help           Show this help.

EXAMPLES
  # Preview what would be restored
  restore.sh --moves logs/moves-2026-05-11T14-25-00Z.jsonl --all

  # Restore everything
  restore.sh --moves logs/moves-2026-05-11T14-25-00Z.jsonl --all --execute

  # Restore one file by exact path
  restore.sh --moves logs/moves-...jsonl \\
    --match 'icjia/pdf/Bulletins/Repeat Offenders in Illinois.pdf' --execute

  # Restore a directory's worth of files
  restore.sh --moves logs/moves-...jsonl --match 'icjia/pdf/Bulletins/*' --execute

  # Fuzzy filename search
  restore.sh --moves logs/moves-...jsonl --match '*Recidivism*' --execute
EOF
}

# ---------- argument parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --moves) MOVES="$2"; shift 2 ;;
    --all) ALL=true; shift ;;
    --match) MATCH="$2"; shift 2 ;;
    --execute) EXECUTE=true; shift ;;
    --dry-run) shift ;;  # accepted for compatibility; dry-run is default
    --verify-sha) VERIFY_SHA=true; shift ;;
    --no-verify-sha) VERIFY_SHA=false; shift ;;
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    -h|--help) print_help; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

[[ -z "$MOVES" ]] && die "--moves is required"
[[ -f "$MOVES" ]] || die "moves file not found: $MOVES"

if [[ "$ALL" == false && -z "$MATCH" ]]; then
  die "must specify either --all or --match PATTERN"
fi
if [[ "$ALL" == true && -n "$MATCH" ]]; then
  die "--all and --match are mutually exclusive"
fi

MODE="dry-run"
[[ "$EXECUTE" == true ]] && MODE="execute"

RUN_ID="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
mkdir -p "$LOG_DIR"
RESTORES_JSONL="${LOG_DIR}/restores-${RUN_ID}.jsonl"
ERRORS_LOG="${LOG_DIR}/restore-errors-${RUN_ID}.log"

# ---------- preflight ----------
info "================================================================"
info "restore.sh ${VERSION}  (run_id=${RUN_ID}, mode=${MODE})"
info "================================================================"
info ""

for tool in jq stat sha256sum mv; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

TOTAL_IN_LOG="$(wc -l < "$MOVES")"
info "PREFLIGHT"
info "  moves log:     $MOVES ($TOTAL_IN_LOG entries)"
info "  selection:     $([ "$ALL" == true ] && echo "ALL ($TOTAL_IN_LOG)" || echo "match: $MATCH")"
info "  verify SHA:    $VERIFY_SHA"
info ""

# ---------- filter entries ----------
info "Filtering entries..."

# Convert shell glob to regex via sed (robust against bash parameter-expansion edge cases).
# Escape regex metacharacters first, then translate glob wildcards * and ?.
glob_to_regex() {
  printf '%s' "$1" \
    | sed -e 's/[][\\^$.|()+{}]/\\&/g' \
          -e 's/?/./g' \
          -e 's/\*/.*/g'
}

# Stream matching entries into a temp file
FILTERED="$(mktemp)"
trap 'rm -f "$FILTERED"' EXIT

if [[ "$ALL" == true ]]; then
  jq -c '.' "$MOVES" > "$FILTERED"
else
  REGEX="^$(glob_to_regex "$MATCH")\$"
  # Pass regex via --arg so jq treats it as a literal string (no JSON escaping
  # needed; \. in regex stays as a one-char escape, not as a JSON escape).
  jq -c --arg pattern "$REGEX" 'select(.src_rel | test($pattern))' "$MOVES" > "$FILTERED"
fi

MATCHED="$(wc -l < "$FILTERED")"
info "  matched: $MATCHED entries"
if (( MATCHED == 0 )); then
  die "no entries matched the filter"
fi

# Show first few matches
info ""
info "First 5 entries to restore:"
head -5 "$FILTERED" | jq -r '"  • " + .src_rel'
if (( MATCHED > 5 )); then
  info "  … and $((MATCHED - 5)) more"
fi
info ""

# ---------- restore loop ----------
if [[ "$EXECUTE" != true ]]; then
  info "DRY RUN — re-run with --execute to actually restore."
  exit 0
fi

info "EXECUTING restores (writing $RESTORES_JSONL)..."
: > "$RESTORES_JSONL"

RESTORED=0
SKIPPED_MISSING_QUARANTINE=0
SKIPPED_SHA_MISMATCH=0
SKIPPED_SRC_EXISTS=0
ERRORS=0
STARTED=$(date +%s)

while IFS= read -r line; do
  src_rel="$(echo "$line" | jq -r '.src_rel')"
  src_abs="$(echo "$line" | jq -r '.src_abs')"
  dst_abs="$(echo "$line" | jq -r '.dst_abs')"
  size_expected="$(echo "$line" | jq -r '.size')"
  sha_expected="$(echo "$line" | jq -r '.sha256')"

  # quarantine file present?
  if [[ ! -f "$dst_abs" ]]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) not_in_quarantine $src_rel" >> "$ERRORS_LOG"
    SKIPPED_MISSING_QUARANTINE=$((SKIPPED_MISSING_QUARANTINE + 1))
    continue
  fi

  # SHA verify
  if [[ "$VERIFY_SHA" == true ]]; then
    sha_actual="$(sha256sum "$dst_abs" | awk '{print $1}')"
    if [[ "$sha_actual" != "$sha_expected" ]]; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) sha_mismatch $src_rel expected=$sha_expected actual=$sha_actual" >> "$ERRORS_LOG"
      SKIPPED_SHA_MISMATCH=$((SKIPPED_SHA_MISMATCH + 1))
      continue
    fi
  fi

  # source already exists?
  if [[ -e "$src_abs" ]]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) src_exists $src_rel" >> "$ERRORS_LOG"
    SKIPPED_SRC_EXISTS=$((SKIPPED_SRC_EXISTS + 1))
    continue
  fi

  # do the restore
  src_parent="$(dirname "$src_abs")"
  mkdir -p "$src_parent"
  if ! mv "$dst_abs" "$src_abs" 2>>"$ERRORS_LOG"; then
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # log restore
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg src_rel "$src_rel" \
    --arg src_abs "$src_abs" \
    --arg dst_abs "$dst_abs" \
    --argjson size "$size_expected" \
    --arg sha256 "$sha_expected" \
    --arg run_id "$RUN_ID" \
    '{ts:$ts,action:"restore",src_rel:$src_rel,restored_to:$src_abs,from:$dst_abs,size:$size,sha256:$sha256,run_id:$run_id}' \
    >> "$RESTORES_JSONL"

  RESTORED=$((RESTORED + 1))
done < "$FILTERED"

ELAPSED=$(( $(date +%s) - STARTED ))

# ---------- post-flight ----------
info ""
info "================================================================"
info "POST-FLIGHT SUMMARY"
info "================================================================"
info "  Restored:                       $RESTORED"
info "  Skipped (not in quarantine):    $SKIPPED_MISSING_QUARANTINE"
info "  Skipped (SHA mismatch):         $SKIPPED_SHA_MISMATCH"
info "  Skipped (src already exists):   $SKIPPED_SRC_EXISTS"
info "  Errors:                         $ERRORS  $([ "$ERRORS" -gt 0 ] && echo "(see ${ERRORS_LOG})")"
info "  Elapsed:                        ${ELAPSED}s"
info "  Restore log:                    $RESTORES_JSONL"
info ""
info "Done."
