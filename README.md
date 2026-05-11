# ICJIA Archive Quarantine

A three-tool pipeline that **safely removes unreferenced documents from web reach** on the ICJIA archive file server (`archive.icjia-api.cloud`) — without deleting anything. Files are *moved* to a sibling quarantine directory on the same machine; every move is logged with cryptographic checksums; every move is reversible.

> **Repo:** https://github.com/ICJIA/icjia-archive-adjustment
> **Design doc:** [`docs/archive-quarantine-design.md`](./docs/archive-quarantine-design.md)
> **License:** MIT — see [`LICENSE`](./LICENSE)

---

## For non-technical readers — *why does this exist?*

ICJIA operates an archive file server that serves PDFs and other documents publicly over HTTP. Most of those files are *not* linked from any current ResearchHub publication — they're older or orphaned assets. But every public-facing document is subject to the federal **ADA Title II web accessibility deadline (April 26, 2027)**.

The Illinois Department of Innovation & Technology (DoIT) recommended a proactive posture: **don't try to remediate everything; instead, take everything off the web that no current publication is actually using.** That dramatically reduces the remediation surface without losing any content.

This tool implements that posture in three deliberate steps:

| Step | What it does | Risk if wrong |
|---|---|---|
| **1. Build keep-list** | Asks the GraphQL publications API which documents are currently referenced. Writes a JSON file listing those paths. | Read-only. Nothing changes. |
| **2. Quarantine** | Walks the archive's filesystem, classifies each file (keep / move / skip), moves the non-referenced ones into a sibling directory that is *not* publicly served. | Defaults to **dry-run** — must pass `--execute` explicitly. Every move is logged with SHA-256. |
| **3. Restore** | Replays the move log in reverse (all files, by directory, or by filename). Verifies SHA-256 before each restore. | Cannot accidentally clobber existing files; cannot restore files that don't match their original checksum. |

The pipeline is **conservative by design**:

- Nothing is ever deleted — only moved.
- The destructive step (Tool 2) only needs the workstation-side keep-list — it has zero network dependencies and zero side effects in its default dry-run mode.
- Every moved file has its full path, size, mtime, and SHA-256 logged as JSONL. The log alone is sufficient to restore the entire move, indefinitely.
- A single file can be restored from quarantine in seconds at any future date, by exact name or filename pattern.

---

## Architecture

```
┌─────────────────────┐         ┌──────────────────┐         ┌──────────────────┐
│ build-keep-list.js  │  ───>   │   keep.json      │  ───>   │  quarantine.sh   │
│ (workstation,       │         │  (auditable      │         │  (archive server,│
│  needs internet)    │         │   artifact)      │         │   needs SSH)     │
└─────────────────────┘         └──────────────────┘         └──────────────────┘
        │                                                              │
        ▼                                                              ▼
   GraphQL @                                              manifest-*.json/.txt
   agency.icjia-api.cloud                                 moves-*.jsonl
                                                                       │
                                                                       ▼
                                                              ┌──────────────────┐
                                                              │  restore.sh      │
                                                              │  (any time later)│
                                                              └──────────────────┘
```

| Tool | Runs on | Network | Destructive |
|---|---|---|---|
| `build-keep-list.js` | Workstation | GraphQL endpoint | No — write-only to local disk |
| `quarantine.sh` | Archive server (SSH) | None | Yes, opt-in via `--execute` |
| `restore.sh` | Archive server (SSH) | None | Yes, opt-in via `--execute` |

The intermediate `keep.json` is **a stable, reviewable artifact**. Once produced, the destructive phase has no remote dependencies — it can be run any time, even with GraphQL offline.

---

## Quick start

