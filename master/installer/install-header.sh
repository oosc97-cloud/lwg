#!/bin/bash
# =====================================================================
#  파일시스템 Master 설치 파일 (자체 압축 해제형)
#  여러 서버의 fs-agent를 한 화면에서 보는 통합 관리 서버
#  대상: RHEL 8.x (폐쇄망), python3 3.6 이상, systemd
#
#  설치/업그레이드 : sudo bash fs-master-install.sh [--port 15900] [--prefix /opt/fs-master]
#                    [--agent 10.0.0.5:15892 ...]  (수동 등록, 보통은 불필요: 에이전트를 --master 로 설치하면 자동 등록)
#  상태 확인       : sudo bash fs-master-install.sh --status
#  제거            : sudo bash fs-master-install.sh --uninstall [--purge]
#                    (--purge 없으면 등록 목록·수집 결과 data/와 config.json은 남김)
#  번들 풀기만     : bash fs-master-install.sh --extract <폴더>
# =====================================================================
set -u
VERSION="@VERSION@"
TMPD=""
SERVICE="fs-master"
PREFIX="/opt/fs-master"
PORT=""
ACTION="install"
PURGE=0
EXTRACT_DIR=""
AGENTS=()
UNIT_DIR="${FS_MASTER_UNIT_DIR:-/etc/systemd/system}"   # 테스트용으로만 바꿈

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
info() { echo "[fs-master] $*"; }
warn() { echo "[fs-master] 경고: $*" >&2; }
die()  { echo "[fs-master] 실패: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    --port=*) PORT="${1#*=}"; shift ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --prefix=*) PREFIX="${1#*=}"; shift ;;
    --agent) AGENTS+=("${2:-}"); shift 2 ;;
    --agent=*) AGENTS+=("${1#*=}"); shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --purge) PURGE=1; shift ;;
    --status) ACTION="status"; shift ;;
    --extract) ACTION="extract"; EXTRACT_DIR="${2:-}"; shift 2 ;;
    --version) echo "$VERSION"; exit 0 ;;
    -h|--help) usage 0 ;;
    *) echo "알 수 없는 옵션: $1"; usage 1 ;;
  esac
done
if [ -n "$PORT" ]; then
  case "$PORT" in *[!0-9]*|"") die "--port 값이 숫자가 아닙니다: $PORT" ;; esac
  [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port 범위는 1~65535 입니다: $PORT"
fi
UNIT_FILE="$UNIT_DIR/$SERVICE.service"

extract_bundle() {   # $1 = 대상 폴더
  local line
  line=$(awk '/^__FS_MASTER_ARCHIVE__$/ { print NR + 1; exit }' "$0")
  [ -n "$line" ] || die "설치 파일 안에 번들이 없습니다 (파일이 손상되었을 수 있음)."
  mkdir -p "$1" && tail -n +"$line" "$0" | tar -xzf - -C "$1" || die "번들 압축 해제 실패"
}

find_python() {
  local c
  for c in python3 /usr/bin/python3 /usr/libexec/platform-python python3.6 python3.8 python3.9; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' 2>/dev/null; then
      command -v "$c"; return 0
    fi
  done
  return 1
}

port_listening() {   # $1 = 포트. LISTEN 중이면 0
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk 'NR > 1 { print $4 }' | grep -Eq "[:.]$1\$"
    return $?
  fi
  "$PY" - "$1" <<'EOF'
import socket, sys
s = socket.socket()
s.settimeout(1)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)
EOF
}

config_port() {   # $1 = config.json 경로
  "$PY" - "$1" <<'EOF' 2>/dev/null || echo 15900
import json, sys
try:
    print(int(json.load(open(sys.argv[1], encoding="utf-8")).get("port", 15900)))
except Exception:
    print(15900)
EOF
}

set_config_port() {   # $1 = config.json, $2 = 포트 (다른 설정은 그대로 둠)
  "$PY" - "$1" "$2" <<'EOF' || die "config.json에 포트를 쓰지 못했습니다."
import json, sys
from collections import OrderedDict
path, port = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as f:
    cfg = json.load(f, object_pairs_hook=OrderedDict)
cfg["port"] = port
cfg.move_to_end("port", last=False)
# 이전 버전 기본값(에이전트 15891) → 마스터용 에이전트 포트 15892
if cfg.get("agent_default_port") == 15891:
    cfg["agent_default_port"] = 15892
    print("[fs-master] config.json: agent_default_port 15891 → 15892 (이미 등록한 에이전트 주소는 그대로)")
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
EOF
}

host_urls() {
  local ips ip
  ips=$(hostname -I 2>/dev/null)
  [ -n "$ips" ] || ips=$(hostname -i 2>/dev/null)
  for ip in $ips; do
    case "$ip" in 127.*|::1|*:*) continue ;; esac
    echo "  http://$ip:$1"
  done
  echo "  http://$(hostname 2>/dev/null || echo localhost):$1  (호스트명 $(hostname 2>/dev/null))"
}

