"""데이터 영역 파일시스템 스캐너.

os.scandir 기반 반복 순회로 파일 메타데이터(size/atime/mtime)를 수집하고
가치점수를 계산해 SQLite에 배치 저장한다. 심볼릭 링크는 따라가지 않으며
권한 오류 디렉터리는 건너뛴다.
"""
import os
import sys
import time
from collections import defaultdict
from pathlib import Path

from . import db
from .scoring import grade, value_score

BATCH_SIZE = 1000

UPSERT = """
INSERT INTO files (path, name, ext, top_dir, dir, size, atime, mtime, score, grade, scan_id)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(path) DO UPDATE SET
    dir=excluded.dir, size=excluded.size, atime=excluded.atime, mtime=excluded.mtime,
    score=excluded.score, grade=excluded.grade, scan_id=excluded.scan_id
"""

DIR_INSERT = """
INSERT OR REPLACE INTO dirs (path, parent, name, depth, size, file_count, score_sum, scan_id)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)
"""


def _norm(path: str) -> str:
    p = os.path.normpath(path)
    return p.lower() if sys.platform == "win32" else p


def run_scan_many(roots, cfg: dict, db_path: Path) -> None:
    """여러 데이터 영역을 순차 스캔. 한 루트가 실패해도 나머지는 계속한다."""
    for root in roots:
        try:
            run_scan(root, cfg, db_path)
        except Exception:
            continue


def run_scan(root: str, cfg: dict, db_path: Path) -> int:
    score_cfg = cfg["score"]
    exclude_paths = {_norm(p) for p in cfg.get("windows_excludes", [])} if sys.platform == "win32" else set()
    exclude_names = {n.lower() for n in cfg.get("exclude_names", [])}
    now = time.time()

    conn = db.connect(db_path)
    cur = conn.execute(
        "INSERT INTO scans (root, started_at, status) VALUES (?, ?, 'running')", (root, now)
    )
    scan_id = cur.lastrowid
    conn.commit()

    batch = []
    file_count = 0
    total_size = 0
    # TreeSize식 트리 뷰용: 디렉터리별 [누적 용량, 파일 수, 점수 합] (조상 디렉터리까지 전파)
    dir_stats = defaultdict(lambda: [0, 0, 0.0])

    def flush():
        nonlocal file_count, total_size
        if not batch:
            return
        conn.executemany(UPSERT, batch)
        conn.execute(
            "UPDATE scans SET file_count=?, total_size=? WHERE id=?",
            (file_count, total_size, scan_id),
        )
        conn.commit()
        batch.clear()

    try:
        root_norm = os.path.normpath(root)
        stack = [root_norm]
        while stack:
            current = stack.pop()
            try:
                entries = os.scandir(current)
            except (PermissionError, FileNotFoundError, OSError):
                continue
            with entries:
                for entry in entries:
                    try:
                        if entry.is_symlink():
                            continue
                        if entry.is_dir(follow_symlinks=False):
                            if entry.name.lower() in exclude_names:
                                continue
                            if exclude_paths and _norm(entry.path) in exclude_paths:
                                continue
                            stack.append(entry.path)
                        elif entry.is_file(follow_symlinks=False):
                            st = entry.stat(follow_symlinks=False)
                            score = value_score(
                                st.st_atime,
                                st.st_mtime,
                                now,
                                atime_weight=score_cfg["atime_weight"],
                                mtime_weight=score_cfg["mtime_weight"],
                                atime_half_life_days=score_cfg["atime_half_life_days"],
                                mtime_half_life_days=score_cfg["mtime_half_life_days"],
                            )
                            rel = os.path.relpath(entry.path, root_norm)
                            top_dir = rel.split(os.sep)[0] if os.sep in rel else "(루트)"
                            ext = os.path.splitext(entry.name)[1].lower() or "(없음)"
                            parent_dir = os.path.dirname(entry.path)
                            p = parent_dir
                            while True:
                                stats = dir_stats[p]
                                stats[0] += st.st_size
                                stats[1] += 1
                                stats[2] += score
                                if p == root_norm:
                                    break
                                nxt = os.path.dirname(p)
                                if nxt == p:
                                    break
                                p = nxt
                            batch.append(
                                (
                                    entry.path,
                                    entry.name,
                                    ext,
                                    top_dir,
                                    parent_dir,
                                    st.st_size,
                                    st.st_atime,
                                    st.st_mtime,
                                    score,
                                    grade(score),
                                    scan_id,
                                )
                            )
                            file_count += 1
                            total_size += st.st_size
                            if len(batch) >= BATCH_SIZE:
                                flush()
                    except (PermissionError, FileNotFoundError, OSError):
                        continue
        flush()
        # 이번 스캔에서 발견되지 않은(삭제된) 루트 하위 파일 제거
        like = os.path.join(root_norm, "%")
        conn.execute("DELETE FROM files WHERE path LIKE ? AND scan_id != ?", (like, scan_id))
        # 디렉터리 집계 저장 (루트 하위 트리 전체 교체)
        conn.execute("DELETE FROM dirs WHERE path = ? OR path LIKE ?", (root_norm, like))
        dir_rows = []
        for p, (size, count, score_sum) in dir_stats.items():
            if p == root_norm:
                parent, depth = "", 0
            else:
                parent = os.path.dirname(p)
                rel = os.path.relpath(p, root_norm)
                depth = rel.count(os.sep) + 1
            name = os.path.basename(p) or p
            dir_rows.append((p, parent, name, depth, size, count, score_sum, scan_id))
            if len(dir_rows) >= BATCH_SIZE:
                conn.executemany(DIR_INSERT, dir_rows)
                dir_rows.clear()
        if dir_rows:
            conn.executemany(DIR_INSERT, dir_rows)
        conn.execute(
            "UPDATE scans SET finished_at=?, status='done', file_count=?, total_size=? WHERE id=?",
            (time.time(), file_count, total_size, scan_id),
        )
        conn.commit()
    except Exception as exc:  # 스캔 스레드 실패를 상태로 남긴다
        conn.execute(
            "UPDATE scans SET finished_at=?, status='error', error=? WHERE id=?",
            (time.time(), str(exc), scan_id),
        )
        conn.commit()
        raise
    finally:
        conn.close()
    return file_count
