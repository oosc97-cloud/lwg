"""atime/mtime 조합 데이터 가치점수(0~100) 산정.

점수 = 100 * (atime_weight * 2^(-접근경과일/atime_half_life)
            + mtime_weight * 2^(-수정경과일/mtime_half_life))

반감기(half-life) 지수감쇠: 접근 30일, 수정 90일이 지날 때마다 해당 항 점수가 절반.
Windows는 NTFS atime 갱신이 비활성화된 경우가 있어(NtfsDisableLastAccessUpdate)
atime < mtime이면 mtime을 유효 접근시간으로 보정한다.
"""
import math
import time
from typing import Optional

GRADES = ("hot", "warm", "cold", "stale")


def value_score(
    atime: float,
    mtime: float,
    now: Optional[float] = None,
    *,
    atime_weight: float = 0.6,
    mtime_weight: float = 0.4,
    atime_half_life_days: float = 30.0,
    mtime_half_life_days: float = 90.0,
) -> float:
    now = now if now is not None else time.time()
    effective_atime = max(atime, mtime)
    days_access = max((now - effective_atime) / 86400.0, 0.0)
    days_modify = max((now - mtime) / 86400.0, 0.0)
    access_term = math.exp(-math.log(2) * days_access / atime_half_life_days)
    modify_term = math.exp(-math.log(2) * days_modify / mtime_half_life_days)
    score = 100.0 * (atime_weight * access_term + mtime_weight * modify_term)
    return round(min(max(score, 0.0), 100.0), 1)


def grade(score: float) -> str:
    if score >= 70:
        return "hot"
    if score >= 40:
        return "warm"
    if score >= 10:
        return "cold"
    return "stale"
