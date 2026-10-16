"""fs-master — 여러 서버의 fs-agent를 한 화면에서 보는 통합 관리 서버 (표준 라이브러리 전용, Python 3.6+).

에이전트는 고치지 않는다. 마스터가 등록된 각 에이전트의 기존 HTTP API를 주기적으로 읽어(pull)
요약을 저장하고, 통합 화면과 서버별 상세 화면(에이전트 대시보드 중계)을 제공한다.
실행: python3 server.py [--host 0.0.0.0] [--port 15900]
"""
import argparse
import errno
import html
import json
import os
import re
import signal
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from socketserver import ThreadingMixIn
from urllib.parse import parse_qs, urlparse

import master_db as mdb

BASE_DIR = Path(__file__).resolve().parent
CONFIG_PATH = BASE_DIR / "config.json"
STATIC_DIR = BASE_DIR / "static"
PID_FILE = BASE_DIR / "fs-master.pid"

DEFAULTS = {
    "port": 15900,                 # 마스터 웹 화면 포트
    "agent_default_port": 15891,   # 주소에 포트를 안 적으면 붙일 에이전트 포트
    "poll_interval_sec": 300,      # 에이전트 요약 수집 주기
    "scan_poll_sec": 10,           # 스캔 중인 에이전트는 이 간격으로 진행 상황만 수집
    "request_timeout_sec": 10,     # 에이전트 요청 제한 시간
    "max_parallel": 8,             # 동시에 수집할 에이전트 수
    "cleanup_top_per_agent": 100,  # 에이전트별로 가져올 정리 후보(큰 순) 개수
    "allow_agent_control": True,   # 마스터 화면에서 에이전트 스캔 시작/취소/초기화 허용
    "db_path": "data/fs_master.db",
}


def load_config():
    cfg = dict(DEFAULTS)
    if CONFIG_PATH.exists():
        with open(str(CONFIG_PATH), encoding="utf-8") as f:
            cfg.update(json.load(f))
    return cfg


CFG = load_config()
DB_PATH = Path(CFG["db_path"])
if not DB_PATH.is_absolute():
    DB_PATH = BASE_DIR / DB_PATH
DB_PATH.parent.mkdir(parents=True, exist_ok=True)

# 내부망 에이전트에 직접 붙는다 (환경변수 http_proxy 무시)
_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

# 마스터 화면에서 에이전트로 넘겨도 되는 POST (에이전트 대시보드의 버튼과 같은 것만)
AGENT_POST_PATHS = ("scan", "scan/cancel", "reset")
CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
}


class AgentError(Exception):
    pass


def normalize_url(raw):
    """'10.0.0.5', '10.0.0.5:15891', 'http://host:15891/' → 'http://host:port'."""
    s = (raw or "").strip()
    if not s:
        raise ValueError("주소를 입력하세요.")
    if "://" not in s:
        s = "http://" + s
    u = urlparse(s)
    if u.scheme not in ("http", "https") or not u.hostname:
        raise ValueError("주소 형식이 올바르지 않습니다: %s" % raw)
    try:
        port = u.port or int(CFG["agent_default_port"])
    except ValueError:
        raise ValueError("포트가 올바르지 않습니다: %s" % raw)
    host = u.hostname
    if ":" in host:  # IPv6
        host = "[" + host + "]"
    return "%s://%s:%d" % (u.scheme, host, port)


def agent_request(base_url, path, method="GET", body=None, timeout=None):
    """에이전트에 요청해 (상태코드, 본문 bytes, Content-Type)을 돌려준다. 연결 실패는 AgentError."""
    req = urllib.request.Request(base_url + path, data=body, method=method)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with _opener.open(req, timeout=timeout or float(CFG["request_timeout_sec"])) as r:
            return r.status, r.read(), r.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers.get("Content-Type", "")
    except (urllib.error.URLError, socket.timeout, OSError) as e:
        reason = getattr(e, "reason", e)
        raise AgentError("에이전트에 연결할 수 없습니다 (%s): %s" % (base_url, reason))


def agent_json(base_url, path):
    status, data, _ = agent_request(base_url, path)
    try:
        obj = json.loads(data.decode("utf-8"))
    except ValueError:
        raise AgentError("fs-agent 응답이 아닙니다 (%s%s, HTTP %d)" % (base_url, path, status))
    if status != 200:
        raise AgentError("에이전트 오류 (%s, HTTP %d): %s" % (path, status, obj.get("detail", "")))
    return obj


# ---------- 수집 ----------

