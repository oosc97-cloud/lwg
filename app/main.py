"""FastAPI 서버: 스캔 트리거 + 분석 조회 API + 대시보드 정적 서빙."""
import threading
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from . import db, scanner
from .config import load_config, resolve_db_path, resolve_scan_roots

app = FastAPI(title="파일시스템 추적 관리 에이전트")

CFG = load_config()
DB_PATH = resolve_db_path(CFG)
db.init_db(DB_PATH)

STATIC_DIR = Path(__file__).resolve().parent / "static"
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

_scan_lock = threading.Lock()
_scan_thread: Optional[threading.Thread] = None


class ScanRequest(BaseModel):
    root: Optional[str] = None


@app.get("/")
def index():
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/api/roots")
def roots():
    return {"roots": resolve_scan_roots(CFG)}


@app.post("/api/scan")
def start_scan(req: ScanRequest):
    """root 지정 시 해당 경로만, 미지정 시 모든 데이터 영역을 순차 스캔."""
    global _scan_thread
    if req.root:
        roots = [req.root]
    else:
        roots = resolve_scan_roots(CFG)
    if not roots:
        raise HTTPException(400, "스캔 루트가 없습니다. config.json의 scan_roots를 확인하세요.")
    missing = [r for r in roots if not Path(r).is_dir()]
    if missing:
        raise HTTPException(400, f"디렉터리가 아닙니다: {', '.join(missing)}")
    with _scan_lock:
        if _scan_thread and _scan_thread.is_alive():
            raise HTTPException(409, "이미 스캔이 진행 중입니다.")
        _scan_thread = threading.Thread(
            target=scanner.run_scan_many, args=(roots, CFG, DB_PATH), daemon=True
        )
        _scan_thread.start()
    return {"started": True, "roots": roots}


@app.get("/api/scan/status")
def scan_status():
    """여러 루트 순차 스캔 중에는 개별 스캔이 done이어도 전체는 running으로 표시."""
    running = _scan_thread is not None and _scan_thread.is_alive()
    with db.connect(DB_PATH) as conn:
        row = conn.execute("SELECT * FROM scans ORDER BY id DESC LIMIT 1").fetchone()
    if not row:
        return {"status": "running" if running else "none"}
    result = dict(row)
    if running:
        result["status"] = "running"
    return result


@app.get("/api/summary")
def summary():
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
    grades = {g: {"count": 0, "size": 0} for g in ("hot", "warm", "cold", "stale")}
    for row in by_grade:
        grades[row["grade"]] = {"count": row["n"], "size": row["s"]}
    return {
        "file_count": total["n"],
        "total_size": total["s"],
        "avg_score": round(total["avg"], 1),
        "grades": grades,
        "last_scan": dict(last) if last else None,
    }


@app.get("/api/distribution")
def distribution():
    """가치점수 10점 단위 히스토그램 (0~100)."""
    with db.connect(DB_PATH) as conn:
        rows = conn.execute(
            """SELECT MIN(CAST(score/10 AS INTEGER), 9) AS bucket,
                      COUNT(*) AS n, COALESCE(SUM(size),0) AS s
               FROM files GROUP BY bucket"""
        ).fetchall()
    buckets = [{"range": f"{i*10}-{i*10+10}", "count": 0, "size": 0} for i in range(10)]
    for row in rows:
        buckets[row["bucket"]] = {
            "range": buckets[row["bucket"]]["range"],
            "count": row["n"],
            "size": row["s"],
        }
    return {"buckets": buckets}


def _dir_row(row) -> dict:
    count = row["file_count"]
    return {
        "path": row["path"],
        "name": row["name"],
        "size": row["size"],
        "file_count": count,
        "avg_score": round(row["score_sum"] / count, 1) if count else 0.0,
    }


@app.get("/api/tree")
def tree(path: Optional[str] = Query(None), files_limit: int = Query(100, ge=0, le=500)):
    """TreeSize식 탐색: path 미지정 시 스캔 루트 목록, 지정 시 직계 하위 디렉터리+파일."""
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


@app.get("/api/top-dirs")
def top_dirs(limit: int = Query(10, ge=1, le=50)):
    with db.connect(DB_PATH) as conn:
        rows = conn.execute(
            """SELECT top_dir, COUNT(*) AS n, SUM(size) AS s, ROUND(AVG(score),1) AS avg_score
               FROM files GROUP BY top_dir ORDER BY s DESC LIMIT ?""",
            (limit,),
        ).fetchall()
    return {"dirs": [dict(r) for r in rows]}


SORT_COLUMNS = {"score": "score", "size": "size", "atime": "atime", "mtime": "mtime"}


@app.get("/api/files")
def files(
    sort: str = Query("score"),
    order: str = Query("asc"),
    grade: Optional[str] = Query(None),
    q: Optional[str] = Query(None),
    limit: int = Query(50, ge=1, le=500),
):
    col = SORT_COLUMNS.get(sort, "score")
    direction = "DESC" if order.lower() == "desc" else "ASC"
    where, params = [], []
    if grade in ("hot", "warm", "cold", "stale"):
        where.append("grade = ?")
        params.append(grade)
    if q:
        where.append("path LIKE ?")
        params.append(f"%{q}%")
    where_sql = ("WHERE " + " AND ".join(where)) if where else ""
    with db.connect(DB_PATH) as conn:
        rows = conn.execute(
            f"""SELECT path, name, ext, size, atime, mtime, score, grade
                FROM files {where_sql}
                ORDER BY {col} {direction}, size DESC LIMIT ?""",
            (*params, limit),
        ).fetchall()
    return {"files": [dict(r) for r in rows]}


@app.get("/api/cleanup-candidates")
def cleanup_candidates(limit: int = Query(50, ge=1, le=500)):
    """정리 후보: 저가치(cold/stale)이면서 용량이 큰 파일."""
    with db.connect(DB_PATH) as conn:
        rows = conn.execute(
            """SELECT path, name, ext, size, atime, mtime, score, grade
               FROM files WHERE grade IN ('cold','stale')
               ORDER BY size DESC LIMIT ?""",
            (limit,),
        ).fetchall()
    return {"files": [dict(r) for r in rows]}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app.main:app", host="127.0.0.1", port=8000)
