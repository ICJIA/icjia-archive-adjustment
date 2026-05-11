# ICJIA Archive Quarantine Tool — Design Document

**Project**: archive-quarantine
**Author**: Chris Rich, ICJIA / IDS
**Status**: Design — ready for implementation
**Date**: 2026-05-11

---

## 1. Context & Rationale

The Illinois Criminal Justice Information Authority (ICJIA) operates an archive file server at `archive.icjia-api.cloud` that serves PDFs and other documents publicly over HTTP. The majority of files on the archive are **not** linked to current ResearchHub publications — they are older or orphaned assets that nonetheless represent web-accessible documents subject to ADA Title II accessibility requirements.

The federal ADA Title II web accessibility deadline (April 26, 2027 per the DOJ Interim Final Rule) creates a remediation burden proportional to the volume of public-facing documents. ICJIA's statewide IT provider (DoIT) has recommended a proactive posture: **remove documents from web reach unless they are actively referenced by a current publication.** This dramatically reduces the remediation surface area without deleting any content.

This tool implements that posture safely and reversibly. It moves all non-referenced files off the served filesystem path into a quarantine directory on the same server (still available to staff, no longer HTTP-accessible), while preserving:

1. **Publications listed in the GraphQL `publications` endpoint** — the canonical source of currently referenced documents.
2. **The `drone2026/` directory** — an active project area that must remain online.

The design favors reversibility, auditability, and a clean separation between the network-dependent step (querying GraphQL) and the destructive step (moving files).


## 2. Goals & Non-Goals

### Goals

- Move all non-referenced documents out of the web-served filesystem path into a sibling quarantine directory.
- Preserve relative directory structure under the quarantine path so any file can be restored to its exact original location.
- Produce a durable audit trail — every move logged with source path, destination path, file size, SHA-256, mtime, and timestamp.
- Default to dry-run; require explicit `--execute` flag for destructive operations.
- Support full or selective restore from the audit trail without needing GraphQL or any network.
- Allow hand-editing of the keep list before execution.

### Non-Goals

- **Not a deletion tool.** Files are moved, never removed.
- **Not a sync tool.** Each run is one-shot; the tool does not maintain ongoing sync with GraphQL.
- **Not a remediation tool.** It does not modify any kept PDF.
- **Not a migration tool.** Quarantined files stay on the same host.

## 3. Architecture Overview

```
┌─────────────────────┐         ┌──────────────────┐         ┌──────────────────┐
│ build-keep-list.js  │  ───>   │   keep.json      │  ───>   │  quarantine.sh   │
│  (workstation,      │         │  (auditable      │         │  (archive server,│
│   needs internet)   │         │   artifact)      │         │   needs SSH)     │
└─────────────────────┘         └──────────────────┘         └──────────────────┘
        │                                                              │
        │                                                              ▼
        ▼                                                     ┌──────────────────┐
   GraphQL @                                                  │ manifest-*.json  │
   agency.icjia-api.cloud                                     │ moves-*.jsonl    │
                                                              └──────────────────┘
                                                                       │
                                                                       ▼
                                                              ┌──────────────────┐
                                                              │  restore.sh      │
                                                              │  (any time later)│
                                                              └──────────────────┘
```

Three tools, each single-purpose:

| Tool | Runs on | Network deps | Side effects |
|------|---------|--------------|--------------|
| `build-keep-list.js` | Any machine with internet | GraphQL endpoint | Writes `keep.json` |
| `quarantine.sh` | Archive server (SSH) | None | Moves files; writes logs |
| `restore.sh` | Archive server (SSH) | None | Moves files back; writes logs |

The intermediate `keep.json` is a stable, reviewable artifact. Once generated, the destructive phase has no remote dependencies — it can be run any time, even with GraphQL offline.

---

## 4. Tool 1: `build-keep-list.js` (Node)

### Purpose
Query the ICJIA GraphQL endpoint, normalize publication file URLs, emit a JSON keep list.

