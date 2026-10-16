"""fs-master 저장 계층 (SQLite). 호출마다 커넥션을 새로 열어 스레드 안전하게 쓴다."""
import json
import sqlite3

SCHEMA = """
CREATE TABLE IF NOT EXISTS agents (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL DEFAULT '',
    url TEXT NOT NULL UNIQUE,
    enabled INTEGER NOT NULL DEFAULT 1,
    added_at REAL NOT NULL,
    status TEXT NOT NULL DEFAULT 'unknown',   -- unknown | ok | error
    error TEXT NOT NULL DEFAULT '',
    last_poll_at REAL,
    last_ok_at REAL,
    hostname TEXT NOT NULL DEFAULT '',
    ip TEXT NOT NULL DEFAULT '',
    scan TEXT,       -- /api/scan/status JSON
    summary TEXT,    -- /api/summary JSON
    roots TEXT,      -- /api/roots JSON
    tree TEXT,       -- /api/tree (스캔 루트 목록) JSON
    cleanup TEXT     -- /api/cleanup-candidates JSON (큰 순 상위 N개)
);
"""


def connect(db_path):
    # Python 3.6의 sqlite3.connect는 Path 객체를 받지 못한다 — str로 넘긴다.
    conn = sqlite3.connect(str(db_path), timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_db(db_path):
    with connect(db_path) as conn:
        conn.executescript(SCHEMA)
        # 자동 등록: agent_key = 에이전트가 보내는 서버별 고유 키, last_seen_at = 마지막 등록 신호
        cols = [r["name"] for r in conn.execute("PRAGMA table_info(agents)")]
        if "agent_key" not in cols:
            conn.execute("ALTER TABLE agents ADD COLUMN agent_key TEXT")
        if "last_seen_at" not in cols:
            conn.execute("ALTER TABLE agents ADD COLUMN last_seen_at REAL")
        conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_agents_key ON agents(agent_key) WHERE agent_key IS NOT NULL")


def list_agents(db_path):
    with connect(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM agents ORDER BY name = '', name, id")]


def get_agent(db_path, aid):
    with connect(db_path) as conn:
        r = conn.execute("SELECT * FROM agents WHERE id = ?", (aid,)).fetchone()
    return dict(r) if r else None


def add_agent(db_path, url, name, now):
    try:
        with connect(db_path) as conn:
            cur = conn.execute("INSERT INTO agents (url, name, added_at) VALUES (?, ?, ?)", (url, name, now))
            return cur.lastrowid
    except sqlite3.IntegrityError:
        return None


def update_agent(db_path, aid, fields):
    if not fields:
        return True
    cols = ", ".join("%s = ?" % k for k in fields)
    try:
        with connect(db_path) as conn:
            if "url" in fields:  # 주소가 바뀌면 예전 수집 결과는 버린다
                conn.execute(
                    "UPDATE agents SET status='unknown', error='', scan=NULL, summary=NULL, roots=NULL, "
                    "tree=NULL, cleanup=NULL, hostname='', ip='' WHERE id = ? AND url != ?",
                    (aid, fields["url"]))
            conn.execute("UPDATE agents SET %s WHERE id = ?" % cols, list(fields.values()) + [aid])
        return True
    except sqlite3.IntegrityError:
        return False


def register_agent(db_path, key, url, hostname, now):
    """에이전트 자동 등록. (id, 새로 등록되었거나 주소가 바뀌었는지)를 돌려준다.
    같은 키가 있으면 주소·호스트명만 갱신, 없으면 같은 주소의 수동 등록 항목에 키를 붙이고, 그것도 없으면 새로 추가."""
    with connect(db_path) as conn:
        row = conn.execute("SELECT id, url FROM agents WHERE agent_key = ?", (key,)).fetchone()
        if row:
            changed = row["url"] != url
            if changed:  # IP가 바뀜: 그 주소로 따로 등록돼 있던 항목은 정리
                conn.execute("DELETE FROM agents WHERE url = ? AND id != ?", (url, row["id"]))
                conn.execute(
                    "UPDATE agents SET url=?, status='unknown', error='' WHERE id = ?", (url, row["id"]))
            conn.execute("UPDATE agents SET last_seen_at=?, hostname=CASE WHEN ?='' THEN hostname ELSE ? END "
                         "WHERE id = ?", (now, hostname, hostname, row["id"]))
            return row["id"], changed
        row = conn.execute("SELECT id FROM agents WHERE url = ?", (url,)).fetchone()
        if row:
            conn.execute("UPDATE agents SET agent_key=?, last_seen_at=? WHERE id = ?", (key, now, row["id"]))
            return row["id"], False
        cur = conn.execute(
            "INSERT INTO agents (url, name, added_at, agent_key, last_seen_at, hostname) VALUES (?, '', ?, ?, ?, ?)",
            (url, now, key, now, hostname))
        return cur.lastrowid, True


def delete_agent(db_path, aid):
    with connect(db_path) as conn:
        conn.execute("DELETE FROM agents WHERE id = ?", (aid,))


def _host_of(scan, summary):
    for src in (scan or {}, (summary or {}).get("last_scan") or {}):
        if src.get("hostname"):
            return src.get("hostname", ""), src.get("ip", "") or ""
    return None


def save_full(db_path, aid, data, now):
    host = _host_of(data["scan"], data["summary"])
    with connect(db_path) as conn:
        conn.execute(
            "UPDATE agents SET status='ok', error='', last_poll_at=?, last_ok_at=?, scan=?, summary=?, "
            "roots=?, tree=?, cleanup=? WHERE id = ?",
            (now, now, json.dumps(data["scan"], ensure_ascii=False),
             json.dumps(data["summary"], ensure_ascii=False),
             json.dumps(data["roots"], ensure_ascii=False),
             json.dumps(data["tree"], ensure_ascii=False),
             json.dumps(data["cleanup"], ensure_ascii=False), aid))
        if host:
            conn.execute("UPDATE agents SET hostname=?, ip=? WHERE id = ?", (host[0], host[1], aid))


def save_scan(db_path, aid, scan, now):
    host = _host_of(scan, None)
    with connect(db_path) as conn:
        conn.execute(
            "UPDATE agents SET status='ok', error='', last_poll_at=?, last_ok_at=?, scan=? WHERE id = ?",
            (now, now, json.dumps(scan, ensure_ascii=False), aid))
        if host:
            conn.execute("UPDATE agents SET hostname=?, ip=? WHERE id = ?", (host[0], host[1], aid))


def save_error(db_path, aid, error, now):
    """연결 실패 시 마지막으로 받은 요약은 그대로 두고 상태만 바꾼다."""
    with connect(db_path) as conn:
        conn.execute("UPDATE agents SET status='error', error=?, last_poll_at=? WHERE id = ?", (error, now, aid))
