#!/usr/bin/env bash
# quarantine.sh — Move non-referenced files from web root to a sibling quarantine dir.
# See docs/archive-quarantine-design.md §5. Dry-run is the default.

set -euo pipefail

VERSION="0.1.0"

# ---------- defaults ----------
KEEP_JSON=""
WEB_ROOT=""
QUARANTINE=""
DRONE_DIR="icjia/drone2026"
EXTENSIONS="pdf,xlsx,xls,docx,doc,pptx,ppt,rtf,csv"
EXECUTE=false
LIMIT=0
LOG_DIR="./logs"
CLEAN_EMPTY_DIRS=false
LOCKFILE=""

# ---------- helpers ----------
err() { echo "ERROR: $*" >&2; }
info() { echo "$*" >&2; }
die() { err "$*"; exit 1; }

print_help() {
  cat <<EOF
quarantine.sh ${VERSION} — Move non-publication files to a sibling quarantine directory.

USAGE
  quarantine.sh --keep PATH --web-root PATH --quarantine PATH [options]

REQUIRED
  --keep PATH            Path to keep.json produced by build-keep-list.js
  --web-root PATH        Filesystem path that maps to the /files/ URL prefix
                         (e.g. /home/forge/archive.icjia-api.cloud/root/files)
  --quarantine PATH      Destination root for moved files (must be a sibling on
                         the same filesystem as --web-root for atomic mv)

OPTIONS
  --drone-dir PATH       Path relative to --web-root to preserve recursively.
                         Accepts nested paths. Default: icjia/drone2026
  --extensions LIST      Comma-separated extensions to consider for moving.
                         Default: pdf,xlsx,xls,docx,doc,pptx,ppt,rtf,csv
  --execute              Actually move files. Without this flag the script
                         only classifies and reports (dry-run is the default).
  --limit N              Cap the move set at N files (for smoke testing).
  --log-dir PATH         Where to write manifest/moves/error logs.
                         Default: ./logs
  --clean-empty-dirs     After moves, remove empty directories left behind
                         in --web-root. Default: off.
  --lockfile PATH        Lockfile location. Default: \$LOG_DIR/quarantine.lock
  -h, --help             Show this help.

EXAMPLES
  # Dry run (default — classify & report, no moves)
  quarantine.sh --keep keep.json \\
    --web-root /home/forge/archive.icjia-api.cloud/root/files \\
    --quarantine /home/forge/archive.icjia-api.cloud/root/files-quarantine

  # Smoke-test execution: move only first 10 files
  quarantine.sh --keep keep.json --web-root /... --quarantine /... \\
    --limit 10 --execute

  # Full execution
  quarantine.sh --keep keep.json --web-root /... --quarantine /... --execute
EOF
}

# ---------- argument parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP_JSON="$2"; shift 2 ;;
    --web-root) WEB_ROOT="$2"; shift 2 ;;
    --quarantine) QUARANTINE="$2"; shift 2 ;;
    --drone-dir) DRONE_DIR="$2"; shift 2 ;;
    --extensions) EXTENSIONS="$2"; shift 2 ;;
    --execute) EXECUTE=true; shift ;;
    --dry-run) shift ;;  # accepted for compatibility; dry-run is default
    --limit) LIMIT="$2"; shift 2 ;;
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    --clean-empty-dirs) CLEAN_EMPTY_DIRS=true; shift ;;
    --lockfile) LOCKFILE="$2"; shift 2 ;;
    -h|--help) print_help; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

[[ -z "$KEEP_JSON" ]] && die "--keep is required"
[[ -z "$WEB_ROOT" ]] && die "--web-root is required"
[[ -z "$QUARANTINE" ]] && die "--quarantine is required"

# Normalize paths (strip trailing slashes)
WEB_ROOT="${WEB_ROOT%/}"
QUARANTINE="${QUARANTINE%/}"
DRONE_DIR="${DRONE_DIR%/}"