### Inputs

| Flag | Default | Description |
|------|---------|-------------|
| `--endpoint URL` | `https://agency.icjia-api.cloud/graphql` | GraphQL endpoint |
| `--limit N` | `900` | Max publications to fetch in one query |
| `--out PATH` | `./keep-{ISO-timestamp}.json` | Output file path |
| `--host HOST` | `archive.icjia-api.cloud` | Host filter for inclusion in keep set |

### GraphQL Query

```graphql
{
  publications(limit: 900) {
    title
    slug
    fileURL
  }
}
```

### Processing Logic

For each publication in the response:

1. If `fileURL` is null/empty → increment `skipped.null_fileurl`, continue.
2. Attempt `new URL(fileURL)`. On failure → increment `skipped.unparseable`, log warning, continue.
3. If `url.host !== archive_host` → increment `skipped.non_archive_host`, continue. (These are typically researchhub-hosted, out of scope for this tool.)
4. Take `url.pathname` (e.g. `/files/icjia/pdf/compiler/Authority%20Endorses%20Proposed%20CHRI%20Act.pdf`).
5. URL-decode the pathname (`decodeURIComponent`). `%20` → space, etc.
6. Validate the decoded path starts with `/files/`. If not, log warning and skip with `skipped.unexpected_prefix`.
7. Strip the `/files/` prefix → filesystem-relative path.
8. Push to `keep[]` with full provenance: `{ title, slug, fileURL, path }`.

### Normalization Edge Cases (from real sample data)

| Case | Example | Handling |
|------|---------|----------|
| URL-encoded spaces | `Authority%20Endorses%20Proposed%20CHRI%20Act.pdf` | `decodeURIComponent` → literal space |
| Literal spaces in URL | `Murder in Illinois 1973 to 1982.pdf` | Already decoded; passes through |
| Unencoded `&` in URL | `T&I 1987.pdf` | `new URL()` parses fine (`&` only special in query strings); pass through |
| Apostrophes | `Illinois' Computerized Criminal History.pdf` | Pass through exactly |
| Mixed-case directory segments | `compiler` vs. `ResearchReports` | Preserve case exactly; filesystem is case-sensitive |
| Leading/trailing whitespace in segments | (hypothetical) | Preserve exactly — do NOT trim |

### Output Schema

```json
{
  "generated_at": "2026-05-11T14:23:00.000Z",
  "source": "https://agency.icjia-api.cloud/graphql",
  "archive_host": "archive.icjia-api.cloud",
  "url_prefix_stripped": "/files/",
  "query": "{ publications(limit: 900) { title slug fileURL } }",
  "stats": {
    "total_publications": 873,
    "kept": 689,
    "skipped": {
      "null_fileurl": 12,
      "non_archive_host": 168,
      "unparseable": 0,
      "unexpected_prefix": 4
    }
  },
  "keep": [
    {
      "title": "Authority Endorses Proposed CHRI Act",
      "slug": "authority-endorses-proposed-chri-act",
      "fileURL": "https://archive.icjia-api.cloud/files/icjia/pdf/compiler/Authority%20Endorses%20Proposed%20CHRI%20Act.pdf",
      "path": "icjia/pdf/compiler/Authority Endorses Proposed CHRI Act.pdf"
    }
  ]
}
```

> **Contract**: the `path` field is the **only** field the mover (Tool 2) consumes. Other fields are for human audit.

### CLI

```bash
node build-keep-list.js [--endpoint URL] [--limit N] [--out PATH] [--host HOST]
```

### Dependencies

- Node.js ≥ 18 (uses built-in `fetch`)
- Zero npm dependencies (`fetch`, `fs`, `url`, `path`, `process` all built-in)

### Errors

- Network failure → exit code 1, write nothing.
- HTTP non-2xx response → exit code 1, write nothing.
- GraphQL `errors` array in response → exit code 1, write nothing, surface errors.
- All other issues during processing → warn and continue; final stats reflect what was skipped.