```bash
# 1. Build the keep-list locally (~5 seconds)
node build-keep-list.js --out keep-$(date +%Y-%m-%d).json
jq '.stats' keep-2026-05-11.json

# 2. Copy artifacts to the archive server
scp keep-2026-05-11.json quarantine.sh restore.sh \
    forge@archive.icjia-api.cloud:~/

# 3. SSH in and do a dry-run
ssh forge@archive.icjia-api.cloud
./quarantine.sh \
  --keep keep-2026-05-11.json \
  --web-root /home/forge/archive.icjia-api.cloud/root/files \
  --quarantine /home/forge/archive-quarantine \
  --log-dir ./logs

# 4. Review the manifest before executing
jq '.counts' logs/manifest-*.json
cat logs/manifest-*.txt

# 5. (Optional) Smoke-test with just 10 files
./quarantine.sh --keep ... --web-root ... --quarantine ... \
  --limit 10 --execute

# 6. Full execution
./quarantine.sh --keep ... --web-root ... --quarantine ... --execute

# 7. Restore later if needed (single file)
./restore.sh --moves logs/moves-2026-05-11T....jsonl \
  --match 'icjia/pdf/Bulletins/Repeat Offenders in Illinois.pdf' --execute
```

---

## Tool 1: `build-keep-list.js`

Node script that paginates the publications GraphQL endpoint and writes a keep-list JSON.

### Requirements

- Node.js ≥ 18 (uses built-in `fetch`, zero npm dependencies)
- Internet access to `https://agency.icjia-api.cloud/graphql`

### Flags

| Flag | Default | Purpose |
|---|---|---|
| `--endpoint URL` | `https://agency.icjia-api.cloud/graphql` | GraphQL endpoint |
| `--page-size N` | `500` | Records per request. Endpoint errors without a `limit`; loop paginates until a page returns fewer than `--page-size` records. |
| `--out PATH` | `./keep-{ISO}.json` | Output path. `:` in ISO replaced with `-` for filesystem safety. |
| `--hosts LIST` | `archive.icjia-api.cloud,archive.icjia.cloud` | Comma-separated list of archive hosts. Publications whose `fileURL` host matches any entry are kept. `--host` is accepted as an alias. |
| `--url-prefix S` | `/files/` | URL pathname prefix to strip when deriving filesystem-relative paths. |
| `--max-pubs N` | `50000` | Safety cap on total publications fetched. Aborts with explicit error if exceeded. |

### Output schema

```json
{
  "generated_at": "2026-05-11T14:23:00.000Z",
  "source": "https://agency.icjia-api.cloud/graphql",
  "archive_hosts": ["archive.icjia-api.cloud", "archive.icjia.cloud"],
  "url_prefix_stripped": "/files/",
  "query_template": "{ publications(limit: N, start: N, sort: \"id:asc\") { id title slug fileURL created_at updated_at published_at } }",
  "pagination": { "syntax": "strapi-v3-limit-start-sort", "page_size": 500 },
  "stats": {
    "total_publications": 1107,
    "kept": 927,
    "skipped": { "null_fileurl": 44, "unparseable": 0, "non_archive_host": 136, "unexpected_prefix": 0 },
    "pages_fetched": 3
  },
  "keep": [
    {
      "id": "3419",
      "title": "Authority Endorses Proposed CHRI Act",
      "slug": "authority-endorses-proposed-chri-act",
      "fileURL": "https://archive.icjia-api.cloud/files/icjia/pdf/compiler/Authority%20Endorses%20Proposed%20CHRI%20Act.pdf",
      "path": "icjia/pdf/compiler/Authority Endorses Proposed CHRI Act.pdf",
      "created_at": "2021-07-01T21:36:40.584Z",
      "updated_at": "2021-07-01T21:36:40.584Z",
      "published_at": "2021-07-01T21:36:40.584Z"
    }
  ]
}
```

> **Contract:** the `path` field is the *only* field that Tool 2 (`quarantine.sh`) consumes. Everything else — `id`, `title`, `fileURL`, timestamps — is human-audit metadata.

### URL normalization

All normalization rules live in [`lib/normalize.js`](./lib/normalize.js) as a pure module. Tests in [`test/normalize.test.js`](./test/normalize.test.js) cover:

