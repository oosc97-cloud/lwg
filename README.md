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
./restart.sh          # 이 폴더의 fs-agent만 멈추고 다시 띄움 (로그: fs-agent.log)
./stop.sh             # 이 폴더의 fs-agent만 중지
python3 server.py     # 포그라운드 실행 (기본 0.0.0.0:15891)
```

pip, venv, 인터넷 연결 모두 불필요. 브라우저에서 `http://<서버IP>:15891` 접속 →
**스캔 시작**. 결과는 `data/fs_agent.db`(SQLite)에 저장되어 재시작 후에도 유지됩니다.

- 포트는 `config.json`의 `"port"`(기본 15891) 또는 `--port`로 바꿉니다 (`./restart.sh --port 15892`).
- **포트 충돌 방지**: 시작할 때 그 포트에 이미 LISTEN 중인 프로세스가 있으면 에이전트는 시작하지 않고
  메시지를 남긴 뒤 종료 코드 1로 끝납니다. 기존 프로세스는 건드리지 않습니다.
- 같은 폴더의 에이전트가 이미 떠 있으면(`fs-agent.pid`) 중복 실행도 거부합니다.
- `restart.sh`/`stop.sh`는 작업 폴더가 이 폴더인 `python3 server.py` 프로세스만 멈춥니다.
  같은 서버의 다른 프로그램(다른 폴더의 `server.py` 등)은 대상이 아닙니다.

## 에이전트 설치 (대상 서버, 권장)

운영자용 상세 설명은 [MANUAL.md](MANUAL.md)를 보세요.

설치 파일 하나로 설치·업그레이드·제거합니다. git, 인터넷, pip가 필요 없습니다.

```bash
# 개발 PC/테스트 서버에서 설치 파일 생성 → dist/fs-agent-install-<버전>.sh
./build-installer.sh

# 대상 서버(root)에서
sudo bash fs-agent-install-<버전>.sh                 # 설치 또는 업그레이드 (기본 /opt/fs-agent, 포트 15891)
sudo bash fs-agent-install-<버전>.sh --port 15892    # 다른 포트로
sudo bash fs-agent-install-<버전>.sh --status        # 버전·서비스 상태·접속 주소
sudo bash fs-agent-install-<버전>.sh --uninstall     # 제거 (스캔 결과 data/와 config.json은 남김)
sudo bash fs-agent-install-<버전>.sh --uninstall --purge   # 전부 삭제
```

설치 파일이 하는 일:
- python3 3.6 이상 확인 (없으면 RHEL 8의 `/usr/libexec/platform-python` 사용)
- 포트가 다른 프로세스에 사용 중이면 아무것도 건드리지 않고 중단
- `/opt/fs-agent`에 프로그램 설치. 업그레이드 때 `data/`(스캔 결과)와 `config.json`(설정)은 유지하고, 새 기본 설정은 `config.json.new`로 둠
- systemd 서비스 `fs-agent` 등록 후 시작 (낮은 CPU/IO 우선순위, 실패 시 30초 후 재시도). 부팅 시 자동 시작은 하지 않음: 재부팅 후 `systemctl start fs-agent`
- 방화벽은 건드리지 않음 (필요하면 서버 관리자가 직접 포트 개방)
- 스캔 대상이 `noatime` 마운트면 경고 (점수는 수정 시간 기준으로 보정)
- 기동 확인 후 접속 주소(IP·호스트명) 출력

설치 후 관리: `systemctl start|status|restart|stop fs-agent`, 로그는 `journalctl -u fs-agent`.

## 폐쇄망 배포

인터넷이 되는 곳에서 소스 아카이브를 만들어 반입:

```bash
git archive --format=tar.gz -o fs-agent.tar.gz HEAD
```

폐쇄망 서버에서:

```bash
mkdir -p /opt/fs-agent && tar xzf fs-agent.tar.gz -C /opt/fs-agent
cd /opt/fs-agent && ./restart.sh
```

## 대시보드 구성 (TreeSize 방식)