---

## 5. Tool 2: `quarantine.sh` (Bash)

### Purpose
Walk the archive's web-served filesystem, classify each file (keep/move/skip), and in `--execute` mode move the move-set into a sibling quarantine directory preserving relative structure.

### Inputs

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--keep PATH` | yes | — | Path to `keep.json` from Tool 1 |
| `--web-root PATH` | yes | — | Filesystem path that `/files/` URL prefix maps to |
| `--quarantine PATH` | yes | — | Destination root for moved files |
| `--drone-dir NAME` | no | `drone2026` | Directory name (relative to web-root) to preserve recursively |
| `--extensions LIST` | no | `pdf,xlsx,xls,docx,doc,pptx,ppt,rtf,csv` | Comma-separated extensions to consider moving |
| `--dry-run` | no | `true` | Default behavior: walk + classify + write manifest, no moves |
| `--execute` | no | `false` | Actually move files (must be explicit) |
| `--limit N` | no | unlimited | Cap the move set at N files |
| `--log-dir PATH` | no | `./logs` | Where to write manifest/moves/error logs |
| `--clean-empty-dirs` | no | `false` | After moves, remove empty directories left in web-root |

### Decision Tree (per file under `--web-root`)

```
For each file F under --web-root:
  rel = path of F relative to --web-root

  1. If rel starts with "${drone_dir}/"           → SKIP (keep)
  2. If extension of F not in --extensions list    → SKIP (keep)
  3. If rel is in KEEP_SET (from keep.json)        → SKIP (keep)
  4. Otherwise                                      → MOVE
```

Classification is **purely path-based**; never reads file contents.

### Path Matching

Strict, case-sensitive, fully-decoded string equality. Load the keep set into bash via `jq` and an associative array:

```bash
declare -A KEEP_SET
while IFS= read -r path; do
  KEEP_SET["$path"]=1
done < <(jq -r '.keep[].path' "$KEEP_JSON")
```

Lookup is O(1).

### Move Mechanics

For each file classified MOVE in `--execute` mode:

```
src = $WEB_ROOT/$rel
dst = $QUARANTINE/$rel
```

Steps:
1. Compute SHA-256 of source.
2. Capture mtime (`stat -c %y`) and size (`stat -c %s`).
3. `mkdir -p` the destination parent.
4. If destination already exists → abort this move, log to `errors-*.log` as `dst_exists`, continue.
5. `mv` source to destination (atomic if same filesystem).
6. Verify destination exists and size matches.
7. Append a JSONL line to `moves-{run_id}.jsonl`:

```json
{"ts":"2026-05-11T14:25:00Z","src_rel":"icjia/pdf/old/foo.pdf","src_abs":"/var/www/archive/files/icjia/pdf/old/foo.pdf","dst_abs":"/var/data/archive-quarantine/icjia/pdf/old/foo.pdf","size":124532,"sha256":"abc123...","mtime":"2018-03-12T09:14:00Z","run_id":"2026-05-11T14-25-00"}
```

Single-file failures never abort the run — log and continue.

**Empty directories** left in `--web-root` after moves: not removed by default. Add `--clean-empty-dirs` for opt-in cleanup via `find $WEB_ROOT -type d -empty -delete` (won't touch `--drone-dir` since it has files).

### Outputs

In `--log-dir`:

| File | When | Contents |
|------|------|----------|
| `manifest-{run_id}.json` | Always | Full classification: counts, sample paths per category, mode |
| `manifest-{run_id}.txt` | Always | Human-readable summary |
| `moves-{run_id}.jsonl` | `--execute` only | One JSON line per successful move |
| `errors-{run_id}.log` | On errors | Plain-text error log |

### Manifest Schema

```json
{
  "run_id": "2026-05-11T14-25-00",
  "mode": "dry-run",
  "started_at": "2026-05-11T14:25:00Z",
  "completed_at": "2026-05-11T14:26:14Z",
  "web_root": "/var/www/archive/files",
  "quarantine_root": "/var/data/archive-quarantine",
  "keep_json": "/home/cjbuilds/keep-2026-05-11.json",
  "drone_dir": "drone2026",
  "extensions": ["pdf","xlsx","xls","docx","doc","pptx","ppt","rtf","csv"],
  "counts": {
    "scanned": 12847,
    "keep_publication": 689,
    "keep_drone2026": 412,
    "skip_other_extension": 8923,
    "move": 2823,
    "errors": 0
  },
  "samples": {
    "move": ["icjia/pdf/Bulletins/Old Report.pdf"],
    "keep_publication": ["icjia/pdf/compiler/Authority Endorses Proposed CHRI Act.pdf"],
    "keep_drone2026": ["drone2026/2026-02-aerial-survey.pdf"]
  },
  "keep_missing_from_disk": [
    "icjia/pdf/somefolder/expected-but-not-present.pdf"
  ]
}
```

> The `keep_missing_from_disk` field surfaces any file listed in `keep.json` that doesn't actually exist on the filesystem. Worth investigating but not an error.

### CLI Examples

```bash
# Dry run (default)
./quarantine.sh \
  --keep ./keep-2026-05-11.json \
  --web-root /var/www/archive/files \
  --quarantine /var/data/archive-quarantine

