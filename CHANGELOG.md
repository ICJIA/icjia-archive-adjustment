# Changelog

All notable changes to the archive-quarantine project are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- **Tool 1 — `build-keep-list.js`**: queries the ICJIA publications GraphQL endpoint with pagination, normalizes archive-hosted file URLs, writes a `keep.json` audit artifact.
  - Multi-host filter (`--hosts archive.icjia-api.cloud,archive.icjia.cloud`) covering both DNS names that point at the archive server.
  - Strapi v3 pagination (`limit + start + sort`) with overflow guard (`--max-pubs`).
  - Per-entry provenance: `id`, `title`, `slug`, `fileURL`, derived `path`, `created_at`, `updated_at`, `published_at`.
  - 16-test suite covering URL-encoding edge cases (literal spaces, encoded spaces, apostrophes, ampersands, mixed-case directories), error branches (null / unparseable / non-archive host / unexpected prefix), and a fixture smoke test against a real 25-record sample.
- **Tool 2 — `quarantine.sh`**: server-side mover with extensive preflight, dry-run-by-default, and SHA-256–logged JSONL move trail.
  - Preflight: required tools (`jq`, `find`, `mv`, `stat`, `sha256sum`, `realpath`, `flock`), bash ≥ 4, valid keep.json with ≥1 entries, web-root readable & writable, quarantine parent writable, same-filesystem check (atomic mv), drone-dir existence, disk-space report, lockfile (`flock`-based, prevents concurrent runs).
  - Classification: path-only (never reads content) → keep-publication / keep-drone-dir / skip-extension / move.
  - Outputs: `manifest-{run_id}.json`, `manifest-{run_id}.txt` (human-readable), `moves-{run_id}.jsonl` (only on `--execute`), `errors-{run_id}.log`.
  - Post-flight: count moved/errored, elapsed time, empty-dirs-remaining surfaced with `--clean-empty-dirs` hint, restore command shown at the end.
  - `keep_missing_from_disk` surfaced in BOTH the JSON manifest and the txt summary.
- **Tool 3 — `restore.sh`**: replays `moves-*.jsonl` in reverse with SHA-256 verification.
  - `--all` to restore every entry in a move log; `--match GLOB` for selective restore (exact filename, directory glob, or fuzzy substring like `*Recidivism*`).
  - Per-restore JSONL log (`restores-*.jsonl`) so the full move/restore history is auditable.
  - SHA-256 verification before restoring defends against tampering or quarantine corruption (`--no-verify-sha` opts out).

### Changed
- Updated the design's plan-time `--limit` (single-page cap) to `--page-size` (per-page limit), since pagination is now mandatory.
- Default extension scope unchanged from design: `pdf,xlsx,xls,docx,doc,pptx,ppt,rtf,csv`.
- Confirmed live GraphQL endpoint uses snake_case timestamp fields (`created_at`, `updated_at`, `published_at`) alongside camelCase `fileURL`; reflected in both the query and the output schema.

### Documentation
- **README expanded substantially** with (a) a manager-facing "Why quarantining older orphan files is the wise move" subsection covering the ADA Title II April 2027 deadline, the disproportionate remediation cost of older documents, duplicate-and-stale-version cleanup, legal-exposure reduction, and reversibility; (b) an explicit "Crucially: nothing is deleted; nothing is lost" subsection emphasizing that quarantined files remain on the same server and same disk, accessible to staff via SSH, with one-command restore at any future date; (c) a full **"Production run record — 2026-05-11"** section with UTC timeline, stats table, before/after state transitions, the post-run bug discovery + fix narrative, HTTP-level verification table, and a catalog of audit artifacts committed under `logs/`.
- Lead paragraph reworded to emphasize *public* web reach (rather than just "web reach") and to state explicitly that quarantined files remain available to staff.

### Fixed
- **`normalize.js` now collapses repeated slashes in URL pathnames** (e.g. `/files/icjia/pdf//AtAGlance/...` → `icjia/pdf/AtAGlance/...`). Real filesystem paths never have `//`; preserving them produced a keep-set key that didn't match what `find` returned from disk, so one publication (`vol1_no3_Class4felonyoffenders.pdf`) was misclassified as orphan and moved to quarantine during the 2026-05-11 production run. Caught by post-execute verification, restored via `restore.sh --match`, two regression tests added (`tests 14`–`15`). The dry-run's `keep_missing_from_disk` check used `[ -f ... ]` which collapses `//` at the syscall level, hiding the inconsistency — that's a known limitation but acceptable now that normalization is correct at source.

### Verified
- Tool 1 unit tests: **18/18** pass (16 original + 2 regression tests for the double-slash bug).
- Tool 1 live smoke test against `https://agency.icjia-api.cloud/graphql`: 1,107 publications fetched across 3 pages; 927 kept (890 unique paths); 44 with null `fileURL`; 136 on non-archive hosts.
- Tool 2 & 3 sandboxed integration test against `/tmp/quarantine-test/` on the production server (ext4, GNU coreutils, real conditions but isolated dir): exact-match restore, fuzzy-match restore, and full-replay restore all succeed; SHA-256 of restored files byte-for-byte matches originals.
- **Production run 2026-05-11 15:52 UTC**: 7,478 files quarantined in 589 seconds, 0 errors at script level. Post-run integrity check found the 1 path-normalization bug above; corrected. Final state: 890/890 keep paths present on disk, 333/333 drone files intact, HTTP 200 on kept + drone paths, HTTP 404 on quarantined paths.