register_agents() {   # --agent 로 받은 주소를 마스터에 등록 (이미 있으면 건너뜀)
  local a
  for a in "${AGENTS[@]}"; do
    [ -n "$a" ] || continue
    "$PY" - "$PORT" "$a" <<'EOF'
import json, sys, urllib.request, urllib.error
port, url = sys.argv[1], sys.argv[2]
req = urllib.request.Request("http://127.0.0.1:%s/api/agents" % port, method="POST",
                             data=json.dumps({"url": url}).encode("utf-8"),
                             headers={"Content-Type": "application/json"})
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
try:
    r = json.loads(opener.open(req, timeout=5).read().decode("utf-8"))
    print("[fs-master] 에이전트 등록: %s" % r.get("url", url))
except urllib.error.HTTPError as e:
    try:
        detail = json.loads(e.read().decode("utf-8")).get("detail", "")
    except ValueError:
        detail = "HTTP %d" % e.code
    print("[fs-master] 에이전트 등록 건너뜀 (%s): %s" % (url, detail))
EOF
  done
}

need_root() { [ "$(id -u)" = "0" ] || die "root 권한이 필요합니다. sudo bash $0 ... 로 실행하세요."; }

# ---------------------------------------------------------------------
do_extract() {
  [ -n "$EXTRACT_DIR" ] || die "--extract 뒤에 폴더를 지정하세요."
  extract_bundle "$EXTRACT_DIR"
  info "번들을 $EXTRACT_DIR 에 풀었습니다 (설치는 하지 않음)."
}

do_status() {
  echo "버전(설치 파일): $VERSION"
  if [ -f "$PREFIX/VERSION" ]; then echo "버전(설치됨)   : $(cat "$PREFIX/VERSION")"; else echo "설치됨        : 아니오 ($PREFIX 없음)"; fi
  [ -f "$UNIT_FILE" ] && systemctl --no-pager status "$SERVICE" 2>/dev/null | head -5
  if [ -f "$PREFIX/config.json" ]; then
    PY=$(find_python) || PY=python3
    echo "접속 주소:"; host_urls "$(config_port "$PREFIX/config.json")"
  fi
}

do_uninstall() {
  need_root
  if [ -f "$UNIT_FILE" ]; then
    systemctl disable --now "$SERVICE" >/dev/null 2>&1
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
    info "서비스 중지·삭제 완료"
  fi
  [ -d "$PREFIX" ] || { info "설치 폴더가 없습니다: $PREFIX"; return; }
  case "$PREFIX" in /|/opt|/usr|/etc|/root|/home|"") die "설치 폴더 경로가 위험해 삭제하지 않습니다: $PREFIX" ;; esac
  [ -f "$PREFIX/master_db.py" ] || [ -f "$PREFIX/data/fs_master.db" ] \
    || die "$PREFIX 가 fs-master 폴더로 보이지 않아 삭제하지 않습니다."
  if [ "$PURGE" = 1 ]; then
    rm -rf "$PREFIX"
    info "$PREFIX 전체 삭제 (등록 목록·수집 결과 포함)"
  else
    find "$PREFIX" -mindepth 1 -maxdepth 1 ! -name data ! -name config.json -exec rm -rf {} +
    info "프로그램 삭제 완료. 등록 목록·수집 결과($PREFIX/data)와 설정(config.json)은 남겼습니다. 모두 지우려면 --uninstall --purge"
  fi
}

