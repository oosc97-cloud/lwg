"""표준 라이브러리 전용 HTTP 서버 — 폐쇄망 RHEL 8 (Python 3.6+) 대상.

외부 패키지 없이 http.server + sqlite3 만으로 API와 대시보드를 제공한다.
실행: python3 server.py [--host 0.0.0.0] [--port 15891]
"""
import argparse
import errno
import json
import os
import signal
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from socketserver import ThreadingMixIn
from urllib.parse import parse_qs, unquote, urlparse

from app import db, master_link, scanner
from app.config import load_config, resolve_db_path, resolve_scan_roots, scan_include_patterns

CFG = load_config()
DB_PATH = resolve_db_path(CFG)
# db.init_db는 main()에서 중복 실행 검사 뒤에 호출 (이미 떠 있는 인스턴스의 '진행 중' 스캔을 망가뜨리지 않게)
STATIC_DIR = Path(__file__).resolve().parent / "app" / "static"

_scan_lock = threading.Lock()
_scan_thread = None
_cancel_event = threading.Event()

GRADES = ("hot", "warm", "cold", "stale")
SORT_COLUMNS = {"score": "score", "size": "size", "atime": "atime", "mtime": "mtime", "name": "name", "path": "path"}
DIR_SORT_COLUMNS = {"size": "size", "cleanup": "cleanup_size", "files": "file_count"}
CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
}


def _int_param(q, key, default, lo, hi):
    try:
        return max(lo, min(hi, int(q.get(key, default))))
    except (TypeError, ValueError):
        return default


# ---------- API 구현 ----------

def api_roots():
    return {"roots": resolve_scan_roots(CFG), "include": scan_include_patterns(CFG)}


def _no_roots_message():
    pats = ", ".join(scan_include_patterns(CFG)) or "(없음)"
    return ("스캔 대상 폴더가 없습니다. 이 서버에 포함 대상(%s)에 해당하는 폴더가 없어 아무것도 스캔하지 않습니다. "
            "config.json의 scan_include를 확인하세요." % pats)


def _within(path, roots):
    p = os.path.normcase(os.path.abspath(path))
    for r in roots:
        r = os.path.normcase(os.path.abspath(r))
        if p == r or p.startswith(os.path.join(r, "")):
            return True
    return False


def api_start_scan(root):
    """root 지정 시 해당 경로만(포함 대상 안이어야 함), 미지정 시 포함 대상 전체를 순차 스캔."""
    global _scan_thread
    allowed = resolve_scan_roots(CFG)
    if not allowed:
        return 400, {"detail": _no_roots_message()}
    if root and not _within(root, allowed):
        return 400, {"detail": "스캔 대상(%s) 밖의 경로는 스캔하지 않습니다: %s"
                     % (", ".join(scan_include_patterns(CFG)), root)}
    roots = [root] if root else allowed
    missing = [r for r in roots if not Path(r).is_dir()]
    if missing:
        return 400, {"detail": "디렉터리가 아닙니다: " + ", ".join(missing)}
    with _scan_lock:
        if _scan_thread is not None and _scan_thread.is_alive():
            return 409, {"detail": "이미 스캔이 진행 중입니다."}
        _cancel_event.clear()
        _scan_thread = threading.Thread(
            target=scanner.run_scan_many, args=(roots, CFG, DB_PATH, _cancel_event), daemon=True
        )
        _scan_thread.start()
    return 200, {"started": True, "roots": roots}


def api_reset():
    """저장된 스캔 결과 전체 삭제 (처음 설치한 상태로). 스캔 중에는 거부."""
    with _scan_lock:
        if _scan_thread is not None and _scan_thread.is_alive():
            return 409, {"detail": "스캔 중에는 초기화할 수 없습니다. 먼저 스캔을 취소하세요."}
        with db.connect(DB_PATH) as conn:
            for table in ("files", "dirs", "scan_history", "scans"):
                conn.execute("DELETE FROM " + table)
        conn = db.connect(DB_PATH)
        try:
            conn.isolation_level = None  # VACUUM은 트랜잭션 밖에서만 가능
            conn.execute("VACUUM")
        finally:
            conn.close()
    return 200, {"reset": True}


