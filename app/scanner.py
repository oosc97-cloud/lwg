"""데이터 영역 파일시스템 스캐너.

os.scandir 기반 반복 순회로 파일 메타데이터(size/atime/mtime)를 수집하고
가치점수를 계산해 SQLite에 배치 저장한다. 심볼릭 링크는 따라가지 않으며
권한 오류 디렉터리는 건너뛴다.
"""
import os
import time
from collections import defaultdict
from pathlib import Path

from . import db, policy
from .hostinfo import get_host_info
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
INSERT OR REPLACE INTO dirs (path, parent, name, depth, size, file_count, score_sum, scan_id,
                             cleanup_size, dir_count, last_mtime, last_atime, alloc_size)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
"""

HISTORY_INSERT = """
INSERT INTO scan_history (scan_id, root, path, depth, size, file_count, score_sum, cleanup_size)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)
"""


class ScanCancelled(Exception):
    """사용자가 스캔을 취소함."""


def run_scan_many(roots, cfg: dict, db_path: Path, cancel_event=None) -> None:
    """여러 데이터 영역을 순차 스캔. 한 루트가 실패해도 나머지는 계속한다.
    스캔 전에 대상 밖 루트(과거 수동 스캔 잔재)의 데이터를 정리한다.
    cancel_event가 set되면 진행 중인 루트를 멈추고 남은 루트도 건너뛴다."""
    purge_other_roots(roots, db_path)
    policy_hits = []  # 스캔 중 발견한 정리 정책 파일(filesystem_auto_clear.env_*)
    cancelled = False
    for root in roots:
        if cancel_event is not None and cancel_event.is_set():
            cancelled = True
            break
        try:
            run_scan(root, cfg, db_path, cancel_event, policy_hits)
        except ScanCancelled:
            cancelled = True
            break
        except Exception:
            continue
    # 정책 분석은 스캔 결과(files)를 쓰므로 스캔이 끝난 뒤에. 취소 시에는 직전 분석 유지
    if not cancelled:
        try:
            policy.refresh(policy_hits, roots, cfg, db_path)
        except Exception:
            pass


def purge_other_roots(roots, db_path: Path) -> None:
    """현재 스캔 대상에 없는 루트의 files/dirs 데이터를 삭제한다."""
    keep = {os.path.normpath(r) for r in roots}
    conn = db.connect(db_path)
    try:
        # 디렉터리 집계가 없는 루트(첫 스캔이 취소·실패한 경우)도 scans 기록으로 찾는다
        rows = conn.execute(
            "SELECT path FROM dirs WHERE parent = '' UNION SELECT root FROM scans"
        ).fetchall()
        for row in rows:
            p = os.path.normpath(row[0])
            if p in keep:
                continue
            like = os.path.join(p, "%")
            conn.execute("DELETE FROM files WHERE path = ? OR path LIKE ?", (p, like))
            conn.execute("DELETE FROM dirs WHERE path = ? OR path LIKE ?", (p, like))
        conn.commit()
    finally:
        conn.close()


def run_scan(root: str, cfg: dict, db_path: Path, cancel_event=None, policy_hits=None) -> int:
    score_cfg = cfg["score"]
    thresholds = cfg["grades"]
    cleanup_grades = set(cfg["cleanup"]["grades"])
    now = time.time()
    host = get_host_info()

    conn = db.connect(db_path)
    cur = conn.execute(
        "INSERT INTO scans (root, started_at, status, hostname, ip) VALUES (?, ?, 'running', ?, ?)",
        (root, now, host["hostname"], host["ip"]),
    )
    scan_id = cur.lastrowid
    conn.commit()

    batch = []
    file_count = 0
    total_size = 0
    # TreeSize식 트리 뷰용: 디렉터리별 [누적 용량, 파일 수, 점수 합, 정리 대상 용량,
    # 하위 폴더 수, 최근 수정, 최근 접근, 할당 용량] (조상 디렉터리까지 전파)
    dir_stats = defaultdict(lambda: [0, 0, 0.0, 0, 0, 0.0, 0.0, 0])

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
        dir_stats[root_norm]  # 파일이 하나도 없어도 루트는 트리에 0 B로 표시
        stack = [root_norm]
        while stack:
            if cancel_event is not None and cancel_event.is_set():
                raise ScanCancelled()
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
                            stack.append(entry.path)
                            dir_stats[entry.path]  # 빈 폴더도 트리에 표시
                        elif entry.is_file(follow_symlinks=False):
                            st = entry.stat(follow_symlinks=False)
                            if policy_hits is not None and policy.is_policy_name(entry.name, cfg):
                                policy_hits.append(entry.path)
                            score = value_score(
                                st.st_atime,
                                st.st_mtime,
                                now,
                                atime_weight=score_cfg["atime_weight"],
                                mtime_weight=score_cfg["mtime_weight"],
                                atime_half_life_days=score_cfg["atime_half_life_days"],
                                mtime_half_life_days=score_cfg["mtime_half_life_days"],
                            )
                            g = grade(score, thresholds)
                            cleanup = st.st_size if g in cleanup_grades else 0
                            eff_atime = max(st.st_atime, st.st_mtime)
                            # 할당 용량: 블록 기준(희소 파일·작은 파일 반영). Windows는 st_blocks 없음
                            blocks = getattr(st, "st_blocks", None)
                            alloc = blocks * 512 if blocks is not None else st.st_size
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
                                stats[3] += cleanup
                                stats[7] += alloc
                                if st.st_mtime > stats[5]:
                                    stats[5] = st.st_mtime
                                if eff_atime > stats[6]:
                                    stats[6] = eff_atime
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
                                    g,
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
        history_depth = int(cfg["history"]["depth"])
        # 하위 폴더 수(재귀): 각 폴더를 조상 폴더마다 1씩 더한다
        for p in list(dir_stats):
            q = p
            while q != root_norm:
                nxt = os.path.dirname(q)
                if nxt == q or nxt not in dir_stats:
                    break
                dir_stats[nxt][4] += 1
                q = nxt
        dir_rows = []
        history_rows = []
        for p, (size, count, score_sum, cleanup_size, dir_count, last_mtime, last_atime, alloc_size) in dir_stats.items():
            if p == root_norm:
                parent, depth = "", 0
            else:
                parent = os.path.dirname(p)
                rel = os.path.relpath(p, root_norm)
                depth = rel.count(os.sep) + 1
            name = os.path.basename(p) or p
            dir_rows.append((p, parent, name, depth, size, count, score_sum, scan_id,
                             cleanup_size, dir_count, last_mtime or None, last_atime or None, alloc_size))
            if depth <= history_depth:
                history_rows.append(
                    (scan_id, root_norm, p, depth, size, count, score_sum, cleanup_size)
                )
            if len(dir_rows) >= BATCH_SIZE:
                conn.executemany(DIR_INSERT, dir_rows)
                dir_rows.clear()
        if dir_rows:
            conn.executemany(DIR_INSERT, dir_rows)
        conn.executemany(HISTORY_INSERT, history_rows)
        conn.execute(
            "UPDATE scans SET finished_at=?, status='done', file_count=?, total_size=? WHERE id=?",
            (time.time(), file_count, total_size, scan_id),
        )
        prune_history(conn, root, int(cfg["history"]["keep_scans"]))
        conn.commit()
    except ScanCancelled:
        # 취소 시 삭제 파일 정리·디렉터리 집계 교체는 하지 않는다 (직전 결과 유지).
        # 직전 완료 결과가 없는 루트면 일부만 담긴 파일 목록을 남기지 않는다.
        has_previous = conn.execute(
            "SELECT 1 FROM dirs WHERE path = ? AND parent = ''", (root_norm,)
        ).fetchone()
        if not has_previous:
            conn.execute("DELETE FROM files WHERE scan_id = ?", (scan_id,))
        conn.execute(
            "UPDATE scans SET finished_at=?, status='cancelled', file_count=?, total_size=? WHERE id=?",
            (time.time(), file_count, total_size, scan_id),
        )
        conn.commit()
        raise
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


def prune_history(conn, root: str, keep: int) -> None:
    """루트별로 최근 완료 스캔 keep개의 이력만 남긴다."""
    rows = conn.execute(
        "SELECT id FROM scans WHERE root = ? AND status = 'done' ORDER BY id DESC",
        (root,),
    ).fetchall()
    for row in rows[max(keep, 1):]:
        conn.execute("DELETE FROM scan_history WHERE scan_id = ?", (row["id"],))