- URL-encoded spaces (`%20` → literal space)
- Literal spaces in URL pathnames
- Straight and curly apostrophes (`'` and `’`)
- Ampersands (`&`)
- Mixed-case directory segments (case is preserved exactly)
- Null `fileURL` → `reason: null_fileurl`
- Malformed URL → `reason: unparseable`
- Non-archive host → `reason: non_archive_host`
- Pathname missing `/files/` prefix → `reason: unexpected_prefix`

Run unit tests with `node --test`.

---

## Tool 2: `quarantine.sh`

Bash script that walks the web-served filesystem and moves the non-referenced files into a sibling quarantine directory. **Dry-run is the default.**

### Requirements (server-side)

- Bash ≥ 4 (associative arrays)
- `jq` (≥ 1.5)
- GNU coreutils: `find`, `mv`, `stat`, `sha256sum`, `realpath`
- `flock` (for the lockfile)

### Flags

| Flag | Required | Default | Notes |
|---|---|---|---|
| `--keep PATH` | yes | — | Path to `keep.json` |
| `--web-root PATH` | yes | — | Filesystem path that maps to the `/files/` URL prefix |
| `--quarantine PATH` | yes | — | Destination root for moved files |
| `--drone-dir PATH` |  | `icjia/drone2026` | Path relative to web-root to preserve recursively. Accepts nested paths. |
| `--extensions LIST` |  | `pdf,xlsx,xls,docx,doc,pptx,ppt,rtf,csv` | Comma-separated extensions to consider for moving |
| `--execute` |  | off | Without this, classify-and-report only |
| `--limit N` |  | 0 | Cap the move set at N files (smoke testing) |
| `--log-dir PATH` |  | `./logs` | Where to write manifests / move logs / errors |
| `--clean-empty-dirs` |  | off | After moves, remove empty directories left in web-root |
| `--lockfile PATH` |  | `$LOG_DIR/quarantine.lock` | Lockfile (prevents concurrent runs) |

### Classification (per file under `--web-root`)

```
For each file F under --web-root:
  rel = path of F relative to --web-root

  1. If rel starts with "${drone_dir}/"          → KEEP (preserved dir)
  2. If extension of F not in --extensions list   → SKIP (other extension)
  3. If rel is in KEEP_SET (from keep.json)       → KEEP (publication)
  4. Otherwise                                    → MOVE
```

Classification is **purely path-based** — file contents are never read.

### Outputs (in `--log-dir`)

| File | When | Contents |
|---|---|---|
| `manifest-{run_id}.json` | Always | Full classification, counts, samples, missing keep entries |
| `manifest-{run_id}.txt` | Always | Human-readable summary |
| `moves-{run_id}.jsonl` | `--execute` only | One JSON line per successful move |
| `errors-{run_id}.log` | On errors | Plain-text error log |

`moves-{run_id}.jsonl` line shape:

```json
{
  "ts": "2026-05-11T14:25:00Z",
  "src_rel": "icjia/pdf/old/foo.pdf",
  "src_abs": "/home/forge/archive.icjia-api.cloud/root/files/icjia/pdf/old/foo.pdf",
  "dst_abs": "/home/forge/archive-quarantine/icjia/pdf/old/foo.pdf",
  "size": 124532,
  "sha256": "abc123…",
  "mtime": "2018-03-12T09:14:00Z",
  "run_id": "2026-05-11T14-25-00Z"
}
```

This log is the **single source of truth** for `restore.sh`.

### Preflight checks

On every run (even dry-run), the script verifies:

1. All required tools present (`jq`, `find`, `mv`, `stat`, `sha256sum`, `realpath`, `flock`)
2. Bash ≥ 4
3. `keep.json` parses as JSON and has ≥1 entries
4. `--web-root` is a readable, writable directory
5. `--quarantine` parent exists and is writable
6. Same-filesystem check: warns if web-root and quarantine are on different filesystems (mv would fall back to copy+delete, becoming slow and non-atomic)
7. `--drone-dir` exists (warns if missing)
8. Reports free disk space at the quarantine parent
9. Acquires an exclusive `flock` on `--lockfile` (prevents concurrent runs)

### Post-flight summary (on `--execute`)

