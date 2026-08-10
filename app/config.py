"""설정 로드 및 플랫폼별 스캔 루트 결정."""
import glob
import json
import sys
from pathlib import Path
from typing import List

BASE_DIR = Path(__file__).resolve().parent.parent
CONFIG_PATH = BASE_DIR / "config.json"

DEFAULTS = {
    "scan_roots": [],
    "windows_excludes": [
        "C:\\Windows",
        "C:\\Program Files",
        "C:\\Program Files (x86)",
        "C:\\ProgramData",
        "C:\\$Recycle.Bin",
        "C:\\System Volume Information",
        "C:\\Recovery",
        "C:\\PerfLogs",
    ],
    "linux_excludes": ["/proc", "/sys", "/dev", "/run"],
    "exclude_names": ["$RECYCLE.BIN", "System Volume Information", "__pycache__", ".git"],
    "score": {
        "atime_weight": 0.6,
        "mtime_weight": 0.4,
        "atime_half_life_days": 30,
        "mtime_half_life_days": 90,
    },
    "db_path": "data/fs_agent.db",
}


def load_config() -> dict:
    cfg = dict(DEFAULTS)
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH, encoding="utf-8") as f:
            user = json.load(f)
        for key, value in user.items():
            if key == "score" and isinstance(value, dict):
                cfg["score"] = {**DEFAULTS["score"], **value}
            else:
                cfg[key] = value
    return cfg


def resolve_scan_roots(cfg: dict) -> List[str]:
    """config에 명시된 루트 우선. 없으면 플랫폼 기본값:
    Windows는 C:\\ (OS 영역은 excludes로 제외), Linux는 /shb*, /nbs* 데이터 영역."""
    if cfg.get("scan_roots"):
        return [str(Path(r)) for r in cfg["scan_roots"]]
    if sys.platform == "win32":
        return ["D:\\"]
    roots = sorted(glob.glob("/shb*") + glob.glob("/nbs*"))
    return [r for r in roots if Path(r).is_dir()]


def resolve_db_path(cfg: dict) -> Path:
    path = Path(cfg["db_path"])
    if not path.is_absolute():
        path = BASE_DIR / path
    path.parent.mkdir(parents=True, exist_ok=True)
    return path
