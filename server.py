"""표준 라이브러리 전용 HTTP 서버 — 폐쇄망 RHEL 8 (Python 3.6+) 대상.

외부 패키지 없이 http.server + sqlite3 만으로 API와 대시보드를 제공한다.
실행: python3 server.py [--host 0.0.0.0] [--port 8000]
"""
import argparse
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from socketserver import ThreadingMixIn
from urllib.parse import parse_qs, unquote, urlparse

from app import db, scanner
from app.config import load_config, resolve_db_path, resolve_scan_roots

CFG = load_config()
DB_PATH = resolve_db_path(CFG)
db.init_db(DB_PATH)
STATIC_DIR = Path(__file__).resolve().parent / "app" / "static"

_scan_lock = threading.Lock()
_scan_thread = None

GRADES = ("hot", "warm", "cold", "stale")
SORT_COLUMNS = {"score": "score", "size": "size", "atime": "atime", "mtime": "mtime"}
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
    return {"roots": resolve_scan_roots(CFG)}


def api_start_scan(root):
    """root 지정 시 해당 경로만, 미지정 시 모든 데이터 영역을 순차 스캔."""
    global _scan_thread
    roots = [root] if root else resolve_scan_roots(CFG)
    if not roots:
        return 400, {"detail": "스캔 루트가 없습니다. config.json의 scan_roots를 확인하세요."}
    missing = [r for r in roots if not Path(r).is_dir()]
    if missing:
        return 400, {"detail": "디렉터리가 아닙니다: " + ", ".join(missing)}
    with _scan_lock:
        if _scan_thread is not None and _scan_thread.is_alive():
            return 409, {"detail": "이미 스캔이 진행 중입니다."}
        _scan_thread = threading.Thread(
            target=scanner.run_scan_many, args=(roots, CFG, DB_PATH), daemon=True
        )
        _scan_thread.start()
    return 200, {"started": True, "roots": roots}


def api_scan_status():
    running = _scan_thread is not None and _scan_thread.is_alive()
    with db.connect(DB_PATH) as conn:
        row = conn.execute("SELECT * FROM scans ORDER BY id DESC LIMIT 1").fetchone()
    if not row:
        return {"status": "running" if running else "none"}
    result = dict(row)
    if running:
        result["status"] = "running"
    return result


def api_summary():
    with db.connect(DB_PATH) as conn:
        total = conn.execute(
            "SELECT COUNT(*) AS n, COALESCE(SUM(size),0) AS s, COALESCE(AVG(score),0) AS avg FROM files"
        ).fetchone()
        by_grade = conn.execute(
            "SELECT grade, COUNT(*) AS n, COALESCE(SUM(size),0) AS s FROM files GROUP BY grade"
        ).fetchall()
        last = conn.execute(
            "SELECT finished_at, root FROM scans WHERE status='done' ORDER BY id DESC LIMIT 1"
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
        "last_scan": dict(last) if last else None,
    }


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
        "file_count": count,
        "avg_score": round(row["score_sum"] / count, 1) if count else 0.0,
    }


def api_tree(q):
    path = q.get("path")
    files_limit = _int_param(q, "files_limit", 100, 0, 500)
    with db.connect(DB_PATH) as conn:
        if not path:
            rows = conn.execute(
                "SELECT * FROM dirs WHERE parent = '' ORDER BY size DESC"
            ).fetchall()
            return {"dirs": [_dir_row(r) for r in rows], "files": []}
        drows = conn.execute(
            "SELECT * FROM dirs WHERE parent = ? ORDER BY size DESC", (path,)
        ).fetchall()
        frows = conn.execute(
            """SELECT path, name, size, atime, mtime, score, grade
               FROM files WHERE dir = ? ORDER BY size DESC LIMIT ?""",
            (path, files_limit),
        ).fetchall()
    return {"dirs": [_dir_row(r) for r in drows], "files": [dict(r) for r in frows]}


def api_top_dirs(q):
    limit = _int_param(q, "limit", 10, 1, 50)
    with db.connect(DB_PATH) as conn:
        rows = conn.execute(
            """SELECT top_dir, COUNT(*) AS n, SUM(size) AS s, ROUND(AVG(score),1) AS avg_score
               FROM files GROUP BY top_dir ORDER BY s DESC LIMIT ?""",
            (limit,),
        ).fetchall()
    return {"dirs": [dict(r) for r in rows]}


def api_files(q):
    col = SORT_COLUMNS.get(q.get("sort", "score"), "score")
    direction = "DESC" if q.get("order", "asc").lower() == "desc" else "ASC"
    limit = _int_param(q, "limit", 50, 1, 500)
    where, params = [], []
    root = q.get("root")
    if root:
        where.append("(path LIKE ? OR dir = ?)")
        params.extend([os.path.join(root, "%"), root])
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
    with db.connect(DB_PATH) as conn:
        rows = conn.execute(
            """SELECT path, name, ext, size, atime, mtime, score, grade
               FROM files WHERE grade IN ('cold','stale')
               ORDER BY size DESC LIMIT ?""",
            (limit,),
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
            return self._send_json({"detail": "not found"}, 404)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            try:
                self._send_json({"detail": str(exc)}, 500)
            except OSError:
                pass


class ThreadingServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser(description="파일시스템 추적 관리 에이전트")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8000)
    args = ap.parse_args()
    srv = ThreadingServer((args.host, args.port), Handler)
    print("fs-agent serving on http://%s:%d" % (args.host, args.port))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