def _scan_running():
    return _scan_thread is not None and _scan_thread.is_alive()


def api_cancel_scan():
    if not _scan_running():
        return 409, {"detail": "진행 중인 스캔이 없습니다."}
    _cancel_event.set()
    return 200, {"cancelling": True}


def api_scan_status():
    running = _scan_running()
    with db.connect(DB_PATH) as conn:
        row = conn.execute("SELECT * FROM scans ORDER BY id DESC LIMIT 1").fetchone()
    if not row:
        return {"status": "running" if running else "none"}
    result = dict(row)
    if running:
        result["status"] = "cancelling" if _cancel_event.is_set() else "running"
    return result


def api_summary():
    with db.connect(DB_PATH) as conn:
        total = conn.execute(
            "SELECT COUNT(*) AS n, COALESCE(SUM(size),0) AS s, COALESCE(AVG(score),0) AS avg FROM files"
        ).fetchone()
        by_grade = conn.execute(
            "SELECT grade, COUNT(*) AS n, COALESCE(SUM(size),0) AS s FROM files GROUP BY grade"
        ).fetchall()
        cleanup = conn.execute(
            "SELECT COUNT(*) AS n, COALESCE(SUM(size),0) AS s FROM files WHERE {}".format(
                _cleanup_where()[0]
            ),
            _cleanup_where()[1],
        ).fetchone()
        last = conn.execute(
            "SELECT finished_at, root, hostname, ip FROM scans WHERE status='done' ORDER BY id DESC LIMIT 1"
        ).fetchone()
    grades = {}
    for g in GRADES:
        grades[g] = {"count": 0, "size": 0}
    for row in by_grade:
        grades[row["grade"]] = {"count": row["n"], "size": row["s"]}
    return {
        "file_count": total["n"],
        "total_size": total["s"],
        "avg_score": round(total["avg"], 1),
        "grades": grades,
        "thresholds": CFG["grades"],
        "cleanup": {
            "grades": CFG["cleanup"]["grades"],
            "min_size_mb": CFG["cleanup"]["min_size_mb"],
            "count": cleanup["n"],
            "size": cleanup["s"],
        },
        "last_scan": dict(last) if last else None,
    }


def _cleanup_where():
    """정리 후보 조건: config.json cleanup.grades 등급 + cleanup.min_size_mb 이상."""
    grades = [g for g in CFG["cleanup"]["grades"] if g in GRADES] or ["stale"]
    min_size = int(float(CFG["cleanup"]["min_size_mb"]) * 1024 * 1024)
    sql = "grade IN ({}) AND size >= ?".format(",".join("?" * len(grades)))
    return sql, tuple(grades) + (min_size,)


def api_distribution():
    with db.connect(DB_PATH) as conn:
        rows = conn.execute(
            """SELECT MIN(CAST(score/10 AS INTEGER), 9) AS bucket,
                      COUNT(*) AS n, COALESCE(SUM(size),0) AS s
               FROM files GROUP BY bucket"""
        ).fetchall()
    buckets = [
        {"range": "%d-%d" % (i * 10, i * 10 + 10), "count": 0, "size": 0} for i in range(10)
    ]
    for row in rows:
        buckets[row["bucket"]]["count"] = row["n"]
        buckets[row["bucket"]]["size"] = row["s"]
    return {"buckets": buckets}


def _dir_row(row):
    count = row["file_count"]
    return {
        "path": row["path"],
        "name": row["name"],
        "size": row["size"],
        "alloc_size": row["alloc_size"],
        "file_count": count,
        "dir_count": row["dir_count"],
        "last_mtime": row["last_mtime"],
        "last_atime": row["last_atime"],
        "cleanup_size": row["cleanup_size"],
        "avg_score": round(row["score_sum"] / count, 1) if count else 0.0,
    }


def _like_escape(s):
    return s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _under(path):
    """files.dir 기준으로 path 폴더와 그 하위 전체를 고르는 조건."""
    prefix = os.path.join(path, "")
    return "(dir = ? OR dir LIKE ? ESCAPE '\\')", [path, _like_escape(prefix) + "%"]