class Poller(object):
    """백그라운드 수집기. 2초마다 수집할 때가 된 에이전트를 골라 스레드 풀에서 수집한다."""

    def __init__(self):
        self.pool = ThreadPoolExecutor(max_workers=max(1, int(CFG["max_parallel"])))
        self.lock = threading.Lock()
        self.inflight = set()
        self.last_full = {}      # agent_id → 마지막 전체 수집 시각 (성공·실패 무관)
        self.last_status = {}    # agent_id → 마지막 상태 수집 시각
        self.scanning = set()    # 스캔 중인 agent_id
        self.forced = set()      # 즉시 전체 수집 요청
        self.wake = threading.Event()

    def start(self):
        t = threading.Thread(target=self._loop, daemon=True)
        t.start()

    def force(self, agent_id=None):
        with self.lock:
            if agent_id is None:
                self.forced.update(a["id"] for a in mdb.list_agents(DB_PATH))
            else:
                self.forced.add(agent_id)
        self.wake.set()

    def _loop(self):
        while True:
            try:
                self._tick()
            except Exception as exc:  # 수집기 자체는 죽지 않게
                sys.stderr.write("[fs-master] 수집 오류: %s\n" % exc)
            self.wake.wait(2)
            self.wake.clear()

    def _tick(self):
        now = time.time()
        interval = max(10, float(CFG["poll_interval_sec"]))
        scan_iv = max(2, float(CFG["scan_poll_sec"]))
        for a in mdb.list_agents(DB_PATH):
            aid = a["id"]
            with self.lock:
                if aid in self.inflight:
                    continue
                if not a["enabled"]:
                    self.forced.discard(aid)
                    continue
                full = aid in self.forced or now - self.last_full.get(aid, 0) >= interval
                quick = aid in self.scanning and now - self.last_status.get(aid, 0) >= scan_iv
                if not (full or quick):
                    continue
                self.forced.discard(aid)
                self.inflight.add(aid)
            self.pool.submit(self._poll, a, full)

    def _poll(self, agent, full):
        aid, url = agent["id"], agent["url"]
        try:
            now = time.time()
            scan = agent_json(url, "/api/scan/status")
            running = scan.get("status") in ("running", "cancelling")
            with self.lock:
                was_running = aid in self.scanning
                self.last_status[aid] = now
                (self.scanning.add if running else self.scanning.discard)(aid)
            # 스캔이 막 끝났으면 바로 전체 수집
            if full or (was_running and not running):
                data = {
                    "scan": scan,
                    "summary": agent_json(url, "/api/summary"),
                    "roots": agent_json(url, "/api/roots"),
                    "tree": agent_json(url, "/api/tree").get("dirs", []),
                    "cleanup": agent_json(
                        url, "/api/cleanup-candidates?limit=%d" % int(CFG["cleanup_top_per_agent"])
                    ).get("files", []),
                }
                with self.lock:
                    self.last_full[aid] = now
                mdb.save_full(DB_PATH, aid, data, now)
            else:
                mdb.save_scan(DB_PATH, aid, scan, now)
        except AgentError as exc:
            with self.lock:
                self.last_full[aid] = time.time()
                self.scanning.discard(aid)
            mdb.save_error(DB_PATH, aid, str(exc), time.time())
        except Exception as exc:
            with self.lock:
                self.last_full[aid] = time.time()
            mdb.save_error(DB_PATH, aid, "수집 실패: %s" % exc, time.time())
        finally:
            with self.lock:
                self.inflight.discard(aid)


POLLER = Poller()


# ---------- API ----------

def _agent_view(a):
    out = {k: a[k] for k in ("id", "name", "url", "enabled", "status", "error",
                             "added_at", "last_poll_at", "last_ok_at", "hostname", "ip")}
    for key in ("scan", "summary", "roots", "tree"):
        out[key] = json.loads(a[key]) if a[key] else None
    return out


def api_agents():
    return {
        "agents": [_agent_view(a) for a in mdb.list_agents(DB_PATH)],
        "poll_interval_sec": CFG["poll_interval_sec"],
        "allow_control": bool(CFG["allow_agent_control"]),
        "now": time.time(),
    }


def api_cleanup(q):
    try:
        limit = max(1, min(2000, int(q.get("limit", 300))))
    except ValueError:
        limit = 300
    agent_filter = q.get("agent")
    rows = []
    for a in mdb.list_agents(DB_PATH):
        if agent_filter and str(a["id"]) != agent_filter:
            continue
        for f in json.loads(a["cleanup"]) if a["cleanup"] else []:
            f["agent_id"] = a["id"]
            f["agent_name"] = a["name"]
            f["hostname"] = a["hostname"]
            rows.append(f)
    rows.sort(key=lambda f: f.get("size", 0), reverse=True)
    return {"files": rows[:limit], "per_agent": int(CFG["cleanup_top_per_agent"])}


