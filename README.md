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

- KPI: 총 파일 수 · 총 용량 · 평균 가치점수 · 정리 후보 용량
- 가치점수 분포 히스토그램 (10점 구간)
- 등급 구성 스택바 (용량 기준)
- 디렉터리 트리: 목록 뷰(TreeSize식 펼침) / 격자 뷰(트리맵, 면적=용량·색=등급)
- 파일 목록: 디렉터리·등급 필터 / 점수·용량·접근·수정 정렬 / 경로 검색

## API

| 메서드 | 경로 | 설명 |
|---|---|---|
| POST | `/api/scan` | 스캔 시작 (`{"root": "/shb1"}` 지정 시 해당 경로만, 생략 시 전체 데이터 영역) |
| GET | `/api/scan/status` | 최근 스캔 상태·진행률 |
| GET | `/api/summary` | 전체 요약 + 등급별 집계 |
| GET | `/api/distribution` | 점수 10점 구간 히스토그램 |
| GET | `/api/tree` | 디렉터리 트리 탐색 (`path` 미지정 시 루트, 지정 시 하위 목록) |
| GET | `/api/top-dirs` | 상위 디렉터리 집계 |
| GET | `/api/files` | 파일 목록 (root/grade/sort/order/q/limit) |
| GET | `/api/cleanup-candidates` | 저가치·대용량 정리 후보 |

## 향후 확장 (2단계)

- LLM(Claude API) 연동: 스캔 결과 요약·정리 제안 자연어 리포트
- 스케줄 스캔(cron) 및 스냅샷 간 변화 추적
- 다중 서버 중앙 수집형 구성
