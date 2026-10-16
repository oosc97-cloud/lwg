# 파일시스템 Master (fs-master)

여러 서버에 설치한 **fs-agent**를 한 화면에서 모아 보는 통합 관리 서버입니다.
각 서버에는 **마스터 연동용 에이전트**(`fs-agent-m-install.sh`)를 마스터 IP를 넣어 설치하면 마스터에 자동 등록됩니다.
기존 단독 실행용 release(`fs-agent-install.sh`, 포트 15891)는 그대로입니다.

- 표준 라이브러리만 사용 (Python 3.6+, pip·인터넷 불필요) — 폐쇄망 RHEL 8에서 그대로 실행
- 기본 포트 **15900** (에이전트는 15892)

## 구조

```
[에이전트 A 15892] ──(등록 신호, 5분마다)──▶ [마스터 15900] ◀── 브라우저: 통합 화면 + 서버별 상세 화면
[에이전트 B 15892] ──────────────────────▶      │
        ▲                                         │
        └──────────(요약 수집, 5분마다)───────────┘
```

- 에이전트를 `--master <마스터IP>`로 설치하면 에이전트가 마스터의 `/api/register`로 자기 포트·호스트명·고유 키를 보냅니다.
  마스터는 **접속해 온 IP + 포트**로 주소를 만들어 목록에 올립니다. 마스터 화면에서 IP를 입력할 필요가 없습니다.
- 등록 신호는 5분마다 다시 보내므로 서버 IP가 바뀌어도 같은 서버(고유 키 `data/agent_key`)로 알아보고 주소만 바꿉니다.
  마스터가 꺼져 있으면 에이전트는 30초마다 다시 시도하고, 그동안 에이전트 자체 동작에는 영향이 없습니다.

- 마스터가 등록된 각 에이전트의 기존 API(`/api/scan/status`, `/api/summary`, `/api/tree`,
  `/api/roots`, `/api/cleanup-candidates`)를 **5분마다** 읽어 저장합니다. 스캔 중인 에이전트는 10초마다 진행 상황만 읽습니다.
- 필요한 접속: 에이전트 → 마스터 15900 (등록), 마스터 → 에이전트 15892 (수집·상세 화면).
- 에이전트가 꺼져 있어도 마지막으로 받은 요약은 그대로 보여 주고 상태만 "연결 실패"로 표시합니다.

## 화면

- 상단: 전체 수집, 전체 스캔(사용 중인 모든 에이전트에 스캔 요청), 단위(기본 GB)
- 서버 탭의 체크박스로 고른 서버만: 선택 수집 · 선택 스캔 · 선택 삭제 (머리글 체크박스 = 전체 선택)
- KPI: 서버(정상/사용 중) · 총 용량 · 총 파일 수 · 평균 가치점수(파일 수 가중) · 정리 후보 용량
- 전체 서버 등급별 용량 막대
- 탭
  - **서버**: 서버별 상태·호스트명/IP·총 용량·파일 수·평균 점수·등급 비중·정리 후보·스캔 상태·마지막 수집, 열 정렬.
    서버 이름(또는 [열기])을 누르면 그 서버의 **상세 화면**(에이전트 대시보드 그대로: 폴더 트리·차트·검색·트리맵 등)이
    마스터를 통해 열립니다. 상단의 "← 통합 화면"으로 돌아옵니다.
  - **스캔 대상 폴더**: 모든 서버의 최상위 스캔 폴더를 용량 큰 순으로
  - **정리 후보**: 서버별 큰 순 상위 100개를 모아 용량 큰 순으로 (서버별 필터)
  - **서버 관리**: 에이전트 설치 명령 안내, 등록 방식(자동/수동)·마지막 신호, 이름 변경, 사용 중지, 삭제.
    자동 등록을 쓸 수 없을 때만 주소로 직접 추가 (자동 등록된 서버를 삭제해도 에이전트가 켜져 있으면 다음 신호 때 다시 나타남)

## 설치 (마스터 서버, root)

```bash
sudo bash fs-master-install.sh                       # 설치 또는 업그레이드 (/opt/fs-master, 포트 15900)
sudo bash fs-master-install.sh --agent 10.0.0.5     # (보통 불필요) 수동 등록
sudo bash fs-master-install.sh --port 15901          # 다른 포트로
sudo bash fs-master-install.sh --status              # 버전·서비스 상태·접속 주소
sudo bash fs-master-install.sh --uninstall [--purge] # 제거 (--purge 없으면 data/와 config.json 남김)
```

