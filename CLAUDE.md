# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

파일시스템 추적 관리 에이전트 — scans "data area" filesystems, assigns each file a
data value score from atime/mtime, and serves a Korean-language web dashboard.
Development happens on Windows; the runtime target is a Linux test server
(deployed by pushing to GitHub and cloning there — no local Python on the dev machine).

## Commands

```bash
pip install -r requirements.txt
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000   # serve dashboard at :8000
```

No test suite or linter is configured yet.

## Architecture

Request flow: `app/static/index.html` (vanilla JS dashboard) → FastAPI endpoints in
`app/main.py` → SQLite (`data/fs_agent.db`, gitignored).

- `app/config.py` — merges `config.json` over `DEFAULTS`. `resolve_scan_roots()` picks
  the platform default when `scan_roots` is empty: Windows `D:\` (data drive),
  Linux `glob("/shb*") + glob("/nbs*")`.
- `app/scoring.py` — the core scoring rule: exponential half-life decay of atime
  (weight 0.6, half-life 30d) and mtime (0.4, 90d), combined to a 0–100 score, then
  graded hot/warm/cold/stale (70/40/10 cutoffs). All parameters come from
  `config.json` `score`. Uses `max(atime, mtime)` because NTFS often has atime
  updates disabled.
- `app/scanner.py` — iterative `os.scandir` walk (no symlink following, permission
  errors skipped), batches upserts of 1000 rows, updates the `scans` row for live
  progress, and deletes rows for files no longer present under the scanned root.
  Runs in a daemon thread started by `POST /api/scan`; only one scan at a time
  (guarded by `_scan_lock` in main.py). Also accumulates per-directory totals
  (size/count/score, propagated to every ancestor) in memory and writes them to the
  `dirs` table at scan end — this backs the TreeSize-style lazy tree (`GET /api/tree`).
- `app/db.py` — one short-lived connection per operation (thread safety), WAL mode.

The dashboard polls `/api/scan/status` every 2s during a scan and re-renders
everything from the aggregate endpoints when it finishes. Charts are hand-built SVG;
dynamic strings go through `textContent` only (paths are untrusted). Colors follow
the dataviz reference palette (sequential blue ramp; ordinal blue steps for grades)
with light/dark via `prefers-color-scheme`.

## Conventions

- UI text and code comments are in Korean; keep new user-facing strings Korean.
- Score/grade thresholds and scan excludes belong in `config.json`, not hardcoded.
