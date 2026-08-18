# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

파일시스템 추적 관리 에이전트 — scans "data area" filesystems, assigns each file a
data value score from atime/mtime, and serves a Korean-language web dashboard.
Development happens on Windows (no local Python); the runtime target is
**air-gapped RHEL 8 servers (8.2/8.10)** whose default `python3` is **3.6.8**.
Deployed by pushing to GitHub, then cloning (test server) or `git archive` tarball
(closed network).

## Hard constraints

- **Python 3.6 compatible, standard library only.** No pip, no third-party
  packages, ever. No f-string `=`, no `X | None` unions, no `ThreadingHTTPServer`
  import (3.7+) — the threaded server is hand-rolled in `server.py`.
- UI text and code comments are in Korean; keep new user-facing strings Korean.
- Score/grade thresholds and scan excludes belong in `config.json`, not hardcoded.

## Commands

```bash
python3 server.py --host 0.0.0.0 --port 8000   # serve dashboard; no install step
```

No test suite or linter is configured yet.

## Architecture

Request flow: `app/static/index.html` (vanilla JS dashboard, single file) →
stdlib `http.server` routing in `server.py` → SQLite (`data/fs_agent.db`, gitignored).

- `server.py` — entrypoint. ThreadingMixIn HTTP server, manual URL routing,
  `api_*` functions port each endpoint; JSON errors as `{"detail": ...}` (the
  frontend reads `err.detail`). Holds the scan thread + `_scan_lock` (one scan
  at a time; `api_scan_status` reports "running" while the thread lives so
  multi-root sequential scans don't flicker to "done").
- `app/config.py` — merges `config.json` over `DEFAULTS`. `resolve_scan_roots()`
  picks the platform default when `scan_roots` is empty: Windows `D:\`, Linux
  `glob("/shb*") + glob("/nbs*")`. `linux_excludes` skips `/proc` (whose `kcore`
  reports 128TB), `/sys`, `/dev`, `/run`.
- `app/scoring.py` — the core rule: exponential half-life decay of atime
  (weight 0.6, half-life 30d) and mtime (0.4, 90d) → 0–100 score → grade
  hot/warm/cold/stale (70/40/10 cutoffs). Uses `max(atime, mtime)` because atime
  updates are often disabled. Korean display labels live only in the frontend
  (`GRADE_LABEL`); DB/API keep English keys.
- `app/scanner.py` — iterative `os.scandir` walk (no symlinks, permission errors
  skipped), 1000-row upsert batches, live progress via the `scans` row, deletes
  rows for vanished files. Accumulates per-directory totals (propagated to every
  ancestor) in memory → `dirs` table at scan end, which backs the lazy tree/treemap
  (`GET /api/tree`). `run_scan_many` purges data for roots no longer in the scan
  target set (removes leftovers from old manual scans).
- `app/db.py` — one short-lived connection per operation (thread safety), WAL mode,
  in-place migration for the `files.dir` column.

The dashboard polls `/api/scan/status` every 2s during a scan and re-renders from
aggregate endpoints when it finishes. Charts are hand-built SVG; the treemap is a
hand-rolled squarified layout; dynamic strings go through `textContent` only
(paths are untrusted). Colors follow the dataviz reference palette (sequential
blue ramp; ordinal blue steps for grades) with light/dark via
`prefers-color-scheme`.