```
================================================================
POST-FLIGHT SUMMARY
================================================================
  Moved successfully:     7142
  Errors:                 0
  Elapsed:                127s
  Move log (for restore): logs/moves-2026-05-11T14-25-00Z.jsonl
  Empty dirs in web-root: 13
    (use --clean-empty-dirs to remove them; safe — drone-dir and keep paths still have files)

To restore everything moved in this run:
  ./restore.sh --moves logs/moves-2026-05-11T14-25-00Z.jsonl --all --execute
```

---

## Tool 3: `restore.sh`

Replays a `moves-*.jsonl` log in reverse with SHA-256 verification.

### Flags

| Flag | Required | Notes |
|---|---|---|
| `--moves PATH` | yes | Path to `moves-{run_id}.jsonl` from a `quarantine.sh --execute` run |
| `--all` | one of these | Restore every entry in the log |
| `--match PATTERN` | one of these | Shell-glob against `src_rel`; quote it |
| `--execute` |  | Without this, report-only |
| `--no-verify-sha` |  | Skip SHA-256 verification (defaults to ON; defends against tampering or corruption) |
| `--log-dir PATH` |  | Default `./logs`; writes `restores-{run_id}.jsonl` |

### Selection patterns

```bash
# Single file by exact path
./restore.sh --moves logs/moves-….jsonl \
  --match 'icjia/pdf/Bulletins/Repeat Offenders in Illinois.pdf' --execute

# Every file under a directory
./restore.sh --moves logs/moves-….jsonl \
  --match 'icjia/pdf/Bulletins/*' --execute

# Fuzzy substring search by filename
./restore.sh --moves logs/moves-….jsonl --match '*Recidivism*' --execute

# Restore everything
./restore.sh --moves logs/moves-….jsonl --all --execute
```

### Per-restore protections

For each entry being restored:

1. **Quarantine file must exist** — otherwise logged as `not_in_quarantine`, skipped.
2. **SHA-256 must match the move-log value** — otherwise logged as `sha_mismatch`, skipped. Defends against tampering or corruption while in quarantine.
3. **Source must not already exist** — otherwise logged as `src_exists`, skipped. Won't clobber an existing file at the destination.

Each successful restore is itself logged as JSONL (`restores-*.jsonl`) so the full move/restore history is reconstructable.

---

## Safety properties

- **No deletion, ever.** The pipeline moves files; it does not remove them.
- **Dry-run by default.** Both `quarantine.sh` and `restore.sh` require an explicit `--execute` flag to do anything destructive.
- **Concurrent-run protection.** `quarantine.sh` acquires an exclusive `flock` on a lockfile, so two operators cannot accidentally interleave moves.
- **Atomicity.** When web-root and quarantine are on the same filesystem (the recommended config), `mv` is atomic. Files are either in the source or destination — never in between.
- **Crypto-verified restore.** Every file's SHA-256 is recorded before the move; restore verifies the checksum before placing the file back.
- **Auditable forever.** `manifest-*.json` plus `moves-*.jsonl` are the audit trail. Keep them in version control or secure storage. They alone are sufficient to:
  - Prove which files were moved on which date
  - Restore any subset, at any future time, with cryptographic guarantee of byte-for-byte fidelity
- **No network dependency for destructive phase.** Once `keep.json` is on the server, `quarantine.sh` and `restore.sh` need zero internet.

---

## Repository layout

```
icjia-archive-adjustment/
├── README.md                     # this file
├── CHANGELOG.md
├── LICENSE                       # MIT
├── package.json                  # Node project metadata (ESM, no deps)
├── .gitignore
├── build-keep-list.js            # Tool 1 (Node)
├── quarantine.sh                 # Tool 2 (Bash)
├── restore.sh                    # Tool 3 (Bash)
├── lib/
│   └── normalize.js              # pure URL→path normalization
├── test/
│   ├── normalize.test.js         # node:test unit suite
│   └── fixtures/
│       └── sample-graphql.json   # 25-record real GraphQL response
├── docs/
│   └── archive-quarantine-design.md   # full design spec
└── logs/                         # gitignored; runtime outputs land here
```

---

