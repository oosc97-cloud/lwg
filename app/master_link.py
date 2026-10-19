"""마스터 서버(fs-master) 자동 등록. config.json에 "master"가 있을 때만 동작한다.

에이전트가 주기적으로 마스터의 /api/register 에 자기 포트·호스트명·고유 키를 보낸다.
마스터는 접속해 온 IP와 이 포트로 에이전트 주소를 만들어 목록에 올리고, 이후 그 주소로 수집한다.
마스터가 꺼져 있으면 30초마다 다시 시도한다. 단독 실행(마스터 없음)에는 영향이 없다.
"""
import json
import socket
import threading
import time
import urllib.request
import uuid
from pathlib import Path
from urllib.parse import urlparse

_state = {"master": "", "last_ok_at": None, "last_error": "", "agent_id": None}
_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # 내부망 직접 접속


def current_version():
    """설치 번들의 VERSION (저장소에서 직접 실행하면 dev)."""
    try:
        return (Path(__file__).resolve().parent.parent / "VERSION").read_text().strip() or "dev"
    except OSError:
        return "dev"


def _agent_key(data_dir):
    """서버별 고유 키 (data/agent_key). IP가 바뀌어도 마스터가 같은 서버로 알아보게 한다."""
    path = data_dir / "agent_key"
    try:
        key = path.read_text().strip()
        if key:
            return key
    except OSError:
        pass
    key = uuid.uuid4().hex
    path.write_text(key + "\n")
    return key


def _register(master, payload, timeout):
    req = urllib.request.Request(master + "/api/register", method="POST",
                                 data=json.dumps(payload).encode("utf-8"),
                                 headers={"Content-Type": "application/json"})
    with _opener.open(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def _loop(master, payload, interval):
    while True:
        try:
            res = _register(master, payload, 10)
            _state.update(last_ok_at=time.time(), last_error="", agent_id=res.get("id"))
            time.sleep(interval)
        except Exception as exc:  # 마스터 장애가 에이전트 동작에 영향을 주지 않게
            reason = getattr(exc, "reason", None) or exc
            _state["last_error"] = str(reason)
            time.sleep(min(30, interval))


def start(cfg, port, data_dir):
    master = (cfg.get("master") or "").strip().rstrip("/")
    if not master:
        return
    if "://" not in master:
        master = "http://" + master
    if urlparse(master).port is None:  # 포트 생략 시 마스터 기본 포트
        master += ":15900"
    _state["master"] = master
    payload = {"port": int(port), "hostname": socket.gethostname(), "agent_key": _agent_key(data_dir),
               "version": current_version()}
    interval = max(30, int(cfg.get("master_heartbeat_sec", 300)))
    threading.Thread(target=_loop, args=(master, payload, interval), daemon=True).start()


def status():
    out = dict(_state)
    out["version"] = current_version()
    return out