- systemd 서비스 `fs-master` 등록 후 시작 (부팅 시 자동 시작은 하지 않음: 재부팅 후 `systemctl start fs-master`)
- 포트가 다른 프로세스에 사용 중이면 아무것도 건드리지 않고 중단, 방화벽은 건드리지 않음
- 업그레이드 때 `data/`(등록 목록·수집 결과)와 `config.json`은 유지

## 에이전트 설치 (각 서버, root)

```bash
sudo bash fs-agent-m-install.sh --master 10.0.0.9          # 마스터 IP (포트 생략 시 15900)
sudo bash fs-agent-m-install.sh --master 10.0.0.9:15901    # 마스터 포트가 다를 때
sudo bash fs-agent-m-install.sh                            # 업그레이드 (마스터 주소는 config.json에 남아 있음)
sudo bash fs-agent-m-install.sh --status | --uninstall [--purge]
```

- systemd 서비스 `fs-agent-m`, 설치 폴더 `/opt/fs-agent-m`, 포트 **15892**. 스캔·점수 기능은 단독 에이전트와 같습니다.
- **웹 화면 없음** (`config.json` `"web_ui": false`): 15892는 마스터의 수집 요청(API)만 받고 웹 페이지는 없습니다 (404).
  서버별 상세 화면은 마스터가 자체로 가진 대시보드로 보여 줍니다. 웹으로 여는 주소는 마스터 15900 하나뿐입니다.
- 처음 설치할 때 `--master`가 없으면 설치하지 않습니다. 설치 끝에 마스터 등록 성공 여부를 보여 줍니다.
- 단독용 `fs-agent`(15891, `/opt/fs-agent`)와 이름·포트·폴더가 달라 한 서버에 같이 있어도 서로 영향이 없습니다.
- 마스터 주소를 바꾸려면 `--master <새 주소>`로 다시 실행하거나 `/opt/fs-agent-m/config.json`의 `"master"`를 고치고 재시작.
- 같은 서버에 에이전트와 마스터를 함께 설치해도 됩니다.

## 설치 파일 만들기 (개발 PC/테스트 서버)

```bash
master/build-installer.sh                       # dist/fs-master-install-<버전>.sh
master/build-installer.sh --release             # + release/fs-master-install.sh (저장소에 커밋)
./build-installer.sh --master-edition [--release]   # 마스터 연동 에이전트 dist/fs-agent-m-install-<버전>.sh (+ release/)
```

## 직접 실행 (설치 없이)

```bash
cd master && ./restart.sh     # 이 폴더의 fs-master만 재기동 (로그 fs-master.log)
cd master && ./stop.sh
python3 master/server.py --port 15900
```

## 설정 (`config.json`)

| 키 | 기본값 | 설명 |
|---|---|---|
| `port` | 15900 | 마스터 화면 포트 |
| `agent_default_port` | 15892 | 주소에 포트를 생략했을 때 붙일 에이전트 포트 |
| `poll_interval_sec` | 300 | 에이전트 요약 수집 주기(초) |
| `scan_poll_sec` | 10 | 스캔 중인 에이전트의 진행 상황 수집 주기(초) |
| `request_timeout_sec` | 10 | 에이전트 요청 제한 시간(초) |
| `max_parallel` | 8 | 동시에 수집할 에이전트 수 |
| `cleanup_top_per_agent` | 100 | 에이전트별로 가져올 정리 후보 개수 |
| `allow_agent_control` | true | 마스터 화면에서 에이전트 스캔 시작/취소/초기화 허용. false면 보기 전용 |
| `db_path` | data/fs_master.db | 등록 목록·수집 결과 저장 위치 |

## API

| 메서드 | 경로 | 설명 |
|---|---|---|
| GET | `/api/agents` | 등록된 에이전트와 마지막 수집 결과 |
| GET | `/api/cleanup?agent=&limit=` | 서버 통합 정리 후보 (용량 큰 순) |
| POST | `/api/register` `{agent_key, port, hostname}` | 에이전트 자동 등록 (에이전트가 호출, 주소 = 접속 IP + port) |
| POST | `/api/agents` `{url, name}` | 에이전트 수동 등록 |
| POST | `/api/agents/<id>/update` `{name?, url?, enabled?}` | 변경 |
| POST | `/api/agents/<id>/delete` | 목록에서 삭제 (에이전트는 건드리지 않음) |
| POST | `/api/agents/<id>/poll`, `/api/poll` | 즉시 수집 (한 대 / 전체) |
| POST | `/api/scan-all` | 사용 중인 모든 에이전트에 스캔 시작 요청 |
| GET/POST | `/agent/<id>/...` | 에이전트 화면·API 중계 (POST는 scan, scan/cancel, reset만) |
