# 파일시스템 추적 관리 에이전트 (lwg)

데이터 영역의 파일시스템 정보를 수집·분석하고, 접근시간(atime)과 수정시간(mtime)을
조합한 **데이터 가치점수**를 부여해 웹 대시보드로 확인하는 도구입니다.

**외부 패키지 의존성 없음** — 표준 라이브러리만 사용하므로 폐쇄망 RHEL 8 (기본
`python3` = 3.6.8) 서버에서 pip 없이 그대로 실행됩니다.

## 스캔 대상 (데이터 영역)

| 플랫폼 | 기본 스캔 루트 |
|---|---|
| Linux | `/shb*`, `/nbs*` 에 매칭되는 디렉터리 자동 인식 |
| Windows | `D:\` (데이터 드라이브) |

`config.json`의 `scan_roots`에 경로를 명시하면 그 값이 우선합니다.
`/proc`, `/sys`, `/dev`, `/run` 등 가상 영역은 기본 제외됩니다 (`linux_excludes`).

## 가치점수 로직

```
점수 = 100 × ( 0.6 × 2^(-접근경과일/30) + 0.4 × 2^(-수정경과일/90) )
```

- 접근(atime) 항: 반감기 30일 — 30일 접근이 없을 때마다 기여 점수가 절반
- 수정(mtime) 항: 반감기 90일
- 가중치·반감기는 `config.json`의 `score`에서 조정
- NTFS 등 atime 갱신이 비활성화된 경우 `atime < mtime`이면 mtime을 유효 접근시간으로 보정

| 등급 | 점수 | 표시 문구 |
|---|---|---|
| hot | 70 이상 | 자주 사용 |
| warm | 40–70 | 가끔 사용 |
| cold | 10–40 | 거의 안 씀 |
| stale | 10 미만 | 장기 미사용 — 정리 후보 |

등급 경계는 `config.json`의 `grades`, 정리 후보 기준(등급·최소 크기)은 `cleanup`에서 조정합니다.

## 실행

```bash
python3 server.py --host 0.0.0.0 --port 8000
```

pip, venv, 인터넷 연결 모두 불필요. 브라우저에서 `http://<서버IP>:<포트>` 접속 →
**스캔 시작**. 결과는 `data/fs_agent.db`(SQLite)에 저장되어 재시작 후에도 유지됩니다.

백그라운드 실행:

```bash
nohup python3 server.py --port 8000 > fs-agent.log 2>&1 &
```

## 폐쇄망 배포

인터넷이 되는 곳에서 소스 아카이브를 만들어 반입:

```bash
git archive --format=tar.gz -o fs-agent.tar.gz HEAD
```

폐쇄망 서버에서:

```bash
mkdir -p /opt/fs-agent && tar xzf fs-agent.tar.gz -C /opt/fs-agent
python3 /opt/fs-agent/server.py --port 8000
```

부팅 시 자동 시작(systemd):

```ini
# /etc/systemd/system/fs-agent.service
[Unit]
Description=Filesystem tracking agent
After=network.target

[Service]
WorkingDirectory=/opt/fs-agent
ExecStart=/usr/bin/python3 /opt/fs-agent/server.py --port 8000
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload && systemctl enable --now fs-agent
```

## 대시보드 구성

- 스캔 시작 / 스캔 취소 (취소하면 직전 완료 결과를 유지)
- 제목 아래에 스캔한 서버의 호스트명·IP 표시 (스캔 시작 시 수집, `scans` 기록과 `/api/scan/status`에 포함)
- KPI: 총 파일 수 · 총 용량 · 평균 가치점수 · 정리 후보 용량
- 가치점수 분포 히스토그램 (10점 구간)
- 등급 구성 스택바 (용량 기준)
- 디렉터리 트리: 목록 뷰(TreeSize식 펼침) / 격자 뷰(트리맵, 면적=용량·색=등급)
- 디렉터리 순위: 루트 기준 깊이별, 용량·정리 후보 용량·파일 수 순
- 파일 목록: 디렉터리·등급 필터 / 점수·용량·접근·수정 정렬 / 경로 검색

## API

| 메서드 | 경로 | 설명 |
|---|---|---|
| POST | `/api/scan` | 스캔 시작 (`{"root": "/shb1"}` 지정 시 해당 경로만, 생략 시 전체 데이터 영역) |
| POST | `/api/scan/cancel` | 진행 중인 스캔 취소 |
| GET | `/api/scan/status` | 최근 스캔 상태·진행률 (`running`/`cancelling`/`done`/`cancelled`/`error`) |
| GET | `/api/summary` | 전체 요약 + 등급별 집계 |
| GET | `/api/distribution` | 점수 10점 구간 히스토그램 |
| GET | `/api/tree` | 디렉터리 트리 탐색 (`path` 미지정 시 루트, 지정 시 하위 목록) |
| GET | `/api/top-dirs` | 디렉터리 순위 (`depth` 기본 1, `sort`=size/cleanup/files, `limit`) |
| GET | `/api/files` | 파일 목록 (root/grade/sort/order/q/limit) |
| GET | `/api/cleanup-candidates` | 저가치·대용량 정리 후보 (`config.json`의 `cleanup` 기준) |
| GET | `/api/history` | 스캔별 디렉터리 집계 이력 (`path` 미지정 시 스캔 루트) |

## 설정 (`config.json`)

| 키 | 기본값 | 설명 |
|---|---|---|
| `scan_roots` | `[]` | 지정 시 플랫폼 기본 루트 대신 사용 |
| `linux_excludes` / `windows_excludes` | 가상·OS 영역 | 제외할 경로 |
| `exclude_names` | `.git` 등 | 이름으로 제외할 디렉터리 |
| `score` | 0.6 / 0.4 / 30일 / 90일 | 가중치와 반감기 |
| `grades` | `{"hot": 70, "warm": 40, "cold": 10}` | 등급별 하한 점수 |
| `cleanup` | `{"grades": ["cold", "stale"], "min_size_mb": 0}` | 정리 후보 등급과 최소 크기 |
| `history` | `{"keep_scans": 10, "depth": 2}` | 루트별 보관할 완료 스캔 수와 이력에 남길 디렉터리 깊이 |
| `db_path` | `data/fs_agent.db` | SQLite 위치 |

`grades`나 `cleanup`을 바꾸면 다음 스캔부터 반영됩니다.

## 향후 확장 (2단계)

- LLM(Claude API) 연동: 스캔 결과 요약·정리 제안 자연어 리포트
- 스케줄 스캔(cron) 및 스냅샷 간 변화 추적 (`scan_history` 테이블에 스캔별 집계를 이미 보관)
- 다중 서버 중앙 수집형 구성
