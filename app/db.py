"""SQLite 저장 계층. 각 호출마다 커넥션을 생성해 스레드 안전하게 사용한다."""
import sqlite3
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS scans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    root TEXT NOT NULL,
    started_at REAL NOT NULL,
    finished_at REAL,
    status TEXT NOT NULL DEFAULT 'running',
    file_count INTEGER NOT NULL DEFAULT 0,
    total_size INTEGER NOT NULL DEFAULT 0,
    error TEXT
);
CREATE TABLE IF NOT EXISTS files (
    path TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    ext TEXT NOT NULL,
    top_dir TEXT NOT NULL,
    dir TEXT NOT NULL DEFAULT '',
    size INTEGER NOT NULL,
    atime REAL NOT NULL,
    mtime REAL NOT NULL,
    score REAL NOT NULL,
    grade TEXT NOT NULL,
    scan_id INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_files_score ON files(score);
CREATE INDEX IF NOT EXISTS idx_files_grade ON files(grade);
CREATE INDEX IF NOT EXISTS idx_files_size ON files(size);
CREATE INDEX IF NOT EXISTS idx_files_top_dir ON files(top_dir);
CREATE TABLE IF NOT EXISTS dirs (
    path TEXT PRIMARY KEY,
    parent TEXT NOT NULL,
    name TEXT NOT NULL,
    depth INTEGER NOT NULL,
    size INTEGER NOT NULL,
    file_count INTEGER NOT NULL,
    score_sum REAL NOT NULL,
    scan_id INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_dirs_parent ON dirs(parent);
-- 스캔별 상위 디렉터리 집계 이력 (스냅샷 간 변화 추적용, history.depth 깊이까지)
CREATE TABLE IF NOT EXISTS scan_history (
    scan_id INTEGER NOT NULL,
    root TEXT NOT NULL,
    path TEXT NOT NULL,
    depth INTEGER NOT NULL,
    size INTEGER NOT NULL,
    file_count INTEGER NOT NULL,
    score_sum REAL NOT NULL,
    cleanup_size INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_history_path ON scan_history(path, scan_id);
CREATE INDEX IF NOT EXISTS idx_history_scan ON scan_history(scan_id);
"""


def connect(db_path: Path) -> sqlite3.Connection:
    # Python 3.6의 sqlite3.connect는 Path 객체를 받지 못한다(3.7부터 지원) — str로 넘긴다.
    conn = sqlite3.connect(str(db_path), timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_db(db_path: Path) -> None:
    with connect(db_path) as conn:
        conn.executescript(SCHEMA)
        # 구버전 DB 마이그레이션: files.dir 컬럼이 없으면 추가
        cols = [r["name"] for r in conn.execute("PRAGMA table_info(files)")]
        if "dir" not in cols:
            conn.execute("ALTER TABLE files ADD COLUMN dir TEXT NOT NULL DEFAULT ''")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_files_dir ON files(dir)")
        # dirs.cleanup_size: 정리 대상 등급 파일 용량 합 (디렉터리 순위용)
        dcols = [r["name"] for r in conn.execute("PRAGMA table_info(dirs)")]
        if "cleanup_size" not in dcols:
            conn.execute("ALTER TABLE dirs ADD COLUMN cleanup_size INTEGER NOT NULL DEFAULT 0")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_dirs_depth ON dirs(depth, size)")
        # 서버 재시작으로 끊긴 스캔은 실패로 정리
        conn.execute(
            "UPDATE scans SET status='error', error='서버 재시작으로 중단됨', finished_at=started_at "
            "WHERE status='running'"
        )