def api_tree(q):
    path = q.get("path")
    files_limit = _int_param(q, "files_limit", 100, 0, 500)
    with db.connect(DB_PATH) as conn:
        if not path:
            rows = conn.execute(
                "SELECT * FROM dirs WHERE parent = '' ORDER BY size DESC"
            ).fetchall()
            return {"dirs": [_dir_row(r) for r in rows], "files": []}
        node = conn.execute("SELECT * FROM dirs WHERE path = ?", (path,)).fetchone()
        drows = conn.execute(
            "SELECT * FROM dirs WHERE parent = ? ORDER BY size DESC", (path,)
        ).fetchall()
        frows = conn.execute(
            """SELECT path, name, ext, size, atime, mtime, score, grade
               FROM files WHERE dir = ? ORDER BY size DESC LIMIT ?""",
            (path, files_limit),
        ).fetchall()
        own = conn.execute(
            "SELECT COUNT(*) AS n, COALESCE(SUM(size),0) AS s FROM files WHERE dir = ?", (path,)
        ).fetchone()
    return {
        "node": _dir_row(node) if node else None,
        "dirs": [_dir_row(r) for r in drows],
        "files": [dict(r) for r in frows],
        "own_files": {"count": own["n"], "size": own["s"]},
    }


def api_top_dirs(q):
    """디렉터리 순위. depth: 루트 기준 깊이(1=루트 바로 아래), sort: size|cleanup|files."""
    limit = _int_param(q, "limit", 20, 1, 200)
    depth = _int_param(q, "depth", 1, 1, 50)
    col = DIR_SORT_COLUMNS.get(q.get("sort", "size"), "size")
    with db.connect(DB_PATH) as conn:
        rows = conn.execute(
            "SELECT * FROM dirs WHERE depth = ? ORDER BY {} DESC LIMIT ?".format(col),
            (depth, limit),
        ).fetchall()
    out = []
    for r in rows:
        d = _dir_row(r)
        d["cleanup_size"] = r["cleanup_size"]
        out.append(d)
    return {"dirs": out}


def api_extensions(q):
    """확장자별 파일 수·용량·정리 후보 용량 (용량 큰 순)."""
    limit = _int_param(q, "limit", 10, 1, 200)
    where, params = _cleanup_where()
    scope, scope_args = ("1=1", [])
    if q.get("path"):
        scope, scope_args = _under(q["path"])
    with db.connect(DB_PATH) as conn:
        total = conn.execute(
            "SELECT COALESCE(SUM(size),0) AS s FROM files WHERE " + scope, scope_args
        ).fetchone()["s"]
        rows = conn.execute(
            """SELECT ext, COUNT(*) AS n, COALESCE(SUM(size),0) AS s,
                      COALESCE(SUM(CASE WHEN {} THEN size ELSE 0 END),0) AS c,
                      ROUND(AVG(score),1) AS avg_score
               FROM files WHERE {} GROUP BY ext ORDER BY s DESC LIMIT ?""".format(where, scope),
            tuple(params) + tuple(scope_args) + (limit,),
        ).fetchall()
    return {
        "total_size": total,
        "extensions": [
            {"ext": r["ext"], "file_count": r["n"], "size": r["s"],
             "cleanup_size": r["c"], "avg_score": r["avg_score"]}
            for r in rows
        ],
    }


AGE_BUCKETS = [(30, "1개월 이내"), (90, "1~3개월"), (180, "3~6개월"), (365, "6개월~1년"),
               (730, "1~2년"), (1095, "2~3년"), (None, "3년 초과")]