MODE="dry-run"
[[ "$EXECUTE" == true ]] && MODE="execute"

RUN_ID="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
mkdir -p "$LOG_DIR"
MANIFEST_JSON="${LOG_DIR}/manifest-${RUN_ID}.json"
MANIFEST_TXT="${LOG_DIR}/manifest-${RUN_ID}.txt"
MOVES_JSONL="${LOG_DIR}/moves-${RUN_ID}.jsonl"
ERRORS_LOG="${LOG_DIR}/errors-${RUN_ID}.log"
[[ -z "$LOCKFILE" ]] && LOCKFILE="${LOG_DIR}/quarantine.lock"

# ---------- preflight ----------
info "================================================================"
info "quarantine.sh ${VERSION}  (run_id=${RUN_ID}, mode=${MODE})"
info "================================================================"
info ""
info "PREFLIGHT"

# tool availability
for tool in jq find mv stat sha256sum realpath flock; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    die "missing required tool: $tool"
  fi
done
info "  tools: jq, find, mv, stat, sha256sum, realpath, flock all present"

# bash version
if (( BASH_VERSINFO[0] < 4 )); then
  die "bash >= 4 required (have ${BASH_VERSION})"
fi
info "  bash version: ${BASH_VERSION}"

# keep.json validation
[[ -f "$KEEP_JSON" ]] || die "keep.json not found: $KEEP_JSON"
KEEP_COUNT="$(jq '.keep | length' "$KEEP_JSON" 2>/dev/null)" || die "keep.json is not valid JSON: $KEEP_JSON"
[[ "$KEEP_COUNT" -gt 0 ]] || die "keep.json has zero entries — refusing to proceed (would move everything)"
info "  keep.json: $KEEP_JSON ($KEEP_COUNT entries)"

# web-root validation
[[ -d "$WEB_ROOT" ]] || die "--web-root is not a directory: $WEB_ROOT"
[[ -r "$WEB_ROOT" ]] || die "--web-root is not readable: $WEB_ROOT"
[[ -w "$WEB_ROOT" ]] || die "--web-root is not writable (need write to mv files out): $WEB_ROOT"
info "  web-root: $WEB_ROOT (readable & writable)"

# quarantine parent validation
QUARANTINE_PARENT="$(dirname "$QUARANTINE")"
[[ -d "$QUARANTINE_PARENT" ]] || die "--quarantine parent does not exist: $QUARANTINE_PARENT"
[[ -w "$QUARANTINE_PARENT" ]] || die "--quarantine parent is not writable: $QUARANTINE_PARENT"
info "  quarantine target: $QUARANTINE (parent writable)"

# same filesystem check
WR_FS="$(stat -c %d "$WEB_ROOT")"
QP_FS="$(stat -c %d "$QUARANTINE_PARENT")"
if [[ "$WR_FS" != "$QP_FS" ]]; then
  info "  ⚠️  WARNING: --web-root and --quarantine are on DIFFERENT filesystems."
  info "      mv operations will fall back to copy+delete (slow, non-atomic, may leave intermediate state)."
else
  info "  filesystem: same device (mv will be atomic)"
fi

# drone-dir check
if [[ -d "$WEB_ROOT/$DRONE_DIR" ]]; then
  DRONE_FILE_COUNT="$(find "$WEB_ROOT/$DRONE_DIR" -type f | wc -l)"
  info "  drone-dir: $DRONE_DIR ($DRONE_FILE_COUNT files; preserved)"
else
  info "  ⚠️  WARNING: drone-dir does not exist: $WEB_ROOT/$DRONE_DIR"
fi

# disk space check
FREE_KB="$(df -P "$QUARANTINE_PARENT" | tail -1 | awk '{print $4}')"
FREE_GB="$(awk "BEGIN{printf \"%.1f\", $FREE_KB/1024/1024}")"
info "  disk free at quarantine parent: ${FREE_GB} GB"