# Limited execution: move only first 10 files (smoke test on real data)
./quarantine.sh \
  --keep ./keep-2026-05-11.json \
  --web-root /var/www/archive/files \
  --quarantine /var/data/archive-quarantine \
  --limit 10 \
  --execute

# Full execution
./quarantine.sh \
  --keep ./keep-2026-05-11.json \
  --web-root /var/www/archive/files \
  --quarantine /var/data/archive-quarantine \
  --execute
```

### Dependencies

- `bash` ≥ 4 (for associative arrays)
- `jq`
- `find`, `mv`, `mkdir`, `stat`, `sha256sum`, `realpath` (GNU coreutils + GNU find)
- **No network access required**
- Recommended: `--quarantine` on same filesystem as `--web-root` so `mv` is atomic

---

## 6. Tool 3: `restore.sh` (Bash)

### Purpose
Reverse moves recorded in `moves.jsonl`, fully or selectively.

### Inputs

| Flag | Default | Description |
|------|---------|-------------|
| `--moves PATH` | required | Path to `moves-*.jsonl` |
| `--all` | — | Restore every move in the log |
| `--match PATTERN` | — | Restore only entries whose `src_rel` matches the glob pattern |
| `--dry-run` | `true` | Preview only |
| `--execute` | `false` | Actually move files back |
| `--verify-sha` | `true` | Verify SHA-256 before restoring |
| `--log-dir PATH` | `./logs` | Where to write the restore log |

### Logic

For each line in `moves.jsonl` (filtered by `--all` or `--match`):

1. Check `dst_abs` exists. If not → log as `not_in_quarantine`, skip.
2. If `--verify-sha`: compute SHA-256 of `dst_abs`, compare with recorded value. Mismatch → log as `sha_mismatch`, skip (defends against tampering or corruption).
3. `mkdir -p` source parent.
4. If `src_abs` already exists → log as `src_exists`, skip (don't clobber).
5. `mv` from `dst_abs` back to `src_abs`.
6. Append a record to `restores-{run_id}.jsonl`.

Restores are themselves logged so the full move/restore history is auditable.

### CLI Examples

```bash
# Restore everything
./restore.sh --moves logs/moves-2026-05-11.jsonl --all --execute

# Restore one report
./restore.sh --moves logs/moves-2026-05-11.jsonl \
  --match 'icjia/pdf/Bulletins/Old Report.pdf' --execute

# Restore a whole subdirectory
./restore.sh --moves logs/moves-2026-05-11.jsonl \
  --match 'icjia/pdf/AnnualReport/*' --execute
