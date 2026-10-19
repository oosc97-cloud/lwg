"""파일시스템 자동 정리 정책 파일(filesystem_auto_clear.env_*) 수집·분석.

스캔 중 이름이 정책 접두어로 시작하는 파일을 찾아 내용을 읽고,
KEY=VALUE(쉘 env) 형식으로 해석한 뒤 경로·보관 기간을 뽑아
스캔 결과(files/dirs)와 맞대어 "정책대로 지우면 얼마나 정리되는지"를 계산한다.
형식이 정해져 있지 않으므로 KEY=VALUE가 아닌 줄(예: "/경로 30")도 경로·숫자를 찾아 해석한다.
"""
import glob
import json
import os
import re
import time

from . import db

KV_RE = re.compile(r"^\s*(?:export\s+|declare\s+(?:-\w+\s+)?|typeset\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")
# 보관 기간(일)으로 볼 키 이름
DAYS_RE = re.compile(r"(^|_)(DAYS?|DD|KEEP|RETEN\w*|PERIOD|AGE|EXPIRE\w*|MTIME|TERM|SAVE)(_|$)", re.I)
# 사용률·용량 임계값으로 볼 키 이름
LIMIT_RE = re.compile(r"PCT|PERCENT|USAGE|THRESHOLD|LIMIT|RATE|FULL", re.I)
# 파일 이름 패턴으로 볼 키 이름
PATTERN_RE = re.compile(r"PATTERN|PATN|NAME|EXT|FILE|MASK|GLOB", re.I)
# 사용 여부로 볼 키 이름
FLAG_RE = re.compile(r"USE_?YN|ENABLE|ACTIVE|FLAG|_YN$", re.I)
PATH_TOKEN_RE = re.compile(r"(/[^\s,;:'\"|]*)")
NUM_RE = re.compile(r"^\d+$")

SCHEMA = """
CREATE TABLE IF NOT EXISTS policies (
    path TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    dir TEXT NOT NULL,
    target TEXT NOT NULL,
    size INTEGER NOT NULL,
    mtime REAL NOT NULL,
    encoding TEXT NOT NULL,
    truncated INTEGER NOT NULL DEFAULT 0,
    content TEXT NOT NULL,
    vars TEXT NOT NULL,
    analysis TEXT NOT NULL,
    checked_at REAL NOT NULL,
    error TEXT
);
"""


def init(conn):
    conn.executescript(SCHEMA)


def _prefix(cfg):
    return cfg.get("policy", {}).get("file_prefix") or "filesystem_auto_clear.env_"


def is_policy_name(name, cfg):
    return name.startswith(_prefix(cfg))


def _read(path, max_bytes):
    with open(path, "rb") as f:
        raw = f.read(max_bytes + 1)
    truncated = len(raw) > max_bytes
    raw = raw[:max_bytes]
    for enc in ("utf-8", "euc-kr"):
        try:
            return raw.decode(enc), enc, truncated
        except UnicodeDecodeError:
            continue
    return raw.decode("latin-1"), "latin-1", truncated


def _unquote(value):
    """쉘 값: 따옴표 안은 그대로, 따옴표 없으면 ' #' 뒤 주석 제거."""
    v = value.strip()
    if v[:1] in ("'", '"'):
        q = v[0]
        end = v.find(q, 1)
        return v[1:end] if end > 0 else v[1:]
    if v.startswith("("):  # 배열 ( a b c )
        end = v.rfind(")")
        return v[1:end if end > 0 else None].strip()
    m = re.search(r"\s+#", v)
    if m:
        v = v[:m.start()]
    return v.strip()


def _expand(value, env):
    """$VAR / ${VAR} 를 앞에서 정의한 값으로 치환 (모르는 변수는 그대로)."""
    def rep(m):
        key = m.group(1) or m.group(2)
        return env.get(key, m.group(0))
    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", rep, value)


def _paths_in(value):
    out = []
    for p in PATH_TOKEN_RE.findall(value):
        p = p.rstrip("/") or "/"
        if p not in out:
            out.append(p)
    return out


def _key_stem(key):
    """LOG_DIR / LOG_KEEP_DAYS 처럼 같은 접두어끼리 묶기 위한 줄기 (첫 토큰)."""
    parts = [p for p in key.upper().split("_") if p]
    return parts[0] if parts else key.upper()


def parse(text):
    """내용 → 변수 목록 + KEY=VALUE가 아닌 줄 목록."""
    env = {}
    variables = []
    others = []
    for lineno, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m = KV_RE.match(line)
        if m:
            key, raw = m.group(1), m.group(2)
            value = _expand(_unquote(raw), env)
            env[key] = value
            kind = "기타"
            if FLAG_RE.search(key):
                kind = "사용여부"
            elif _paths_in(value) and not NUM_RE.match(value):
                kind = "경로"
            elif NUM_RE.match(value) and DAYS_RE.search(key):
                kind = "보관기간"
            elif re.match(r"^\d+(\.\d+)?%?$", value) and LIMIT_RE.search(key):
                kind = "임계값"
            elif PATTERN_RE.search(key) or re.search(r"[*?]", value):
                kind = "패턴"
            variables.append({"line": lineno, "key": key, "value": value, "kind": kind})
        else:
            others.append({"line": lineno, "text": _expand(s, env)})
    return variables, others