# lockfile
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  die "another quarantine.sh is already running (lockfile: $LOCKFILE)"
fi
info "  lock acquired: $LOCKFILE"

info ""

# ---------- load keep set ----------
info "Loading keep set..."
declare -A KEEP_SET
while IFS= read -r path; do
  KEEP_SET["$path"]=1
done < <(jq -r '.keep[].path' "$KEEP_JSON")
info "  ${#KEEP_SET[@]} unique paths in keep set"

# extension set (lowercase)
declare -A EXT_SET
IFS=',' read -ra _exts <<< "$EXTENSIONS"
for e in "${_exts[@]}"; do
  EXT_SET["${e,,}"]=1
done
info "  extensions in scope: ${EXTENSIONS}"
info ""

# ---------- walk & classify ----------
info "Scanning $WEB_ROOT ..."
declare -a MOVE_LIST=()
declare -a KEEP_PUB_SAMPLES=()
declare -a KEEP_DRONE_SAMPLES=()
declare -a SKIP_EXT_SAMPLES=()

SCANNED=0
COUNT_KEEP_PUB=0
COUNT_KEEP_DRONE=0
COUNT_SKIP_EXT=0
COUNT_MOVE=0
MOVE_TOTAL_BYTES=0

while IFS= read -r -d '' file; do
  SCANNED=$((SCANNED + 1))
  rel="${file#$WEB_ROOT/}"

  # 1. preserved dir
  if [[ "$rel" == "$DRONE_DIR/"* || "$rel" == "$DRONE_DIR" ]]; then
    COUNT_KEEP_DRONE=$((COUNT_KEEP_DRONE + 1))
    (( ${#KEEP_DRONE_SAMPLES[@]} < 5 )) && KEEP_DRONE_SAMPLES+=("$rel")
    continue
  fi

  # 2. extension filter
  basename="${file##*/}"
  if [[ "$basename" != *.* ]]; then
    # no extension on the filename itself
    COUNT_SKIP_EXT=$((COUNT_SKIP_EXT + 1))
    (( ${#SKIP_EXT_SAMPLES[@]} < 5 )) && SKIP_EXT_SAMPLES+=("$rel")
    continue
  fi
  ext_lc="${basename##*.}"
  ext_lc="${ext_lc,,}"
  if [[ -z "${EXT_SET[$ext_lc]:-}" ]]; then
    COUNT_SKIP_EXT=$((COUNT_SKIP_EXT + 1))
    (( ${#SKIP_EXT_SAMPLES[@]} < 5 )) && SKIP_EXT_SAMPLES+=("$rel")
    continue
  fi

  # 3. in keep set
  if [[ -n "${KEEP_SET[$rel]:-}" ]]; then
    COUNT_KEEP_PUB=$((COUNT_KEEP_PUB + 1))
    (( ${#KEEP_PUB_SAMPLES[@]} < 5 )) && KEEP_PUB_SAMPLES+=("$rel")
    continue
  fi

  # 4. move
  COUNT_MOVE=$((COUNT_MOVE + 1))
  if (( LIMIT == 0 )) || (( COUNT_MOVE <= LIMIT )); then
    MOVE_LIST+=("$rel")
    sz="$(stat -c %s "$file" 2>/dev/null || echo 0)"
    MOVE_TOTAL_BYTES=$((MOVE_TOTAL_BYTES + sz))
  fi
done < <(find "$WEB_ROOT" -type f -print0)

# apply limit to actual move count for reporting
if (( LIMIT > 0 )) && (( COUNT_MOVE > LIMIT )); then
  info "  (limit ${LIMIT} applied; ${COUNT_MOVE} total candidates, ${#MOVE_LIST[@]} selected for move)"
  COUNT_MOVE_ELIGIBLE="$COUNT_MOVE"
  COUNT_MOVE="${#MOVE_LIST[@]}"
else
  COUNT_MOVE_ELIGIBLE="$COUNT_MOVE"
fi

# keep set entries not on disk
declare -a MISSING_FROM_DISK=()
for kpath in "${!KEEP_SET[@]}"; do
  if [[ ! -f "$WEB_ROOT/$kpath" ]]; then
    MISSING_FROM_DISK+=("$kpath")
  fi
done

MOVE_TOTAL_MB="$(awk "BEGIN{printf \"%.1f\", $MOVE_TOTAL_BYTES/1024/1024}")"

info "  scanned:                ${SCANNED} files"
info "  keep (publication):     ${COUNT_KEEP_PUB}"
info "  keep (drone-dir):       ${COUNT_KEEP_DRONE}"
info "  skip (other extension): ${COUNT_SKIP_EXT}"
info "  → MOVE candidates:      ${COUNT_MOVE_ELIGIBLE}  (~${MOVE_TOTAL_MB} MB)"
if (( LIMIT > 0 )) && (( COUNT_MOVE_ELIGIBLE > LIMIT )); then
  info "  (limited to ${LIMIT} via --limit)"
fi
info "  keep entries missing on disk: ${#MISSING_FROM_DISK[@]}"
info ""

# ---------- write manifest ----------
info "Writing manifest..."

# Build samples JSON arrays
sample_array() {
  local -n arr=$1
  if (( ${#arr[@]} == 0 )); then echo '[]'; return; fi
  printf '%s\n' "${arr[@]}" | jq -R . | jq -s .
}
SAMPLES_MOVE_JSON="$(printf '%s\n' "${MOVE_LIST[@]:0:5}" | jq -R . | jq -s .)"
SAMPLES_KEEP_PUB_JSON="$(sample_array KEEP_PUB_SAMPLES)"
SAMPLES_KEEP_DRONE_JSON="$(sample_array KEEP_DRONE_SAMPLES)"
SAMPLES_SKIP_EXT_JSON="$(sample_array SKIP_EXT_SAMPLES)"

# extensions array
EXTS_JSON="$(echo "$EXTENSIONS" | tr ',' '\n' | jq -R . | jq -s .)"

# missing array
if (( ${#MISSING_FROM_DISK[@]} == 0 )); then
  MISSING_JSON='[]'
else
  MISSING_JSON="$(printf '%s\n' "${MISSING_FROM_DISK[@]}" | jq -R . | jq -s .)"
fi

jq -n \
  --arg run_id "$RUN_ID" \
  --arg mode "$MODE" \
  --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg web_root "$WEB_ROOT" \
  --arg quarantine_root "$QUARANTINE" \
  --arg keep_json "$KEEP_JSON" \
  --arg drone_dir "$DRONE_DIR" \
  --argjson extensions "$EXTS_JSON" \
  --argjson counts "{
    \"scanned\": $SCANNED,
    \"keep_publication\": $COUNT_KEEP_PUB,
    \"keep_drone_dir\": $COUNT_KEEP_DRONE,
    \"skip_other_extension\": $COUNT_SKIP_EXT,
    \"move\": $COUNT_MOVE,
    \"move_total_bytes\": $MOVE_TOTAL_BYTES
  }" \
  --argjson samples_move "$SAMPLES_MOVE_JSON" \
  --argjson samples_keep_pub "$SAMPLES_KEEP_PUB_JSON" \
  --argjson samples_keep_drone "$SAMPLES_KEEP_DRONE_JSON" \
  --argjson samples_skip_ext "$SAMPLES_SKIP_EXT_JSON" \
  --argjson keep_missing "$MISSING_JSON" \
  '{
    run_id: $run_id,
    mode: $mode,
    started_at: $started_at,
    web_root: $web_root,
    quarantine_root: $quarantine_root,
    keep_json: $keep_json,
    drone_dir: $drone_dir,
    extensions: $extensions,
    counts: $counts,
    samples: {
      move: $samples_move,
      keep_publication: $samples_keep_pub,
      keep_drone_dir: $samples_keep_drone,
      skip_other_extension: $samples_skip_ext
    },
    keep_missing_from_disk: $keep_missing
  }' > "$MANIFEST_JSON"

# human-readable summary
{
  echo "================================================================"
  echo "quarantine.sh manifest — run ${RUN_ID}  (mode: ${MODE})"
  echo "================================================================"
  echo
  echo "Web root:        $WEB_ROOT"
  echo "Quarantine:      $QUARANTINE"
  echo "Keep list:       $KEEP_JSON ($KEEP_COUNT entries)"
  echo "Preserved dir:   $DRONE_DIR"
  echo "Extensions:      $EXTENSIONS"
  echo
  echo "COUNTS"
  echo "  Files scanned:                ${SCANNED}"
  echo "  Keep (publication match):     ${COUNT_KEEP_PUB}"
  echo "  Keep (under preserved dir):   ${COUNT_KEEP_DRONE}"
  echo "  Skip (non-target extension):  ${COUNT_SKIP_EXT}"
  echo "  → MOVE:                       ${COUNT_MOVE_ELIGIBLE}  (~${MOVE_TOTAL_MB} MB)"
  if (( LIMIT > 0 )) && (( COUNT_MOVE_ELIGIBLE > LIMIT )); then
    echo "  (limited to ${LIMIT} via --limit; ${COUNT_MOVE} will actually be moved)"
  fi
  echo
  echo "SAMPLES"
  echo "  Would move (first 5):"
  for p in "${MOVE_LIST[@]:0:5}"; do echo "    • $p"; done
  if (( COUNT_KEEP_PUB > 0 )); then
    echo "  Kept by publication match (first 5):"
    for p in "${KEEP_PUB_SAMPLES[@]}"; do echo "    • $p"; done
  fi
  if (( COUNT_KEEP_DRONE > 0 )); then
    echo "  Kept by preserved-dir (first 5):"
    for p in "${KEEP_DRONE_SAMPLES[@]}"; do echo "    • $p"; done
  fi
  if (( COUNT_SKIP_EXT > 0 )); then
    echo "  Skipped by extension (first 5):"
    for p in "${SKIP_EXT_SAMPLES[@]}"; do echo "    • $p"; done
  fi
  echo
  if (( ${#MISSING_FROM_DISK[@]} > 0 )); then
    echo "⚠️  KEEP ENTRIES MISSING FROM DISK (${#MISSING_FROM_DISK[@]})"
    echo "    These publications list a file that doesn't exist on disk:"
    for p in "${MISSING_FROM_DISK[@]:0:10}"; do echo "    • $p"; done
    if (( ${#MISSING_FROM_DISK[@]} > 10 )); then
      echo "    … and $((${#MISSING_FROM_DISK[@]} - 10)) more (see manifest JSON)"
    fi
    echo
  fi
  if [[ "$MODE" == "dry-run" ]]; then
    echo "DRY RUN — no files were moved. To execute, re-run with --execute."
  fi
} | tee "$MANIFEST_TXT"

info ""
info "Manifest written: $MANIFEST_JSON"
info "                  $MANIFEST_TXT"

# ---------- execute ----------
if [[ "$EXECUTE" == true ]]; then
  info ""
  info "EXECUTING moves (writing $MOVES_JSONL)"
  STARTED=$(date +%s)
  MOVED=0
  ERRORS=0
  : > "$MOVES_JSONL"

  for rel in "${MOVE_LIST[@]}"; do
    src="$WEB_ROOT/$rel"
    dst="$QUARANTINE/$rel"
    dst_parent="$(dirname "$dst")"

    if [[ ! -f "$src" ]]; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) src_missing $rel" >> "$ERRORS_LOG"
      ERRORS=$((ERRORS + 1))
      continue
    fi
    if [[ -e "$dst" ]]; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) dst_exists $rel" >> "$ERRORS_LOG"
      ERRORS=$((ERRORS + 1))
      continue
    fi

    size="$(stat -c %s "$src")"
    mtime="$(stat -c %Y "$src")"
    mtime_iso="$(date -u -d "@$mtime" +%Y-%m-%dT%H:%M:%SZ)"
    sha="$(sha256sum "$src" | awk '{print $1}')"

    mkdir -p "$dst_parent"
    if ! mv "$src" "$dst" 2>>"$ERRORS_LOG"; then
      ERRORS=$((ERRORS + 1))
      continue
    fi

    # verify destination
    if [[ ! -f "$dst" ]]; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) dst_missing_after_mv $rel" >> "$ERRORS_LOG"
      ERRORS=$((ERRORS + 1))
      continue
    fi
    new_size="$(stat -c %s "$dst")"
    if [[ "$new_size" != "$size" ]]; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) size_mismatch $rel src=$size dst=$new_size" >> "$ERRORS_LOG"
      ERRORS=$((ERRORS + 1))
      continue
    fi

    # log the move
    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg src_rel "$rel" \
      --arg src_abs "$src" \
      --arg dst_abs "$dst" \
      --argjson size "$size" \
      --arg sha256 "$sha" \
      --arg mtime "$mtime_iso" \
      --arg run_id "$RUN_ID" \
      '{ts:$ts,src_rel:$src_rel,src_abs:$src_abs,dst_abs:$dst_abs,size:$size,sha256:$sha256,mtime:$mtime,run_id:$run_id}' \
      >> "$MOVES_JSONL"

    MOVED=$((MOVED + 1))
    if (( MOVED % 100 == 0 )); then
      info "  …moved ${MOVED}/${COUNT_MOVE}"
    fi
  done

  ELAPSED=$(( $(date +%s) - STARTED ))

  # ---------- post-flight ----------
  EMPTY_DIRS_LEFT=0
  if (( MOVED > 0 )); then
    EMPTY_DIRS_LEFT="$(find "$WEB_ROOT" -mindepth 1 -type d -empty | wc -l)"
  fi

  COMPLETED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # update manifest with post-flight fields
  tmp_manifest="$(mktemp)"
  jq \
    --arg completed_at "$COMPLETED_AT" \
    --argjson moved "$MOVED" \
    --argjson errors "$ERRORS" \
    --argjson elapsed_seconds "$ELAPSED" \
    --argjson empty_dirs_left "$EMPTY_DIRS_LEFT" \
    '.completed_at = $completed_at
     | .counts.moved = $moved
     | .counts.errors = $errors
     | .timing = { elapsed_seconds: $elapsed_seconds }
     | .empty_dirs_left = $empty_dirs_left' \
    "$MANIFEST_JSON" > "$tmp_manifest" && mv "$tmp_manifest" "$MANIFEST_JSON"

  info ""
  info "================================================================"
  info "POST-FLIGHT SUMMARY"
  info "================================================================"
  info "  Moved successfully:     ${MOVED}"
  info "  Errors:                 ${ERRORS}  $([ "$ERRORS" -gt 0 ] && echo "(see ${ERRORS_LOG})")"
  info "  Elapsed:                ${ELAPSED}s"
  info "  Move log (for restore): ${MOVES_JSONL}"
  info "  Empty dirs in web-root: ${EMPTY_DIRS_LEFT}"
  if (( EMPTY_DIRS_LEFT > 0 )) && [[ "$CLEAN_EMPTY_DIRS" != true ]]; then
    info "    (use --clean-empty-dirs to remove them; safe — drone-dir and keep paths still have files)"
  fi

  if [[ "$CLEAN_EMPTY_DIRS" == true ]]; then
    info ""
    info "Cleaning empty directories under $WEB_ROOT..."
    REMOVED_DIRS="$(find "$WEB_ROOT" -mindepth 1 -type d -empty -delete -print | wc -l)"
    info "  Removed: ${REMOVED_DIRS} empty directories"
  fi

  info ""
  info "To restore everything moved in this run:"
  info "  ./restore.sh --moves ${MOVES_JSONL} --all --execute"
fi

info ""
info "Done."