```

---

## 7. Operational Workflow

The intended sequence for a production run:

1. **Build the keep list** on workstation:
   ```bash
   node build-keep-list.js --out keep-$(date +%Y-%m-%d).json
   ```
2. **Review the keep list** locally:
   ```bash
   jq '.stats' keep-2026-05-11.json
   jq '.keep | length' keep-2026-05-11.json
   jq '.keep[0:5]' keep-2026-05-11.json
   ```
3. **Copy to archive server**:
   ```bash
   scp keep-2026-05-11.json quarantine.sh restore.sh user@archive.icjia-api.cloud:~/
   ```
4. **Dry-run on server**:
   ```bash
   ssh user@archive.icjia-api.cloud
   ./quarantine.sh --keep keep-2026-05-11.json \
     --web-root /var/www/archive/files \
     --quarantine /var/data/archive-quarantine
   ```
5. **Review the manifest**:
   ```bash
   jq '.counts' logs/manifest-*.json
   cat logs/manifest-*.txt
   ```
6. **Limited execution** (10 files, to confirm move mechanics on real data):
   ```bash
   ./quarantine.sh --keep ... --execute --limit 10
   ```
7. **Verify** — check the quarantine directory, confirm a kept PDF still serves over HTTP, confirm a moved PDF returns 404 (or 410 if you add the nginx snippet later).
8. **Full execution**:
   ```bash
   ./quarantine.sh --keep ... --execute
   ```
9. **Archive the logs**. Keep `keep-*.json`, `manifest-*.json`, `moves-*.jsonl` in version control or secure storage indefinitely. These ARE the audit trail.

---

## 8. Tech Stack & Dependencies

- **`build-keep-list.js`**: Node.js ≥ 18, zero npm deps.
- **`quarantine.sh`** / **`restore.sh`**: Bash 4+, `jq`, GNU coreutils, GNU `find`.
- **Server requirements**: SSH access; read+write on `--web-root` parent; write on `--quarantine` parent. Strongly recommend `--quarantine` on same filesystem as `--web-root` so `mv` is atomic.

---

## 9. File Structure

```
archive-quarantine/
├── README.md
├── design.md                    # This document
├── build-keep-list.js           # Tool 1 (Node)
├── quarantine.sh                # Tool 2 (Bash)
├── restore.sh                   # Tool 3 (Bash)
├── lib/
│   └── normalize.js             # URL normalization (testable in isolation)
├── test/
│   ├── normalize.test.js        # Node unit tests for normalization
│   ├── fixtures/
│   │   └── sample-graphql.json  # Captured 25-record sample for testing
│   └── integration.sh           # End-to-end test with synthetic filesystem
└── logs/                        # gitignored
    ├── keep-*.json
    ├── manifest-*.json
    ├── moves-*.jsonl
    └── restores-*.jsonl