def _rules(variables, others):
    """경로마다 보관 기간·패턴을 짝지어 정리 규칙을 만든다."""
    rules = []
    days_vars = [v for v in variables if v["kind"] == "보관기간"]
    pattern_vars = [v for v in variables if v["kind"] == "패턴"]
    off = [v for v in variables if v["kind"] == "사용여부" and v["value"].upper() in ("N", "NO", "0", "FALSE", "OFF")]

    def pick(cands, stem):
        same = [v for v in cands if _key_stem(v["key"]) == stem]
        if same:
            return same[0]
        return cands[0] if len(cands) == 1 else None

    for v in variables:
        if v["kind"] != "경로":
            continue
        stem = _key_stem(v["key"])
        d = pick(days_vars, stem)
        pt = pick(pattern_vars, stem)
        for p in _paths_in(v["value"]):
            rules.append({
                "path": p, "days": int(d["value"]) if d else None,
                "days_key": d["key"] if d else "", "pattern": pt["value"] if pt else "",
                "source": "%d행 %s" % (v["line"], v["key"]),
                "own": bool(d and _key_stem(d["key"]) == stem),
            })
    # "/경로 30 *.log" 처럼 KEY=VALUE가 아닌 줄
    for o in others:
        paths = _paths_in(o["text"])
        if not paths:
            continue
        rest = PATH_TOKEN_RE.sub(" ", o["text"]).split()
        nums = [t for t in rest if NUM_RE.match(t)]
        pats = [t for t in rest if re.search(r"[*?]", t)]
        for p in paths:
            rules.append({
                "path": p, "days": int(nums[0]) if nums else None, "days_key": "",
                "pattern": pats[0] if pats else "", "source": "%d행" % o["line"],
                "own": bool(nums),
            })
    # BASE=/shblog 처럼 다른 경로의 바탕이 되는 상위 경로(자체 기간 없음)는 규칙에서 뺀다
    rules = [r for r in rules if r.pop("own") and r["days"] is not None
             or not any(o is not r and o["path"].startswith(r["path"].rstrip("/") + "/") for o in rules)]
    return rules, off


def _glob_to_sql(pattern):
    """쉘 패턴(여러 개는 공백·쉼표 구분) → SQLite GLOB 목록."""
    return [p for p in re.split(r"[\s,]+", pattern.strip()) if p]


def _rule_stats(conn, rule, now, cleanup_grades):
    path = rule["path"]
    if any(c in path for c in "*?["):
        dir_where, dparams = "(dir GLOB ? OR dir GLOB ?)", [path, path + "/*"]
    else:
        like = path.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "/%"
        dir_where, dparams = "(dir = ? OR dir LIKE ? ESCAPE '\\')", [path, like]
    pats = _glob_to_sql(rule.get("pattern") or "")
    name_where = ""
    if pats:
        name_where = " AND (" + " OR ".join("name GLOB ?" for _ in pats) + ")"
        dparams = dparams + pats
    row = conn.execute(
        "SELECT COUNT(*) AS n, COALESCE(SUM(size),0) AS s FROM files WHERE " + dir_where + name_where,
        dparams).fetchone()
    stats = {"files": row["n"], "size": row["s"]}
    if rule.get("days") is not None:
        cutoff = now - rule["days"] * 86400
        r2 = conn.execute(
            "SELECT COUNT(*) AS n, COALESCE(SUM(size),0) AS s FROM files WHERE "
            + dir_where + name_where + " AND mtime < ?", dparams + [cutoff]).fetchone()
        stats["expired_files"] = r2["n"]
        stats["expired_size"] = r2["s"]
        # 정책 기간은 지났지만 아직 남아 있는 가장 오래된 파일 (정책이 실제로 돌고 있는지 판단용)
        r3 = conn.execute(
            "SELECT MIN(mtime) AS m FROM files WHERE " + dir_where + name_where, dparams).fetchone()
        stats["oldest_mtime"] = r3["m"]
    if cleanup_grades:
        marks = ",".join("?" for _ in cleanup_grades)
        r4 = conn.execute(
            "SELECT COALESCE(SUM(size),0) AS s FROM files WHERE " + dir_where + name_where
            + " AND grade IN (" + marks + ")", dparams + list(cleanup_grades)).fetchone()
        stats["cleanup_size"] = r4["s"]
    return stats


def _within(path, roots):
    for r in roots:
        r = os.path.normpath(r)
        if path == r or path.startswith(r.rstrip("/") + "/"):
            return True
    return False