def api_age(q):
    """파일 나이 분포 (TreeSize 'Age of Files'). by=mtime(수정, 기본)|atime(접근)."""
    col = "MAX(atime, mtime)" if q.get("by") == "atime" else "mtime"
    scope, scope_args = ("1=1", [])
    if q.get("path"):
        scope, scope_args = _under(q["path"])
    cases = " ".join(
        "WHEN age < {} THEN {}".format(days, i) for i, (days, _) in enumerate(AGE_BUCKETS) if days
    )
    sql = """SELECT CASE {} ELSE {} END AS b, COUNT(*) AS n, COALESCE(SUM(size),0) AS s
             FROM (SELECT size, (? - {}) / 86400.0 AS age FROM files WHERE {})
             GROUP BY b""".format(cases, len(AGE_BUCKETS) - 1, col, scope)
    with db.connect(DB_PATH) as conn:
        rows = conn.execute(sql, [time.time()] + scope_args).fetchall()
    buckets = [{"label": label, "file_count": 0, "size": 0} for _, label in AGE_BUCKETS]
    for r in rows:
        buckets[r["b"]]["file_count"] = r["n"]
        buckets[r["b"]]["size"] = r["s"]
    return {"by": "atime" if q.get("by") == "atime" else "mtime", "buckets": buckets}


def api_changes(q):
    """루트별 최근 완료 스캔과 직전 완료 스캔의 디렉터리 집계 비교 (scan_history 기반)."""
    limit = _int_param(q, "limit", 10, 1, 100)
    roots, dirs = [], []
    with db.connect(DB_PATH) as conn:
        root_rows = conn.execute(
            """SELECT DISTINCT s.root FROM scans s
               WHERE s.status = 'done' AND EXISTS (SELECT 1 FROM scan_history h WHERE h.scan_id = s.id)"""
        ).fetchall()
        for rr in root_rows:
            scans = conn.execute(
                """SELECT id, finished_at FROM scans s WHERE root = ? AND status = 'done'
                   AND EXISTS (SELECT 1 FROM scan_history h WHERE h.scan_id = s.id)
                   ORDER BY id DESC LIMIT 2""",
                (rr["root"],),
            ).fetchall()
            if len(scans) < 2:
                continue
            cur, prev = scans[0], scans[1]
            rows = {}
            for which, scan in (("cur", cur), ("prev", prev)):
                for h in conn.execute(
                    "SELECT path, depth, size, file_count, cleanup_size FROM scan_history WHERE scan_id = ?",
                    (scan["id"],),
                ):
                    rows.setdefault(h["path"], {"depth": h["depth"]})[which] = h
            for path, r in rows.items():
                c, p = r.get("cur"), r.get("prev")
                item = {
                    "path": path,
                    "size": c["size"] if c else 0,
                    "size_delta": (c["size"] if c else 0) - (p["size"] if p else 0),
                    "file_delta": (c["file_count"] if c else 0) - (p["file_count"] if p else 0),
                    "cleanup_delta": (c["cleanup_size"] if c else 0) - (p["cleanup_size"] if p else 0),
                    "state": "new" if not p else ("removed" if not c else "changed"),
                }
                if r["depth"] == 0:
                    item.update({
                        "root": rr["root"],
                        "prev_finished_at": prev["finished_at"],
                        "cur_finished_at": cur["finished_at"],
                    })
                    roots.append(item)
                elif r["depth"] == 1 and (item["size_delta"] or item["file_delta"]):
                    dirs.append(item)
    dirs.sort(key=lambda d: abs(d["size_delta"]), reverse=True)
    return {"roots": roots, "dirs": dirs[:limit]}


def api_history(q):
    """스캔별 디렉터리 집계 이력. path 미지정 시 각 스캔 루트."""
    path = q.get("path")
    with db.connect(DB_PATH) as conn:
        if path:
            rows = conn.execute(
                """SELECT h.*, s.finished_at FROM scan_history h JOIN scans s ON s.id = h.scan_id
                   WHERE h.path = ? ORDER BY h.scan_id""",
                (path,),
            ).fetchall()
        else:
            rows = conn.execute(
                """SELECT h.*, s.finished_at FROM scan_history h JOIN scans s ON s.id = h.scan_id
                   WHERE h.depth = 0 ORDER BY h.path, h.scan_id"""
            ).fetchall()
    out = []
    for r in rows:
        count = r["file_count"]
        out.append({
            "scan_id": r["scan_id"],
            "finished_at": r["finished_at"],
            "path": r["path"],
            "size": r["size"],
            "file_count": count,
            "avg_score": round(r["score_sum"] / count, 1) if count else 0.0,
            "cleanup_size": r["cleanup_size"],
        })
    return {"history": out}