- 상단: 스캔 시작/취소, 초기화(확인 후 저장된 결과 전체 삭제, 스캔 중 비활성), 스캔한 서버의 호스트명·IP, 마지막 스캔 시각, **기준**(용량/할당 용량/파일 수)과 **단위**(자동/KB/MB/GB) 선택
- KPI: 총 용량 · 총 파일 수 · 총 폴더 수 · 평균 가치점수 · 정리 후보 용량
- 경로 표시줄: 선택한 폴더까지의 경로(클릭 이동), ↑ 상위
- 왼쪽 폴더 트리: 펼침(▶), 상위 대비 비중 막대·크기·%, `[파일 N개]` 행(그 폴더 바로 아래 파일 합계). 기준 선택에 따라 정렬·비중이 바뀜
- 오른쪽 탭 (모두 선택한 폴더 기준)
  - 상세: 하위 폴더 + 파일, 열 머리글 클릭 정렬 (이름·용량·할당·상위 대비 %·파일·폴더·최근 수정·최근 접근·점수·등급·정리 후보), 폴더 더블클릭으로 이동
  - 차트: 하위 항목 비중 도넛 차트 (상위 9개 + 기타)
  - 확장자: 하위 전체의 확장자별 파일 수·용량·비중·정리 후보
  - 파일 나이: 수정/접근 시간 기준 기간별(1개월 이내 ~ 3년 초과) 용량·파일 수
  - 상위 파일: 하위 전체에서 가장 큰 파일 100개
  - 트리맵: 면적 = 용량, 색 = 가치 등급, 폴더 클릭 시 이동
  - 파일 검색: 등급 필터·정렬·경로 검색 (최대 200개)
  - 변화: 최근 두 완료 스캔 비교 (루트 합계 + 1단계 폴더 증감)
- 할당 용량은 실제 디스크 사용량(`st_blocks × 512`)이라 희소 파일은 용량보다 작게 나옵니다. 폴더 수·할당·최근 수정/접근 열은 이 버전 이후 스캔부터 채워집니다.

## API

| 메서드 | 경로 | 설명 |
|---|---|---|
| POST | `/api/scan` | 스캔 시작 (`{"root": "/shb1"}` 지정 시 해당 경로만, 생략 시 전체 데이터 영역) |
| POST | `/api/scan/cancel` | 진행 중인 스캔 취소 |
| POST | `/api/reset` | 저장된 스캔 결과 전체 삭제(처음 상태로, 실제 파일은 그대로). 스캔 중이면 409 |
| GET | `/api/scan/status` | 최근 스캔 상태·진행률 (`running`/`cancelling`/`done`/`cancelled`/`error`) |
| GET | `/api/summary` | 전체 요약 + 등급별 집계 |
| GET | `/api/distribution` | 점수 10점 구간 히스토그램 |
| GET | `/api/tree` | 디렉터리 트리 탐색 (`path` 미지정 시 루트, 지정 시 `node`·하위 폴더·바로 아래 파일(`files_limit`, 기본 100)·`own_files` 합계). 폴더마다 용량·할당·파일 수·폴더 수·최근 수정/접근 포함 |
| GET | `/api/top-dirs` | 디렉터리 순위 (`depth` 기본 1, `sort`=size/cleanup/files, `limit`) |
| GET | `/api/files` | 파일 목록 (`root`=그 폴더 하위 전체, grade/sort(score·size·atime·mtime·name·path)/order/q/limit) |
| GET | `/api/cleanup-candidates` | 저가치·대용량 정리 후보 (`config.json`의 `cleanup` 기준) |
| GET | `/api/extensions` | 확장자별 파일 수·용량·정리 후보 용량 (`path`=그 폴더 하위로 한정, `limit` 최대 200) |
| GET | `/api/age` | 파일 나이 분포 (`by`=mtime/atime, `path`) |
| GET | `/api/changes` | 루트별 최근 두 완료 스캔 비교 (루트 합계 + 1단계 디렉터리 증감, `limit`) |
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
