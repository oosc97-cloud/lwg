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
- Score/grade thresholds, cleanup criteria and the scan include list belong in `config.json`, not hardcoded.
- `sqlite3.connect` needs a `str` on 3.6 (path-like support is 3.7+); `db.connect` converts.

## Commands

```bash
python3 server.py                 # serve dashboard on 0.0.0.0:15891 (config.json "port"); no install step
./restart.sh / ./stop.sh          # start/stop only this folder's agent (cwd-matched, never pkill -f)
./build-installer.sh [--release]    # dist/fs-agent-install-<ver>.sh: self-extracting installer for target servers;
                                  # --release also writes release/fs-agent-install.sh (committed so deploy.sh drops it on the test server)
                                  # (installer/install-header.sh + tar.gz of runtime files only; systemd unit not enabled at boot, keeps data/ & config.json)
master/build-installer.sh [--release] # dist/fs-master-install-<ver>.sh; --release also writes release/fs-master-install.sh
./build-installer.sh --master-edition [--release]  # master-linked agent: fs-agent-m, /opt/fs-agent-m, port 15892, --master required
cd master && ./restart.sh / ./stop.sh  # run the master (port 15900) from the repo
```

No test suite or linter is configured yet.

## Master edition (`master/`)

Separate component; `release/fs-agent-install.sh` (standalone, 15891) is left as built — do not
rebuild it for master work. Agents self-register: `app/master_link.py` runs only when
`config.json` `"master"` is set and POSTs `{agent_key, port, hostname}` to the master's
`/api/register` every `master_heartbeat_sec` (retry 30s); `agent_key` lives in
`data/agent_key`. The master builds the agent URL from the request's source IP + port and
matches by key (IP changes update the row). Agent exposes `GET /api/master` (link status,
used by the installer). The installer header is shared and templated (`@SERVICE@ @PREFIX@
@PORT@ @EDITION@ @INSTALLER@`); `--master-edition` builds `fs-agent-m` (15892, `--master`
required on first install) and both editions accept `--master`.
`master/server.py` (port 15900, own `config.json`, `data/fs_master.db`, systemd
`fs-master`, `/opt/fs-master`) pulls each agent's existing API (`scan/status`, `summary`,
`roots`, `tree`, `cleanup-candidates`) every `poll_interval_sec` (scanning agents every
`scan_poll_sec`, status only) and keeps the last result on failure. `/agent/<id>/` proxies
the agent dashboard by rewriting its `"/api/` fetch paths to `/agent/<id>/api/` — keep agent
frontend API calls as quoted absolute `/api/...` strings. POST pass-through is limited to
scan, scan/cancel, reset (`allow_agent_control`).

## Architecture

Request flow: `app/static/index.html` (vanilla JS dashboard, single file) →
stdlib `http.server` routing in `server.py` → SQLite (`data/fs_agent.db`, gitignored).

- `server.py` — entrypoint. Refuses to start (exit 1) if the port already has a
  LISTENer or `fs-agent.pid` points at a live instance; `db.init_db` runs only after
  those checks so a second launch can't flip the live instance's running scan to error.
  Windows binds with `SO_EXCLUSIVEADDRUSE` (its `SO_REUSEADDR` can steal ports). ThreadingMixIn HTTP server, manual URL routing,
  `api_*` functions port each endpoint; JSON errors as `{"detail": ...}` (the
  frontend reads `err.detail`). Holds the scan thread + `_scan_lock` (one scan
  at a time; `api_scan_status` reports "running" while the thread lives so
  multi-root sequential scans don't flicker to "done").
- `app/config.py` — merges `config.json` over `DEFAULTS`. Scan scope is include-only:
  `scan_include` {linux: ["/shb*", "/nbs*"], windows: ["D:\\"]} globbed by
  `resolve_scan_roots()`; nothing outside is scanned (no exclude lists). No match →
  scan refused with a message; an explicit API root must lie inside those roots.
- `app/scoring.py` — the core rule: exponential half-life decay of atime
  (weight 0.6, half-life 30d) and mtime (0.4, 90d) → 0–100 score → grade
  hot/warm/cold/stale (70/40/10 cutoffs). Uses `max(atime, mtime)` because atime
  updates are often disabled. Cutoffs come from `config.json` `grades`. Korean display labels live only in the frontend
  (`GRADE_LABEL`); DB/API keep English keys.
- `app/scanner.py` — iterative `os.scandir` walk (no symlinks, permission errors
  skipped), 1000-row upsert batches, live progress via the `scans` row, deletes
  rows for vanished files. Accumulates per-directory totals (propagated to every
  ancestor) in memory → `dirs` table at scan end, which backs the lazy tree/treemap
  (`GET /api/tree`). `run_scan_many` purges data for roots no longer in the scan
  target set (removes leftovers from old manual scans). A shared `threading.Event`
  cancels between directories: status `cancelled`, previous dirs/files kept (a
  first-ever scan of that root drops its partial rows). On `done`, dirs up to
  `history.depth` are copied to `scan_history`, pruned to `history.keep_scans`
  per root — groundwork for phase-2 snapshot diffs (`GET /api/history`).
- `app/hostinfo.py` — hostname + primary non-loopback IP (UDP route trick →
  `gethostbyname_ex` → `hostname -I`), stored on each `scans` row at scan start.
- `app/db.py` — one short-lived connection per operation (thread safety), WAL mode,
  in-place migration for the `files.dir` column.

The dashboard is a TreeSize-style two-pane explorer: lazy folder tree on the
left (`/api/tree?files_limit=0`), tabs on the right that all scope to the
selected folder (`path`/`root` params; `_under()` in `server.py` builds the
`dir = ? OR dir LIKE ? ESCAPE` filter). `dirs` also stores `dir_count`
(recursive), `alloc_size` (`st_blocks*512`), `last_mtime`/`last_atime`.

The dashboard polls `/api/scan/status` every 2s during a scan and re-renders from
aggregate endpoints when it finishes. Charts are hand-built SVG; the treemap is a
hand-rolled squarified layout; dynamic strings go through `textContent` only
(paths are untrusted). Colors follow the dataviz reference palette (sequential
blue ramp; ordinal blue steps for grades) with light/dark via
`prefers-color-scheme`.