def api_add_agent(body):
    try:
        url = normalize_url(body.get("url"))
    except ValueError as e:
        return 400, {"detail": str(e)}
    name = (body.get("name") or "").strip()[:100]
    aid = mdb.add_agent(DB_PATH, url, name, time.time())
    if aid is None:
        return 409, {"detail": "이미 등록된 주소입니다: " + url}
    POLLER.force(aid)
    return 200, {"id": aid, "url": url}


def api_update_agent(aid, body):
    if not mdb.get_agent(DB_PATH, aid):
        return 404, {"detail": "등록되지 않은 에이전트입니다."}
    fields = {}
    if "name" in body:
        fields["name"] = (body.get("name") or "").strip()[:100]
    if "url" in body:
        try:
            fields["url"] = normalize_url(body.get("url"))
        except ValueError as e:
            return 400, {"detail": str(e)}
    if "enabled" in body:
        fields["enabled"] = 1 if body.get("enabled") else 0
    if not mdb.update_agent(DB_PATH, aid, fields):
        return 409, {"detail": "이미 등록된 주소입니다."}
    POLLER.force(aid)
    return 200, {"updated": True}


def api_delete_agent(aid):
    mdb.delete_agent(DB_PATH, aid)
    return 200, {"deleted": True}


def api_scan_all():
    """사용 중인 모든 에이전트에 스캔 시작 요청 (각 에이전트의 포함 대상 전체)."""
    if not CFG["allow_agent_control"]:
        return 403, {"detail": "마스터에서 에이전트 제어가 꺼져 있습니다 (config.json allow_agent_control)."}
    agents = [a for a in mdb.list_agents(DB_PATH) if a["enabled"]]

    def start(a):
        try:
            status, data, _ = agent_request(a["url"], "/api/scan", "POST", b'{"root": null}')
            try:
                detail = json.loads(data.decode("utf-8")).get("detail", "")
            except ValueError:
                detail = ""
            return {"id": a["id"], "name": a["name"] or a["hostname"] or a["url"],
                    "ok": status == 200, "detail": detail}
        except AgentError as e:
            return {"id": a["id"], "name": a["name"] or a["url"], "ok": False, "detail": str(e)}

    results = list(POLLER.pool.map(start, agents)) if agents else []
    for a in agents:
        POLLER.force(a["id"])
    return 200, {"results": results}


# ---------- 에이전트 화면 중계 (/agent/<id>/...) ----------

_API_PATH_RE = re.compile(r"""(["'`])/api/""")


def agent_page(agent):
    """에이전트 대시보드 HTML을 받아 API 경로를 /agent/<id>/api/ 로 바꾸고 상단에 돌아가기 줄을 붙인다."""
    status, data, _ = agent_request(agent["url"], "/")
    if status != 200:
        raise AgentError("에이전트 화면을 받지 못했습니다 (HTTP %d)" % status)
    page = data.decode("utf-8")
    prefix = "/agent/%d/api/" % agent["id"]
    page = _API_PATH_RE.sub(lambda m: m.group(1) + prefix, page)
    label = agent["name"] or agent["hostname"] or agent["url"]
    page = page.replace("<title>", "<title>" + html.escape(label) + " · ", 1)
    banner = (
        '<div style="display:flex;gap:12px;align-items:center;padding:7px 14px;font-size:12px;'
        'background:var(--surface-2,#f0f0ed);border-bottom:1px solid var(--border,#ddd)">'
        '<a href="/" style="color:var(--accent,#2a78d6);font-weight:600;text-decoration:none">'
        '&larr; 통합 화면</a><span>서버: <b>%s</b> &middot; %s</span>'
        '<span style="color:var(--text-muted,#888)">마스터를 통해 보는 중</span></div>'
        % (html.escape(label), html.escape(agent["url"]))
    )
    m = re.search(r"<body[^>]*>", page)
    if m:
        page = page[:m.end()] + banner + page[m.end():]
    return page.encode("utf-8")


# ---------- HTTP 핸들러 ----------