do_install() {
  need_root
  command -v systemctl >/dev/null 2>&1 || die "systemd(systemctl)가 없습니다."
  PY=$(find_python) || die "python3 3.6 이상을 찾지 못했습니다. RHEL 8은 'dnf install python3' (또는 platform-python) 필요."
  info "설치 버전 $VERSION · 파이썬 $("$PY" -c 'import platform; print(platform.python_version())') ($PY)"
  [ -f "$PREFIX/server.py" ] && [ ! -f "$PREFIX/master_db.py" ] \
    && die "$PREFIX 에 fs-master가 아닌 프로그램이 있습니다. --prefix 로 다른 폴더를 지정하세요."

  local upgrade=0 old_port=""
  if [ -f "$PREFIX/master_db.py" ]; then
    upgrade=1
    [ -f "$PREFIX/config.json" ] && old_port=$(config_port "$PREFIX/config.json")
    info "기존 설치를 업그레이드합니다: $PREFIX ($(cat "$PREFIX/VERSION" 2>/dev/null || echo '버전 정보 없음'))"
  fi
  [ -n "$PORT" ] || PORT="${old_port:-15900}"

  # 우리 서비스가 그 포트를 쓰고 있다면 먼저 멈춘 뒤 확인 (다른 프로세스는 절대 건드리지 않음)
  local was_running=0
  if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then was_running=1; systemctl stop "$SERVICE"; sleep 1; fi
  if port_listening "$PORT"; then
    [ "$was_running" = 1 ] && systemctl start "$SERVICE"
    die "$PORT 포트를 이미 다른 프로세스가 사용 중입니다. 기존 프로세스는 건드리지 않았습니다.
        사용 중인 프로세스 확인: ss -ltnp | grep :$PORT
        다른 포트로 설치: sudo bash $0 --port <포트>"
  fi

  TMPD=$(mktemp -d /tmp/fs-master-install.XXXXXX) || die "임시 폴더 생성 실패"
  trap 'rm -rf "$TMPD"' EXIT
  local tmp="$TMPD"
  extract_bundle "$tmp"

  mkdir -p "$PREFIX/data"
  # 프로그램 파일 교체 (data/와 config.json은 보존)
  if [ "$upgrade" = 1 ]; then
    find "$PREFIX" -mindepth 1 -maxdepth 1 ! -name data ! -name config.json ! -name '*.log' -exec rm -rf {} +
  fi
  if [ -f "$PREFIX/config.json" ]; then
    mv "$tmp/config.json" "$PREFIX/config.json.new"
    info "기존 config.json 유지 (새 기본 설정은 config.json.new 참고)"
  fi
  cp -a "$tmp/." "$PREFIX/"
  set_config_port "$PREFIX/config.json" "$PORT"
  chown -R root:root "$PREFIX"
  chmod 750 "$PREFIX/data"
  rm -f "$PREFIX/fs-master.pid"

  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=파일시스템 Master (fs-master $VERSION)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$PREFIX
ExecStart=$PY -u $PREFIX/server.py --host 0.0.0.0
Restart=on-failure
RestartSec=30
# 실패하면 30초 간격으로 재시도. 로그는 journalctl -u fs-master
Nice=10
# 부팅 시 자동 시작하지 않음 ([Install] 없음). 재부팅 후에는 systemctl start fs-master 로 수동 시작
EOF
  systemctl daemon-reload
  systemctl restart "$SERVICE" || die "서비스 시작 실패: journalctl -u $SERVICE 확인"

  # 기동 확인 (최대 15초)
  local ok=0 i
  for i in $(seq 1 15); do
    if "$PY" - "$PORT" <<'EOF' 2>/dev/null
import sys, urllib.request
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
opener.open("http://127.0.0.1:%s/api/agents" % sys.argv[1], timeout=2).read()
EOF
    then ok=1; break; fi
    sleep 1
  done
  if [ "$ok" = 1 ]; then
    register_agents
    info "설치 완료 ($( [ "$upgrade" = 1 ] && echo 업그레이드 || echo 신규 설치)). 브라우저에서 접속:"
    host_urls "$PORT"
    echo
    local myip
    myip=$(hostname -I 2>/dev/null | awk '{print $1}')
    local maddr="${myip:-<마스터IP>}$( [ "$PORT" = 15900 ] || echo ":$PORT")"
    echo "  에이전트 추가: 각 서버(root)에서 아래 한 줄이면 마스터에서 설치 파일을 받아 설치하고 자동 등록됩니다."
    echo "      cd /tmp && curl -fsS -o fs-agent-m-install.sh http://$maddr/dl/fs-agent-m-install.sh && bash fs-agent-m-install.sh --master $maddr"
    echo "  에이전트 업그레이드: 각 서버(root)에서"
    echo "      cd /tmp && curl -fsS -o fs-agent-m-install.sh http://$maddr/dl/fs-agent-m-install.sh && bash fs-agent-m-install.sh"
    echo "  마스터 ↔ 에이전트 사이에 $PORT(마스터)·15892(에이전트) 포트가 열려 있어야 합니다 (방화벽은 건드리지 않음)."
    echo "  상태: systemctl status $SERVICE   로그: journalctl -u $SERVICE"
    echo "  재시작: systemctl restart $SERVICE   제거: sudo bash $0 --uninstall"
    echo "  부팅 시 자동 시작하지 않습니다. 서버 재부팅 후에는 systemctl start $SERVICE 로 시작하세요."
  else
    journalctl -u "$SERVICE" -n 5 --no-pager 2>/dev/null
    die "서비스가 응답하지 않습니다. 위 로그와 'systemctl status $SERVICE'를 확인하세요."
  fi
}

case "$ACTION" in
  install) do_install ;;
  uninstall) do_uninstall ;;
  status) do_status ;;
  extract) do_extract ;;
esac
exit 0
__FS_MASTER_ARCHIVE__