```

---

## 10. Open Questions (Confirm Before / During Implementation)

These were intentionally left open in design and must be confirmed when Claude Code runs:

1. **Confirm archive domain.** Original brief said `archive.icjia.cloud`; observed `fileURL` values use `archive.icjia-api.cloud`. Confirm SSH host and that the served filesystem corresponds to the URLs in GraphQL.
2. **Web root filesystem path.** What directory does `/files/` URL prefix map to on the server? Check nginx config (likely `/etc/nginx/sites-enabled/archive*` or similar). May be an `alias` directive pointing somewhere non-obvious.
3. **Quarantine directory location.** Recommended: sibling to web root on the **same filesystem** (e.g. `/var/data/archive-quarantine` if web root is `/var/www/archive/files`). Must not itself be web-served.
4. **drone2026 location.** Confirm it lives at `${WEB_ROOT}/drone2026/` and not somewhere nested.
5. **Extension scope.** Design defaults to broad sweep (`pdf,xlsx,xls,docx,doc,pptx,ppt,rtf,csv`). Confirm or narrow.
6. **Total file count on the archive.** Influences whether dry-run output needs sampling/pagination for review.
7. **(Follow-up, not in scope here)** nginx `410 Gone` snippet for moved paths. Worth adding after the first successful run.

---

## 11. Edge Cases & Defensive Behavior

| Case | Handling |
|------|----------|
| Symlinks in web root | `find` without `-L` — treat symlinks as themselves, not followed. Document this. |
| Filenames with spaces, newlines, or shell metacharacters | Use `find -print0` and `read -d ''` throughout |
| File in keep list missing from disk | Log to `manifest.keep_missing_from_disk`; not an error |
| File on disk whose path differs from keep list only by case/whitespace | NOT a match (strict comparison). Surface in dry-run for review. |
| Destination path already exists in quarantine | Abort that single move, log `dst_exists`, continue |
| Insufficient disk space on quarantine filesystem | Check `df` upfront; abort gracefully if move set won't fit |
| Permission errors mid-run | Log and continue; summarize at end |
| Hidden files (`.htaccess`, `.DS_Store`) | Extension filter excludes by default; document and confirm |
| Files with no extension | Skipped (extension filter excludes) |
| Cross-filesystem `--quarantine` | Detect via `stat -c %d` comparison; warn loudly (moves become slow and non-atomic) |
| `keep.json` corrupted or unreadable | Abort before scanning anything |
| `keep.json` has zero entries | Abort with explicit error (almost certainly an upstream bug) |

---

## 12. Testing Approach

### Unit tests (Node)
Test `lib/normalize.js` against captured GraphQL fixtures covering:
- URL-encoded spaces
- Literal spaces
- Apostrophes (straight and curly)
- Ampersands in filenames
- Mixed-case path segments
- Null `fileURL`
- Non-archive host
- Malformed URLs
- Unexpected URL prefix (not `/files/`)

### Integration test (Bash)
Create a synthetic filesystem in `/tmp/test-archive/`:
- A handful of "keep" files at paths matching a test `keep.json`
- A `drone2026/` directory with a few files
- A mix of PDFs, XLSXs, DOCXs, and unrelated files (HTML, images)
- A file with spaces in the name, one with an apostrophe, one with `&`

Run `quarantine.sh --dry-run` and assert manifest counts and classifications. Run `--execute` and verify resulting layout. Run `restore.sh --all --execute` and verify original layout is restored byte-for-byte (via SHA comparison).

### Production smoke test
First real execution must use `--limit 10` to confirm move mechanics work on real files before processing the full set.

---

## 13. Out of Scope

- Modifying or remediating any kept PDF (separate workstream — `audit.icjia.app`).
- Web server configuration changes (nginx 410 snippet is a separate, optional follow-up).
- Scheduled re-runs to keep the quarantine in sync with publications (one-shot; future re-syncs are a separate design decision).
- Migration of files off this server entirely.
- Communications to staff or external users about moved URLs (this tool produces the list of moved files, but messaging is out of scope).

---

## 14. Implementation Notes for Claude Code

When implementing:

- **Start with Tool 1 (`build-keep-list.js`) and its unit tests.** It's the most contained piece and produces an artifact the rest of the project depends on. Capture the provided 25-record GraphQL sample as `test/fixtures/sample-graphql.json` for tests.
- **Then write the integration test fixture** (`test/integration.sh`) before writing `quarantine.sh`. Test-first makes the move logic easier to verify.
- **Then `quarantine.sh`**, then `restore.sh`. Keep them small — each should be well under 300 lines of bash. If something gets complex, lean on `jq` rather than parsing JSON in bash.
- **Default to safety**: `--dry-run` must be the implicit default everywhere. Make `--execute` loud (echo a warning, require confirmation if interactive).
- **Logs are first-class outputs**, not debugging afterthoughts. The JSONL format is intentional — easy to grep, parse, and reverse.
- **Do not silently swallow errors**. Every skipped or failed file should appear in the manifest or `errors-*.log`.
- **Do not optimize prematurely.** A linear `find` walk over even 50k files is fast enough.