_AGENT_ROUTE = re.compile(r"^/agent/(\d+)(/.*)?$")
_AGENT_API = re.compile(r"^/api/agents/(\d+)/(update|delete|poll)$")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "fs-master"

    def log_message(self, fmt, *args):
        pass

    def _send(self, data, ctype, status=200, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _send_json(self, obj, status=200):
        self._send(json.dumps(obj, ensure_ascii=False).encode("utf-8"),
                   "application/json; charset=utf-8", status)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        return raw

    def _json_body(self):
        raw = self._body()
        try:
            obj = json.loads(raw.decode("utf-8")) if raw else {}
        except ValueError:
            obj = {}
        return obj if isinstance(obj, dict) else {}

    def _handle(self, method):
        parsed = urlparse(self.path)
        route = parsed.path
        try:
            m = _AGENT_ROUTE.match(route)
            if m:
                return self._agent_proxy(method, int(m.group(1)), m.group(2) or "", parsed.query)
            if method == "GET":
                return self._get(route, {k: v[0] for k, v in parse_qs(parsed.query).items()})
            return self._post(route)
        except AgentError as exc:
            self._send_json({"detail": str(exc)}, 502)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            try:
                self._send_json({"detail": str(exc)}, 500)
            except OSError:
                pass

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def _get(self, route, q):
        if route == "/":
            return self._send((STATIC_DIR / "index.html").read_bytes(), CONTENT_TYPES[".html"])
        if route == "/api/agents":
            return self._send_json(api_agents())
        if route == "/api/cleanup":
            return self._send_json(api_cleanup(q))
        return self._send_json({"detail": "not found"}, 404)

    def _post(self, route):
        body = self._json_body()
        if route == "/api/agents":
            status, payload = api_add_agent(body)
            return self._send_json(payload, status)
        if route == "/api/poll":
            try:
                POLLER.force(int(body["id"]) if body.get("id") is not None else None)
            except (TypeError, ValueError):
                return self._send_json({"detail": "id가 올바르지 않습니다."}, 400)
            return self._send_json({"polling": True})
        if route == "/api/scan-all":
            status, payload = api_scan_all()
            return self._send_json(payload, status)
        m = _AGENT_API.match(route)
        if m:
            aid, action = int(m.group(1)), m.group(2)
            if action == "update":
                status, payload = api_update_agent(aid, body)
            elif action == "delete":
                status, payload = api_delete_agent(aid)
            else:
                POLLER.force(aid)
                status, payload = 200, {"polling": True}
            return self._send_json(payload, status)
        return self._send_json({"detail": "not found"}, 404)

    def _agent_proxy(self, method, aid, rest, query):
        agent = mdb.get_agent(DB_PATH, aid)
        if not agent:
            return self._send_json({"detail": "등록되지 않은 에이전트입니다."}, 404)
        if rest == "":
            return self._send(b"", "text/plain", 301, {"Location": "/agent/%d/" % aid})
        if rest == "/" and method == "GET":
            return self._send(agent_page(agent), CONTENT_TYPES[".html"])
        if not rest.startswith("/api/"):
            return self._send_json({"detail": "not found"}, 404)
        sub = rest[len("/api/"):]
        if method == "POST":
            body = self._body()
            if sub not in AGENT_POST_PATHS:
                return self._send_json({"detail": "not found"}, 404)
            if not CFG["allow_agent_control"]:
                return self._send_json(
                    {"detail": "마스터에서 에이전트 제어가 꺼져 있습니다 (config.json allow_agent_control)."}, 403)
            status, data, ctype = agent_request(agent["url"], rest, "POST", body or b"{}")
            if sub in ("scan", "reset"):
                POLLER.force(aid)
        else:
            status, data, ctype = agent_request(agent["url"], rest + ("?" + query if query else ""))
        return self._send(data, ctype or "application/json; charset=utf-8", status)


class ThreadingServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = os.name != "nt"

    def server_bind(self):
        if os.name == "nt" and hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        HTTPServer.server_bind(self)


def _fail(msg):
    sys.stderr.write("[fs-master] 시작 중단: " + msg + "\n")
    sys.exit(1)


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
    except OSError as e:
        return e.errno == errno.EPERM
    return True


def _port_in_use(host, port):
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
    ap = argparse.ArgumentParser(description="파일시스템 통합 관리 서버 (fs-master)")
    ap.add_argument("--host", default=CFG.get("host", "0.0.0.0"))
    ap.add_argument("--port", type=int, default=int(CFG.get("port", 15900)))
    args = ap.parse_args()

    try:
        pid = int(PID_FILE.read_text().strip())
        if pid != os.getpid() and _pid_alive(pid):
            _fail("이 폴더의 fs-master가 이미 실행 중입니다 (PID %d). 재기동은 restart.sh "
                  "(설치판은 systemctl restart fs-master)를 사용하세요." % pid)
    except (OSError, ValueError):
        pass
    in_use_msg = ("%d 포트를 이미 다른 프로세스가 사용(LISTEN) 중입니다. 기존 프로세스는 건드리지 않습니다. "
                  "--port <다른 포트> 또는 config.json의 \"port\"로 다른 포트를 지정하세요." % args.port)
    if _port_in_use(args.host, args.port):
        _fail(in_use_msg)
    try:
        srv = ThreadingServer((args.host, args.port), Handler)
    except OSError as e:
        if e.errno in (errno.EADDRINUSE, getattr(errno, "WSAEADDRINUSE", -1)):
            _fail(in_use_msg)
        raise

    mdb.init_db(DB_PATH)
    PID_FILE.write_text(str(os.getpid()))
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    POLLER.start()
    print("fs-master serving on http://%s:%d (PID %d)" % (args.host, args.port, os.getpid()))
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
