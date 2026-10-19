"""설정 로드 및 플랫폼별 스캔 루트 결정."""
import glob
import json
import sys
from pathlib import Path
from typing import List

BASE_DIR = Path(__file__).resolve().parent.parent
CONFIG_PATH = BASE_DIR / "config.json"

DEFAULTS = {
    "port": 15891,  # 웹 대시보드 포트 (--port로 덮어쓰기)
    # 스캔 대상 (포함 목록만): 여기에 해당하는 폴더만 스캔하고 그 밖은 보지 않는다.
    # 와일드카드(glob) 가능. 리눅스 /shb* = shb로 시작하는 최상위 폴더 전체.
    "scan_include": {
        "linux": ["/shb*", "/nbs*"],
        "windows": ["D:\\"],
    },
    "score": {
        "atime_weight": 0.6,
        "mtime_weight": 0.4,
        "atime_half_life_days": 30,
        "mtime_half_life_days": 90,
    },
    # 등급 하한 점수: hot ≥ 70, warm ≥ 40, cold ≥ 10, 나머지 stale
    "grades": {"hot": 70, "warm": 40, "cold": 10},
    # 정리 후보: 이 등급들 중 min_size_mb 이상인 파일
    "cleanup": {"grades": ["cold", "stale"], "min_size_mb": 0},
    # 스캔 이력: 루트별 완료 스캔 keep_scans개, 루트 기준 depth 깊이까지 디렉터리 집계 보관
    "history": {"keep_scans": 10, "depth": 2},
    # 정리 정책 파일: 스캔 중 이름이 file_prefix로 시작하는 파일을 읽어 분석 (max_bytes까지만 읽음).
    # extra_paths: 스캔 대상 밖에 있는 정책 파일 위치(glob), 예: ["/home/*/filesystem_auto_clear.env_*"]
    "policy": {"file_prefix": "filesystem_auto_clear.env_", "max_bytes": 262144, "extra_paths": []},
    "db_path": "data/fs_agent.db",
    # 마스터 서버(fs-master) 주소. 비우면 단독 실행. 예: "http://10.0.0.9:15900"
    "master": "",
    "master_heartbeat_sec": 300,  # 마스터에 등록 신호를 보내는 간격
    # 웹 화면 제공 여부. 마스터 연동판은 false: 화면은 마스터에서만 보고 에이전트는 API만 응답
    "web_ui": True,
}

NESTED_KEYS = ("scan_include", "score", "grades", "cleanup", "history", "policy")


def load_config() -> dict:
    cfg = dict(DEFAULTS)
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH, encoding="utf-8") as f:
            user = json.load(f)
        for key, value in user.items():
            if key in NESTED_KEYS and isinstance(value, dict):
                cfg[key] = {**DEFAULTS[key], **value}
            else:
                cfg[key] = value
    return cfg


def scan_include_patterns(cfg: dict) -> List[str]:
    """현재 플랫폼의 스캔 포함 패턴 목록."""
    key = "windows" if sys.platform == "win32" else "linux"
    return list(cfg.get("scan_include", {}).get(key) or [])


def resolve_scan_roots(cfg: dict) -> List[str]:
    """포함 패턴(scan_include)에 해당하는 실제 폴더 목록. 그 밖의 경로는 스캔하지 않는다."""
    roots = []
    for pattern in scan_include_patterns(cfg):
        for r in sorted(glob.glob(pattern)):
            r = str(Path(r))
            if Path(r).is_dir() and r not in roots:
                roots.append(r)
    return roots


def resolve_db_path(cfg: dict) -> Path:
    path = Path(cfg["db_path"])
    if not path.is_absolute():
        path = BASE_DIR / path
    path.parent.mkdir(parents=True, exist_ok=True)
    return path
