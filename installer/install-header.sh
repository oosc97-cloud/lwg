#!/bin/bash
# =====================================================================
#  파일시스템 Agent 설치 파일 (자체 압축 해제형)
#  대상: RHEL 8.x (폐쇄망), python3 3.6 이상, systemd
#
#  설치/업그레이드 : sudo bash fs-agent-install.sh [--port 15891] [--prefix /opt/fs-agent]
#  상태 확인       : sudo bash fs-agent-install.sh --status
#  제거            : sudo bash fs-agent-install.sh --uninstall [--purge]
#                    (--purge 없으면 스캔 결과 data/와 config.json은 남김)
#  번들 풀기만     : bash fs-agent-install.sh --extract <폴더>
# =====================================================================
set -u
VERSION="@VERSION@"
TMPD=""
SERVICE="fs-agent"
PREFIX="/opt/fs-agent"
PORT=""
ACTION="install"
PURGE=0
EXTRACT_DIR=""
UNIT_DIR="${FS_AGENT_UNIT_DIR:-/etc/systemd/system}"   # 테스트용으로만 바꿈

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
info() { echo "[fs-agent] $*"; }
warn() { echo "[fs-agent] 경고: $*" >&2; }
die()  { echo "[fs-agent] 실패: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    --port=*) PORT="${1#*=}"; shift ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --prefix=*) PREFIX="${1#*=}"; shift ;;
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
  line=$(awk '/^__FS_AGENT_ARCHIVE__$/ { print NR + 1; exit }' "$0")
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
  "$PY" - "$1" <<'EOF' 2>/dev/null || echo 15891
import json, sys
try:
    print(int(json.load(open(sys.argv[1], encoding="utf-8")).get("port", 15891)))
except Exception:
    print(15891)
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
# 이전 버전 설정 정리: 제외 목록 방식 → 포함 목록(scan_include) 방식
for k in ("linux_excludes", "windows_excludes", "exclude_names"):
    if cfg.pop(k, None) is not None:
        print("[fs-agent] config.json: 더 이상 쓰지 않는 설정 '%s' 삭제 (이제 포함 대상만 스캔)" % k)
old_roots = cfg.pop("scan_roots", None)
if "scan_include" not in cfg:
    inc = OrderedDict([("linux", ["/shb*", "/nbs*"]), ("windows", ["D:\\"])])
    if old_roots:
        inc["linux"] = list(old_roots)
        print("[fs-agent] config.json: 기존 scan_roots %s 를 scan_include.linux 로 옮김" % old_roots)
    items = list(cfg.items())
    cfg = OrderedDict(items[:1] + [("scan_include", inc)] + items[1:])
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

check_noatime() {   # 스캔 대상의 마운트 옵션 확인 (경고만)
  local roots r opts
  roots=$("$PY" - "$PREFIX" <<'EOF' 2>/dev/null
import sys
sys.path.insert(0, sys.argv[1])
from app.config import load_config, resolve_scan_roots
for r in resolve_scan_roots(load_config()):
    print(r)
EOF
)
  if [ -z "$roots" ]; then
    warn "스캔 대상 폴더가 없습니다 (포함 대상: /shb*, /nbs*). 이 상태에서는 아무것도 스캔하지 않습니다. 필요하면 $PREFIX/config.json의 scan_include를 수정하세요."
    return
  fi
  info "스캔 대상: $(echo $roots)"
  command -v findmnt >/dev/null 2>&1 || return
  for r in $roots; do
    opts=$(findmnt -no OPTIONS -T "$r" 2>/dev/null)
    case ",$opts," in
      *,noatime,*) warn "$r 는 noatime 마운트라 접근 시간(atime)이 갱신되지 않습니다. 가치점수는 수정 시간 기준으로 보정해 계산합니다." ;;
    esac
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
  [ -f "$PREFIX/server.py" ] || [ -f "$PREFIX/data/fs_agent.db" ] || [ -f "$PREFIX/config.json" ] \
    || die "$PREFIX 가 fs-agent 폴더로 보이지 않아 삭제하지 않습니다."
  if [ "$PURGE" = 1 ]; then
    rm -rf "$PREFIX"
    info "$PREFIX 전체 삭제 (스캔 결과 포함)"
  else
    find "$PREFIX" -mindepth 1 -maxdepth 1 ! -name data ! -name config.json -exec rm -rf {} +
    info "프로그램 삭제 완료. 스캔 결과($PREFIX/data)와 설정(config.json)은 남겼습니다. 모두 지우려면 --uninstall --purge"
  fi
}

do_install() {
  need_root
  command -v systemctl >/dev/null 2>&1 || die "systemd(systemctl)가 없습니다."
  PY=$(find_python) || die "python3 3.6 이상을 찾지 못했습니다. RHEL 8은 'dnf install python3' (또는 platform-python) 필요."
  info "설치 버전 $VERSION · 파이썬 $("$PY" -c 'import platform; print(platform.python_version())') ($PY)"

  local upgrade=0 old_port=""
  if [ -f "$PREFIX/server.py" ]; then
    upgrade=1
    [ -f "$PREFIX/config.json" ] && old_port=$(config_port "$PREFIX/config.json")
    info "기존 설치를 업그레이드합니다: $PREFIX ($(cat "$PREFIX/VERSION" 2>/dev/null || echo '버전 정보 없음'))"
  fi
  [ -n "$PORT" ] || PORT="${old_port:-15891}"

  # 우리 서비스가 그 포트를 쓰고 있다면 먼저 멈춘 뒤 확인 (다른 프로세스는 절대 건드리지 않음)
  local was_running=0
  if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then was_running=1; systemctl stop "$SERVICE"; sleep 1; fi
  if port_listening "$PORT"; then
    [ "$was_running" = 1 ] && systemctl start "$SERVICE"
    die "$PORT 포트를 이미 다른 프로세스가 사용 중입니다. 기존 프로세스는 건드리지 않았습니다.
        사용 중인 프로세스 확인: ss -ltnp | grep :$PORT
        다른 포트로 설치: sudo bash $0 --port <포트>"
  fi

  TMPD=$(mktemp -d /tmp/fs-agent-install.XXXXXX) || die "임시 폴더 생성 실패"
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
  rm -f "$PREFIX/fs-agent.pid"

  # 이전 설치본이 부팅 시 자동 시작으로 등록했던 경우 해제 (유닛을 덮어쓰기 전에 해야 함)
  [ -f "$UNIT_FILE" ] && systemctl disable "$SERVICE" >/dev/null 2>&1
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=파일시스템 Agent (fs-agent $VERSION)
After=network-online.target local-fs.target remote-fs.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$PREFIX
ExecStart=$PY -u $PREFIX/server.py --host 0.0.0.0
Restart=on-failure
RestartSec=30
# 포트 충돌(종료 코드 1) 등으로 실패하면 30초 간격으로 재시도. 로그는 journalctl -u fs-agent
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
# 부팅 시 자동 시작하지 않음 ([Install] 없음). 재부팅 후에는 systemctl start fs-agent 로 수동 시작
EOF
  systemctl daemon-reload
  systemctl restart "$SERVICE" || die "서비스 시작 실패: journalctl -u $SERVICE 확인"

  # 기동 확인 (최대 15초)
  local ok=0 i
  for i in $(seq 1 15); do
    if "$PY" - "$PORT" <<'EOF' 2>/dev/null
import sys, urllib.request
urllib.request.urlopen("http://127.0.0.1:%s/api/scan/status" % sys.argv[1], timeout=2).read()
EOF
    then ok=1; break; fi
    sleep 1
  done
  check_noatime
  if [ "$ok" = 1 ]; then
    info "설치 완료 ($( [ "$upgrade" = 1 ] && echo 업그레이드 || echo 신규 설치)). 브라우저에서 접속:"
    host_urls "$PORT"
    echo
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
__FS_AGENT_ARCHIVE__