def api_files(q):
    col = SORT_COLUMNS.get(q.get("sort", "score"), "score")
    direction = "DESC" if q.get("order", "asc").lower() == "desc" else "ASC"
    limit = _int_param(q, "limit", 50, 1, 500)
    where, params = [], []
    root = q.get("root")
    if root:
        cond, args = _under(root)
        where.append(cond)
        params.extend(args)
    if q.get("grade") in GRADES:
        where.append("grade = ?")
        params.append(q["grade"])
    if q.get("q"):
        where.append("path LIKE ?")
        params.append("%" + q["q"] + "%")
    where_sql = ("WHERE " + " AND ".join(where)) if where else ""
    with db.connect(DB_PATH) as conn:
        rows = conn.execute(
            """SELECT path, name, ext, size, atime, mtime, score, grade
               FROM files {} ORDER BY {} {}, size DESC LIMIT ?""".format(
                where_sql, col, direction
            ),
            tuple(params) + (limit,),
        ).fetchall()
    return {"files": [dict(r) for r in rows]}


def api_cleanup_candidates(q):
    limit = _int_param(q, "limit", 50, 1, 500)
    where, params = _cleanup_where()
    with db.connect(DB_PATH) as conn:
        rows = conn.execute(
            """SELECT path, name, ext, size, atime, mtime, score, grade
               FROM files WHERE {}
               ORDER BY size DESC LIMIT ?""".format(where),
            params + (limit,),
        ).fetchall()
    return {"files": [dict(r) for r in rows]}


# ---------- HTTP 핸들러 ----------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "fs-agent"

    def log_message(self, fmt, *args):  # 요청 로그 소음 억제
        pass

    def _send_json(self, obj, status=200):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_file(self, path):
        data = path.read_bytes()
        self.send_response(200)
        self.send_header(
            "Content-Type", CONTENT_TYPES.get(path.suffix.lower(), "application/octet-stream")
        )
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        route = parsed.path
        q = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        try:
            # web_ui=false (마스터 연동판): 웹 화면 없음. 마스터가 쓰는 API만 응답
            if (route == "/" or route.startswith("/static/")) and not CFG.get("web_ui", True):
                return self._send_json({"detail": "not found"}, 404)
            if route == "/":
                return self._send_file(STATIC_DIR / "index.html")
            if route.startswith("/static/"):
                rel = unquote(route[len("/static/"):])
                target = (STATIC_DIR / rel).resolve()
                if not str(target).startswith(str(STATIC_DIR.resolve())) or not target.is_file():
                    return self._send_json({"detail": "not found"}, 404)
                return self._send_file(target)
            if route == "/api/roots":
                return self._send_json(api_roots())
            if route == "/api/scan/status":
                return self._send_json(api_scan_status())
            if route == "/api/summary":
                return self._send_json(api_summary())
            if route == "/api/distribution":
                return self._send_json(api_distribution())
            if route == "/api/tree":
                return self._send_json(api_tree(q))
            if route == "/api/top-dirs":
                return self._send_json(api_top_dirs(q))
            if route == "/api/files":
                return self._send_json(api_files(q))
            if route == "/api/cleanup-candidates":
                return self._send_json(api_cleanup_candidates(q))
            if route == "/api/extensions":
                return self._send_json(api_extensions(q))
            if route == "/api/age":
                return self._send_json(api_age(q))
            if route == "/api/changes":
                return self._send_json(api_changes(q))
            if route == "/api/history":
                return self._send_json(api_history(q))
            if route == "/api/master":
                return self._send_json(master_link.status())
            return self._send_json({"detail": "not found"}, 404)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            try:
                self._send_json({"detail": str(exc)}, 500)
            except OSError:
                pass

    def do_POST(self):
        parsed = urlparse(self.path)
        try:
            if parsed.path == "/api/scan":
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length) if length else b""
                try:
                    body = json.loads(raw.decode("utf-8")) if raw else {}
                except ValueError:
                    body = {}
                status, payload = api_start_scan(body.get("root"))
                return self._send_json(payload, status)
            if parsed.path == "/api/reset":
                status, payload = api_reset()
                return self._send_json(payload, status)
            if parsed.path == "/api/scan/cancel":
                status, payload = api_cancel_scan()
                return self._send_json(payload, status)
            return self._send_json({"detail": "not found"}, 404)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            try:
                self._send_json({"detail": str(exc)}, 500)
            except OSError:
                pass