## Testing

### Unit tests (Tool 1)

```bash
node --test
```

16 tests covering the URL-normalization edge cases enumerated in design §4 plus a fixture smoke test against `test/fixtures/sample-graphql.json` (a real 25-record GraphQL response).

### Integration test (Tools 2 & 3)

Manual / sandboxed. The expected pattern (as exercised during development):

1. Create a synthetic web-root and a small `keep.json` in `/tmp/`.
2. Run `quarantine.sh --execute` against the sandbox.
3. Run `restore.sh --all --execute` against the resulting move log.
4. `sha256sum`-compare originals vs restored — they must match byte-for-byte.

The sandbox tests are not committed as automation because they require a Linux-with-GNU-coreutils host. They exercise the same scripts that ship in production, on the same filesystem semantics (ext4) and `mv` atomicity guarantees.

---

## Production operational workflow

The intended sequence for the production run:

1. **Build the keep-list** on workstation:
   ```bash
   node build-keep-list.js --out keep-$(date +%Y-%m-%d).json
   jq '.stats' keep-*.json
   ```
2. **Review the keep-list locally.** Spot-check a handful of entries by pasting `fileURL` values into a browser.
3. **Copy artifacts to the archive server:**
   ```bash
   scp keep-*.json quarantine.sh restore.sh forge@archive.icjia-api.cloud:~/
   ```
4. **Dry-run on server:**
   ```bash
   ssh forge@archive.icjia-api.cloud
   ./quarantine.sh \
     --keep keep-*.json \
     --web-root /home/forge/archive.icjia-api.cloud/root/files \
     --quarantine /home/forge/archive-quarantine
   ```
5. **Review the manifest:**
   ```bash
   jq '.counts' logs/manifest-*.json
   cat logs/manifest-*.txt
   ```
6. **Smoke-test execution (10 files):**
   ```bash
   ./quarantine.sh --keep ... --web-root ... --quarantine ... --limit 10 --execute
   ```
7. **Verify the smoke test** — confirm a kept PDF still serves over HTTP, confirm a quarantined PDF now returns 404.
8. **Full execution:**
   ```bash
   ./quarantine.sh --keep ... --web-root ... --quarantine ... --execute
   ```
9. **Archive the logs.** Keep `keep-*.json`, `manifest-*.json`, `moves-*.jsonl` in version control or secure storage indefinitely. **These ARE the audit trail.**

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| GraphQL: `Cannot query field "createdAt"` | Endpoint uses snake_case timestamps | Already handled — query uses `created_at` |
| `stats.kept` is 0 | Wrong endpoint, wrong host filter, or schema change | Inspect output and investigate before running Tool 2 |
| `stats.kept` is unexpectedly high | The current count is ~927. If you see a different order of magnitude, the schema may have changed. | Compare to recent `keep.json` files. |
| Tool 2 aborts: "lockfile" | Another `quarantine.sh` is already running | Wait for it, or remove the stale lockfile after confirming no process holds it |
| Tool 2 warns "different filesystems" | `--quarantine` is on a different volume than `--web-root` | Move quarantine to the same filesystem; otherwise `mv` becomes slow copy+delete |
| Restore: `sha_mismatch` | The quarantined file has changed since it was moved | Investigate — could be tampering or filesystem corruption; do not bypass without understanding why |
| Restore: `not_in_quarantine` | The quarantine file was already restored, deleted, or moved out of quarantine | Check the restore log; the file may already be back in web-root |
| 404 instead of 410 for moved URLs | `serve` (Vercel) doesn't have nginx-style routing | Optional follow-up: swap to nginx with a `410 Gone` rule for moved paths |

---

## Links

- Design doc: [`docs/archive-quarantine-design.md`](./docs/archive-quarantine-design.md)
- Changelog: [`CHANGELOG.md`](./CHANGELOG.md)
- License: [`LICENSE`](./LICENSE)
- Repository: https://github.com/ICJIA/icjia-archive-adjustment
- Federal ADA Title II web accessibility rule: https://www.ada.gov/resources/2024-03-08-web-rule/