def analyze(conn, path, name, text, cfg, roots, now):
    variables, others = parse(text)
    rules, off = _rules(variables, others)
    target = name[len(_prefix(cfg)):]
    cleanup_grades = list(cfg.get("cleanup", {}).get("grades") or [])
    warnings = []
    if off:
        warnings.append("사용 안 함으로 설정됨: " + ", ".join("%s=%s" % (v["key"], v["value"]) for v in off))
    for rule in rules:
        rule["in_scan"] = _within(rule["path"].split("*")[0].rstrip("/") or "/", roots)
        if rule["in_scan"]:
            rule.update(_rule_stats(conn, rule, now, cleanup_grades))
            if rule.get("files") == 0:
                warnings.append("%s: 스캔 결과에 파일이 없음 (경로가 없거나 비어 있음)" % rule["path"])
            elif rule.get("expired_files"):
                warnings.append("%s: 보관 기간(%d일)이 지난 파일 %d개가 남아 있음 — 정리가 돌지 않았을 수 있음"
                                % (rule["path"], rule["days"], rule["expired_files"]))
        else:
            warnings.append("%s: 스캔 대상(scan_include) 밖이라 용량을 계산하지 못함" % rule["path"])
        if rule.get("days") == 0:
            warnings.append("%s: 보관 기간이 0일" % rule["path"])
    if not rules:
        warnings.append("정리 대상 경로를 찾지 못함 — 원문을 확인하세요")
    # 파일 이름 뒤쪽(shblog 등)과 같은 이름의 최상위 파일시스템
    fs = None
    for r in roots:
        if os.path.basename(os.path.normpath(r)) == target:
            row = conn.execute("SELECT size, file_count, cleanup_size FROM dirs WHERE path = ?",
                               (os.path.normpath(r),)).fetchone()
            fs = {"path": os.path.normpath(r), "size": row["size"] if row else None,
                  "files": row["file_count"] if row else None,
                  "cleanup_size": row["cleanup_size"] if row else None}
            break
    expired = sum(r.get("expired_size") or 0 for r in rules)
    return variables, {
        "target": target, "filesystem": fs, "rules": rules, "others": others,
        "warnings": warnings, "expired_size": expired,
        "expired_files": sum(r.get("expired_files") or 0 for r in rules),
    }


def refresh(found, scanned_roots, cfg, db_path):
    """스캔에서 찾은 정책 파일(+ config의 추가 경로)을 다시 읽고 분석해 저장한다.
    scanned_roots 아래에 있던 기존 행은 이번에 못 찾았으면 지운다."""
    pcfg = cfg.get("policy", {})
    max_bytes = int(pcfg.get("max_bytes", 262144))
    from .config import resolve_scan_roots
    roots = [os.path.normpath(r) for r in resolve_scan_roots(cfg)]
    paths = list(found)
    for pat in pcfg.get("extra_paths") or []:
        for p in sorted(glob.glob(pat)):
            if os.path.isfile(p) and is_policy_name(os.path.basename(p), cfg) and p not in paths:
                paths.append(p)
    now = time.time()
    conn = db.connect(db_path)
    try:
        init(conn)
        existing = [r["path"] for r in conn.execute("SELECT path FROM policies")]
        scanned = [os.path.normpath(r) for r in scanned_roots]
        for p in existing:
            if p not in paths and (_within(p, scanned) or not os.path.exists(p)):
                conn.execute("DELETE FROM policies WHERE path = ?", (p,))
        for p in paths:
            name = os.path.basename(p)
            try:
                st = os.stat(p)
                text, enc, truncated = _read(p, max_bytes)
                variables, analysis = analyze(conn, p, name, text, cfg, roots, now)
                error = None
            except (OSError, ValueError) as exc:
                st = None
                text, enc, truncated, variables, analysis = "", "", False, [], {}
                error = str(exc)
            conn.execute(
                "INSERT OR REPLACE INTO policies (path, name, dir, target, size, mtime, encoding, truncated,"
                " content, vars, analysis, checked_at, error) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (p, name, os.path.dirname(p), name[len(_prefix(cfg)):], st.st_size if st else 0,
                 st.st_mtime if st else 0, enc, int(truncated), text,
                 json.dumps(variables, ensure_ascii=False), json.dumps(analysis, ensure_ascii=False),
                 now, error))
        conn.commit()
    finally:
        conn.close()


def list_policies(db_path, with_content=True):
    conn = db.connect(db_path)
    try:
        init(conn)
        rows = conn.execute("SELECT * FROM policies ORDER BY target, path").fetchall()
    finally:
        conn.close()
    items = []
    for r in rows:
        d = dict(r)
        d["vars"] = json.loads(d["vars"] or "[]")
        d["analysis"] = json.loads(d["analysis"] or "{}")
        d["truncated"] = bool(d["truncated"])
        if not with_content:
            d.pop("content", None)
        items.append(d)
    return items