PID_FILE = Path(__file__).resolve().parent / "fs-agent.pid"


class ThreadingServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    # Linux의 SO_REUSEADDR는 TIME_WAIT 포트 재사용만 허용하고, LISTEN 중인 포트는 bind 자체가 실패한다.
    # Windows에서는 SO_REUSEADDR가 남의 LISTEN 포트를 가로챌 수 있으므로 끄고 독점 바인딩을 쓴다.
    allow_reuse_address = os.name != "nt"

    def server_bind(self):
        if os.name == "nt" and hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        HTTPServer.server_bind(self)


def _fail(msg):
    sys.stderr.write("[fs-agent] 시작 중단: " + msg + "\n")
    sys.exit(1)


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
    except OSError as e:
        return e.errno == errno.EPERM
    return True


def _check_pid_file():
    """같은 폴더의 에이전트가 이미 실행 중이면 중단 (pid 파일 기준)."""
    try:
        pid = int(PID_FILE.read_text().strip())
    except (OSError, ValueError):
        return
    if pid != os.getpid() and _pid_alive(pid):
        _fail("이 폴더의 fs-agent가 이미 실행 중입니다 (PID %d). 재기동은 restart.sh (설치판은 systemctl restart fs-agent)를 사용하세요." % pid)


def _port_in_use(host, port):
    """해당 포트에 LISTEN 중인 프로세스가 있는지 접속 시도로 확인."""
    # 0.0.0.0 바인딩이면 루프백으로 확인 (특정 IP에만 LISTEN 중인 경우는 아래 bind 실패로 걸러짐)
    targets = ["127.0.0.1"] if host in ("", "0.0.0.0", "::") else [host]
    for target in targets:
        try:
            with socket.create_connection((target, port), timeout=1):
                return True
        except OSError:
            continue
    return False


def _remove_pid_file():
    try:
        if PID_FILE.read_text().strip() == str(os.getpid()):
            PID_FILE.unlink()
    except OSError:
        pass


def main():
    ap = argparse.ArgumentParser(description="파일시스템 추적 관리 에이전트")
    ap.add_argument("--host", default=CFG.get("host", "0.0.0.0"))
    ap.add_argument("--port", type=int, default=int(CFG.get("port", 15891)))
    args = ap.parse_args()

    in_use_msg = ("%d 포트를 이미 다른 프로세스가 사용(LISTEN) 중입니다. 기존 프로세스는 건드리지 않습니다. "
                  "'ss -ltnp | grep :%d'로 사용 중인 프로세스를 확인하거나, "
                  "--port <다른 포트> 또는 config.json의 \"port\"로 다른 포트를 지정하세요." % (args.port, args.port))
    _check_pid_file()
    if _port_in_use(args.host, args.port):
        _fail(in_use_msg)
    try:
        srv = ThreadingServer((args.host, args.port), Handler)
    except OSError as e:
        if e.errno in (errno.EADDRINUSE, getattr(errno, "WSAEADDRINUSE", -1), errno.EACCES):
            _fail(in_use_msg if e.errno != errno.EACCES else "%d 포트에 바인딩할 권한이 없습니다: %s" % (args.port, e))
        raise

    db.init_db(DB_PATH)
    PID_FILE.write_text(str(os.getpid()))
    # kill(SIGTERM)로 종료해도 pid 파일을 정리하도록
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    master_link.start(CFG, args.port, DB_PATH.parent)
    print("fs-agent serving on http://%s:%d (PID %d)" % (args.host, args.port, os.getpid()))
    sys.stdout.flush()
    try:
        srv.serve_forever()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        srv.server_close()
        _remove_pid_file()


if __name__ == "__main__":
    main()
