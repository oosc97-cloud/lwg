#!/bin/bash
# =====================================================================
#  íŒŒì¼ì‹œìŠ¤í…œ Master ì„¤ì¹˜ íŒŒì¼ (ìžì²´ ì••ì¶• í•´ì œí˜•)
#  ì—¬ëŸ¬ ì„œë²„ì˜ fs-agentë¥¼ í•œ í™”ë©´ì—ì„œ ë³´ëŠ” í†µí•© ê´€ë¦¬ ì„œë²„
#  ëŒ€ìƒ: RHEL 8.x (íì‡„ë§), python3 3.6 ì´ìƒ, systemd
#
#  ì„¤ì¹˜/ì—…ê·¸ë ˆì´ë“œ : sudo bash fs-master-install.sh [--port 15900] [--prefix /opt/fs-master]
#                    [--agent 10.0.0.5:15892 ...]  (ìˆ˜ë™ ë“±ë¡, ë³´í†µì€ ë¶ˆí•„ìš”: ì—ì´ì „íŠ¸ë¥¼ --master ë¡œ ì„¤ì¹˜í•˜ë©´ ìžë™ ë“±ë¡)
#  ìƒíƒœ í™•ì¸       : sudo bash fs-master-install.sh --status
#  ì œê±°            : sudo bash fs-master-install.sh --uninstall [--purge]
#                    (--purge ì—†ìœ¼ë©´ ë“±ë¡ ëª©ë¡Â·ìˆ˜ì§‘ ê²°ê³¼ data/ì™€ config.jsonì€ ë‚¨ê¹€)
#  ë²ˆë“¤ í’€ê¸°ë§Œ     : bash fs-master-install.sh --extract <í´ë”>
# =====================================================================
set -u
VERSION="20261016-bc74c81"
TMPD=""
SERVICE="fs-master"
PREFIX="/opt/fs-master"
PORT=""
ACTION="install"
PURGE=0
EXTRACT_DIR=""
AGENTS=()
UNIT_DIR="${FS_MASTER_UNIT_DIR:-/etc/systemd/system}"   # í…ŒìŠ¤íŠ¸ìš©ìœ¼ë¡œë§Œ ë°”ê¿ˆ

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
info() { echo "[fs-master] $*"; }
warn() { echo "[fs-master] ê²½ê³ : $*" >&2; }
die()  { echo "[fs-master] ì‹¤íŒ¨: $*" >&2; exit 1; }

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
    *) echo "ì•Œ ìˆ˜ ì—†ëŠ” ì˜µì…˜: $1"; usage 1 ;;
  esac
done
if [ -n "$PORT" ]; then
  case "$PORT" in *[!0-9]*|"") die "--port ê°’ì´ ìˆ«ìžê°€ ì•„ë‹™ë‹ˆë‹¤: $PORT" ;; esac
  [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port ë²”ìœ„ëŠ” 1~65535 ìž…ë‹ˆë‹¤: $PORT"
fi
UNIT_FILE="$UNIT_DIR/$SERVICE.service"

extract_bundle() {   # $1 = ëŒ€ìƒ í´ë”
  local line
  line=$(awk '/^__FS_MASTER_ARCHIVE__$/ { print NR + 1; exit }' "$0")
  [ -n "$line" ] || die "ì„¤ì¹˜ íŒŒì¼ ì•ˆì— ë²ˆë“¤ì´ ì—†ìŠµë‹ˆë‹¤ (íŒŒì¼ì´ ì†ìƒë˜ì—ˆì„ ìˆ˜ ìžˆìŒ)."
  mkdir -p "$1" && tail -n +"$line" "$0" | tar -xzf - -C "$1" || die "ë²ˆë“¤ ì••ì¶• í•´ì œ ì‹¤íŒ¨"
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

port_listening() {   # $1 = í¬íŠ¸. LISTEN ì¤‘ì´ë©´ 0
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

config_port() {   # $1 = config.json ê²½ë¡œ
  "$PY" - "$1" <<'EOF' 2>/dev/null || echo 15900
import json, sys
try:
    print(int(json.load(open(sys.argv[1], encoding="utf-8")).get("port", 15900)))
except Exception:
    print(15900)
EOF
}

set_config_port() {   # $1 = config.json, $2 = í¬íŠ¸ (ë‹¤ë¥¸ ì„¤ì •ì€ ê·¸ëŒ€ë¡œ ë‘ )
  "$PY" - "$1" "$2" <<'EOF' || die "config.jsonì— í¬íŠ¸ë¥¼ ì“°ì§€ ëª»í–ˆìŠµë‹ˆë‹¤."
import json, sys
from collections import OrderedDict
path, port = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as f:
    cfg = json.load(f, object_pairs_hook=OrderedDict)
cfg["port"] = port
cfg.move_to_end("port", last=False)
# ì´ì „ ë²„ì „ ê¸°ë³¸ê°’(ì—ì´ì „íŠ¸ 15891) â†’ ë§ˆìŠ¤í„°ìš© ì—ì´ì „íŠ¸ í¬íŠ¸ 15892
if cfg.get("agent_default_port") == 15891:
    cfg["agent_default_port"] = 15892
    print("[fs-master] config.json: agent_default_port 15891 â†’ 15892 (ì´ë¯¸ ë“±ë¡í•œ ì—ì´ì „íŠ¸ ì£¼ì†ŒëŠ” ê·¸ëŒ€ë¡œ)")
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
  echo "  http://$(hostname 2>/dev/null || echo localhost):$1  (í˜¸ìŠ¤íŠ¸ëª… $(hostname 2>/dev/null))"
}

register_agents() {   # --agent ë¡œ ë°›ì€ ì£¼ì†Œë¥¼ ë§ˆìŠ¤í„°ì— ë“±ë¡ (ì´ë¯¸ ìžˆìœ¼ë©´ ê±´ë„ˆëœ€)
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
    print("[fs-master] ì—ì´ì „íŠ¸ ë“±ë¡: %s" % r.get("url", url))
except urllib.error.HTTPError as e:
    try:
        detail = json.loads(e.read().decode("utf-8")).get("detail", "")
    except ValueError:
        detail = "HTTP %d" % e.code
    print("[fs-master] ì—ì´ì „íŠ¸ ë“±ë¡ ê±´ë„ˆëœ€ (%s): %s" % (url, detail))
EOF
  done
}

need_root() { [ "$(id -u)" = "0" ] || die "root ê¶Œí•œì´ í•„ìš”í•©ë‹ˆë‹¤. sudo bash $0 ... ë¡œ ì‹¤í–‰í•˜ì„¸ìš”."; }

# ---------------------------------------------------------------------
do_extract() {
  [ -n "$EXTRACT_DIR" ] || die "--extract ë’¤ì— í´ë”ë¥¼ ì§€ì •í•˜ì„¸ìš”."
  extract_bundle "$EXTRACT_DIR"
  info "ë²ˆë“¤ì„ $EXTRACT_DIR ì— í’€ì—ˆìŠµë‹ˆë‹¤ (ì„¤ì¹˜ëŠ” í•˜ì§€ ì•ŠìŒ)."
}

do_status() {
  echo "ë²„ì „(ì„¤ì¹˜ íŒŒì¼): $VERSION"
  if [ -f "$PREFIX/VERSION" ]; then echo "ë²„ì „(ì„¤ì¹˜ë¨)   : $(cat "$PREFIX/VERSION")"; else echo "ì„¤ì¹˜ë¨        : ì•„ë‹ˆì˜¤ ($PREFIX ì—†ìŒ)"; fi
  [ -f "$UNIT_FILE" ] && systemctl --no-pager status "$SERVICE" 2>/dev/null | head -5
  if [ -f "$PREFIX/config.json" ]; then
    PY=$(find_python) || PY=python3
    echo "ì ‘ì† ì£¼ì†Œ:"; host_urls "$(config_port "$PREFIX/config.json")"
  fi
}

do_uninstall() {
  need_root
  if [ -f "$UNIT_FILE" ]; then
    systemctl disable --now "$SERVICE" >/dev/null 2>&1
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
    info "ì„œë¹„ìŠ¤ ì¤‘ì§€Â·ì‚­ì œ ì™„ë£Œ"
  fi
  [ -d "$PREFIX" ] || { info "ì„¤ì¹˜ í´ë”ê°€ ì—†ìŠµë‹ˆë‹¤: $PREFIX"; return; }
  case "$PREFIX" in /|/opt|/usr|/etc|/root|/home|"") die "ì„¤ì¹˜ í´ë” ê²½ë¡œê°€ ìœ„í—˜í•´ ì‚­ì œí•˜ì§€ ì•ŠìŠµë‹ˆë‹¤: $PREFIX" ;; esac
  [ -f "$PREFIX/master_db.py" ] || [ -f "$PREFIX/data/fs_master.db" ] \
    || die "$PREFIX ê°€ fs-master í´ë”ë¡œ ë³´ì´ì§€ ì•Šì•„ ì‚­ì œí•˜ì§€ ì•ŠìŠµë‹ˆë‹¤."
  if [ "$PURGE" = 1 ]; then
    rm -rf "$PREFIX"
    info "$PREFIX ì „ì²´ ì‚­ì œ (ë“±ë¡ ëª©ë¡Â·ìˆ˜ì§‘ ê²°ê³¼ í¬í•¨)"
  else
    find "$PREFIX" -mindepth 1 -maxdepth 1 ! -name data ! -name config.json -exec rm -rf {} +
    info "í”„ë¡œê·¸ëž¨ ì‚­ì œ ì™„ë£Œ. ë“±ë¡ ëª©ë¡Â·ìˆ˜ì§‘ ê²°ê³¼($PREFIX/data)ì™€ ì„¤ì •(config.json)ì€ ë‚¨ê²¼ìŠµë‹ˆë‹¤. ëª¨ë‘ ì§€ìš°ë ¤ë©´ --uninstall --purge"
  fi
}

do_install() {
  need_root
  command -v systemctl >/dev/null 2>&1 || die "systemd(systemctl)ê°€ ì—†ìŠµë‹ˆë‹¤."
  PY=$(find_python) || die "python3 3.6 ì´ìƒì„ ì°¾ì§€ ëª»í–ˆìŠµë‹ˆë‹¤. RHEL 8ì€ 'dnf install python3' (ë˜ëŠ” platform-python) í•„ìš”."
  info "ì„¤ì¹˜ ë²„ì „ $VERSION Â· íŒŒì´ì¬ $("$PY" -c 'import platform; print(platform.python_version())') ($PY)"
  [ -f "$PREFIX/server.py" ] && [ ! -f "$PREFIX/master_db.py" ] \
    && die "$PREFIX ì— fs-masterê°€ ì•„ë‹Œ í”„ë¡œê·¸ëž¨ì´ ìžˆìŠµë‹ˆë‹¤. --prefix ë¡œ ë‹¤ë¥¸ í´ë”ë¥¼ ì§€ì •í•˜ì„¸ìš”."

  local upgrade=0 old_port=""
  if [ -f "$PREFIX/master_db.py" ]; then
    upgrade=1
    [ -f "$PREFIX/config.json" ] && old_port=$(config_port "$PREFIX/config.json")
    info "ê¸°ì¡´ ì„¤ì¹˜ë¥¼ ì—…ê·¸ë ˆì´ë“œí•©ë‹ˆë‹¤: $PREFIX ($(cat "$PREFIX/VERSION" 2>/dev/null || echo 'ë²„ì „ ì •ë³´ ì—†ìŒ'))"
  fi
  [ -n "$PORT" ] || PORT="${old_port:-15900}"

  # ìš°ë¦¬ ì„œë¹„ìŠ¤ê°€ ê·¸ í¬íŠ¸ë¥¼ ì“°ê³  ìžˆë‹¤ë©´ ë¨¼ì € ë©ˆì¶˜ ë’¤ í™•ì¸ (ë‹¤ë¥¸ í”„ë¡œì„¸ìŠ¤ëŠ” ì ˆëŒ€ ê±´ë“œë¦¬ì§€ ì•ŠìŒ)
  local was_running=0
  if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then was_running=1; systemctl stop "$SERVICE"; sleep 1; fi
  if port_listening "$PORT"; then
    [ "$was_running" = 1 ] && systemctl start "$SERVICE"
    die "$PORT í¬íŠ¸ë¥¼ ì´ë¯¸ ë‹¤ë¥¸ í”„ë¡œì„¸ìŠ¤ê°€ ì‚¬ìš© ì¤‘ìž…ë‹ˆë‹¤. ê¸°ì¡´ í”„ë¡œì„¸ìŠ¤ëŠ” ê±´ë“œë¦¬ì§€ ì•Šì•˜ìŠµë‹ˆë‹¤.
        ì‚¬ìš© ì¤‘ì¸ í”„ë¡œì„¸ìŠ¤ í™•ì¸: ss -ltnp | grep :$PORT
        ë‹¤ë¥¸ í¬íŠ¸ë¡œ ì„¤ì¹˜: sudo bash $0 --port <í¬íŠ¸>"
  fi

  TMPD=$(mktemp -d /tmp/fs-master-install.XXXXXX) || die "ìž„ì‹œ í´ë” ìƒì„± ì‹¤íŒ¨"
  trap 'rm -rf "$TMPD"' EXIT
  local tmp="$TMPD"
  extract_bundle "$tmp"

  mkdir -p "$PREFIX/data"
  # í”„ë¡œê·¸ëž¨ íŒŒì¼ êµì²´ (data/ì™€ config.jsonì€ ë³´ì¡´)
  if [ "$upgrade" = 1 ]; then
    find "$PREFIX" -mindepth 1 -maxdepth 1 ! -name data ! -name config.json ! -name '*.log' -exec rm -rf {} +
  fi
  if [ -f "$PREFIX/config.json" ]; then
    mv "$tmp/config.json" "$PREFIX/config.json.new"
    info "ê¸°ì¡´ config.json ìœ ì§€ (ìƒˆ ê¸°ë³¸ ì„¤ì •ì€ config.json.new ì°¸ê³ )"
  fi
  cp -a "$tmp/." "$PREFIX/"
  set_config_port "$PREFIX/config.json" "$PORT"
  chown -R root:root "$PREFIX"
  chmod 750 "$PREFIX/data"
  rm -f "$PREFIX/fs-master.pid"

  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=íŒŒì¼ì‹œìŠ¤í…œ Master (fs-master $VERSION)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$PREFIX
ExecStart=$PY -u $PREFIX/server.py --host 0.0.0.0
Restart=on-failure
RestartSec=30
# ì‹¤íŒ¨í•˜ë©´ 30ì´ˆ ê°„ê²©ìœ¼ë¡œ ìž¬ì‹œë„. ë¡œê·¸ëŠ” journalctl -u fs-master
Nice=10
# ë¶€íŒ… ì‹œ ìžë™ ì‹œìž‘í•˜ì§€ ì•ŠìŒ ([Install] ì—†ìŒ). ìž¬ë¶€íŒ… í›„ì—ëŠ” systemctl start fs-master ë¡œ ìˆ˜ë™ ì‹œìž‘
EOF
  systemctl daemon-reload
  systemctl restart "$SERVICE" || die "ì„œë¹„ìŠ¤ ì‹œìž‘ ì‹¤íŒ¨: journalctl -u $SERVICE í™•ì¸"

  # ê¸°ë™ í™•ì¸ (ìµœëŒ€ 15ì´ˆ)
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
    info "ì„¤ì¹˜ ì™„ë£Œ ($( [ "$upgrade" = 1 ] && echo ì—…ê·¸ë ˆì´ë“œ || echo ì‹ ê·œ ì„¤ì¹˜)). ë¸Œë¼ìš°ì €ì—ì„œ ì ‘ì†:"
    host_urls "$PORT"
    echo
    local myip
    myip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "  ì—ì´ì „íŠ¸ ì¶”ê°€: ê° ì„œë²„ì—ì„œ ì•„ëž˜ì²˜ëŸ¼ ì„¤ì¹˜í•˜ë©´ ì´ ë§ˆìŠ¤í„°ì— ìžë™ ë“±ë¡ë©ë‹ˆë‹¤."
    echo "      sudo bash fs-agent-m-install.sh --master ${myip:-<ë§ˆìŠ¤í„°IP>}$( [ "$PORT" = 15900 ] || echo ":$PORT")"
    echo "  ë§ˆìŠ¤í„° â†” ì—ì´ì „íŠ¸ ì‚¬ì´ì— $PORT(ë§ˆìŠ¤í„°)Â·15892(ì—ì´ì „íŠ¸) í¬íŠ¸ê°€ ì—´ë ¤ ìžˆì–´ì•¼ í•©ë‹ˆë‹¤ (ë°©í™”ë²½ì€ ê±´ë“œë¦¬ì§€ ì•ŠìŒ)."
    echo "  ìƒíƒœ: systemctl status $SERVICE   ë¡œê·¸: journalctl -u $SERVICE"
    echo "  ìž¬ì‹œìž‘: systemctl restart $SERVICE   ì œê±°: sudo bash $0 --uninstall"
    echo "  ë¶€íŒ… ì‹œ ìžë™ ì‹œìž‘í•˜ì§€ ì•ŠìŠµë‹ˆë‹¤. ì„œë²„ ìž¬ë¶€íŒ… í›„ì—ëŠ” systemctl start $SERVICE ë¡œ ì‹œìž‘í•˜ì„¸ìš”."
  else
    journalctl -u "$SERVICE" -n 5 --no-pager 2>/dev/null
    die "ì„œë¹„ìŠ¤ê°€ ì‘ë‹µí•˜ì§€ ì•ŠìŠµë‹ˆë‹¤. ìœ„ ë¡œê·¸ì™€ 'systemctl status $SERVICE'ë¥¼ í™•ì¸í•˜ì„¸ìš”."
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
‹      ì<ksW–|ö¯¸i*iV’%Ù²_¬%ñ®16;IQ”«%µ¬Ž[Ýšî†ÉRe@Iñp
(ìà$6ã©8<RL­CœàìýŸ2Õ­ÿ0çÜ{û-É†ÙlíÈ`I÷ž{Þ¯{»Û©Þ#oü•†×`.Gßá~§Ÿ3¹ì@_n0“îƒñÁÁÌà’{ó¬9R7LQ'äˆ®if7¸½æÿ¾R½UÑ0%}®THÕ®¼hàþþöÏôçÒýŽý²ƒGÒ™l¶ìŸ~3ì_ÿÏí/BÙH2 öæ’ýèÒü¾aïþ@b3¿’M)ž"­µ]ûÇuëÉMëÎ±ÿ²e5¾±?Y³7Ä¾qÓúÓ:±îØŸïûö–µyÓz «7íÍFku­ùb™Øv`a
HõÈÕš¦›ä#CSÏÆï Ò×Ó3sòýüé	2Fðä¹üÄlžÌNœ˜Ê“ÉwÉô™Y’ÿ`rfv†ˆó’j$ÖCà%—Èäôlþ½ü9röÜäé‰s’ÏH&ÎÏž™œ$§óÓ³	
©ŠU‰Ìæ?˜¥¸¦ÏOM‘Sùw'ÎOÍ’wÞa u]	AœŸžüíù<›•T± H½šƒK%©4'šD˜r¡Ø8›Y7:±QWTmQ}'É$á_Ém~Iº®éŒü´‡,
˜t®¦)ŠÃ‰oX[V4ÃÜ‡zäÚ FQT)
@˜½bMîÅ‰^.û¿Íœ™fÐõjUÔ¯x\h>áBbì~Ä$›páL]’ÚÒ§1pOû¿WˆõõÓÖí]b}ûÌúÓFÜ[]T$Q­sý«ùD„(É%Ñ”Ik]Û&öMðö×ìõ™nn¯Ç{â#=èÀ==%©LŠšªJE3V*ÌÕD³¦”Ž’³WÌŠ¦’¾Ô€½±æ„@ŠC[·WÈY€&ÍíûÅŽõÍ+bme?YžÿÒZ]Ç(üëÒ
8“ŽÁg5Öš»4Â˜€‚(„3À.	bÊUI«›c}é¸»(¥k‹se±hj {Á9mÑ‘.KÅº)Å„³ç&Þƒ`ýH«ëª¨ÌUµ’4ö»‰)¡Ó%Æé®Y•M¨1!E,Ê eXGD4è	“6Šº\3c,YÄ]£Ä~tÏºû±|ffYbnABQì‡÷ìLH·w›Û Æïw¬ë;¨f»±n½hXß7 émÚë›¤u}+Á‚Ä$ÃdŒ@âå[OnqäÄ¾³	)ÑÇžb Øý‚€Q$\$eOdn¯4óÈœ¬–µËeq!~ÑÅ&—‰à2/U3"ÅðµÇÄÔ,¤$–.y‚œ8uŠœ<3uþô´OèÜB<@Ì/íß‰^@˜g|$ƒxxžgyRë©ü¡t/—.Ï1
T€3\#æ
'¿{?.ï“rrÆMR@™y "O|é¡¼;õ…’`z¼“‘gòSù“³ä7äÝsgN;º9sî¨ëÄ‡¬
aÆ¤ Ÿ±8/q.D”Kä°ïƒ!¦1¨žcä¸ 1 “ˆÇSeÉ,Bb’b8v$oÑ‰¤™Î4”»0ÓPGñ €qþMýŠÇå>…¡þRŠ49=“?7‹•øŒÛøˆ:8Nþcbê|~†ÄŽ'þ‹£¨!îâjNæªë)tbH‰r‰ÕÜËE©æv+©IÕ”æuÙ¼’ÇZqŸ~ê5,mìš eYRJ×(cEÎêu©Ç—l@!õ‘&«1ámƒ‘¼M¨O. OrÔ¯¥yL ,ÁÃ7Lí×¯ìO—iÝ^±––­gÐù­a¿ÅpÍ~rŸ4_l7¿…ù“ëãm¨MÄ‘4™Å—pþì)ÌÜÀ3ùYÞ>ù%Ú
a8a1F;-§³àßh“À?í)aÀ!x±çßœÎˆRkðˆ21}ŠvoÑ0j‹<æ3õªÏ‹!ŸúvTê·Cá
–F/HÐ”c˜S—D¥.±xœü¹ $/Æ;ºÐÁ\ù]žû².ÍËt·òfÈ¹<ê…ù#Ú!Vê‰¡~øF‚Y÷Öì‡7›ßm[××"î3àYPã´1º»lmnÙ[KnÿÓÜþÂÞXÂBŽkìG7íõWÔE)ž_^âfæöða}û‰õdà¿ƒz<ü”CrlögàÖÃ¤µúgèA"¤Ayøàw HæËÝæ‹ÖÝ†³Gúq¢» Ä!$ N	Õ†¾MëþÞ‡fw´O4»ó¡Œ[Õy	}¦¸Ë¢‡Ã‡p~à 4/Lžu´>Œšà¤v]Ùö™÷î+´‹õÙš£KÔöæªõøy÷4!œÉ!6¢£œx„(y‹ËM]’
e6vôûÍB€uªIçd©®]ùØ+üýÍÒusÒÉ‰™<’š&Ç‘è,~r·rù)˜<Nò öIIæ$ñ±÷©÷<K¸Ó	Ç'öçÂméèí ~»‡"Ý°@-µ±ÍhTûœeJ—›hßX¿ß&&áñäÚ³N ÏÁJuÜýU%NóDtñDjF J°ÂJAIR¤¶mÍá·v]â;Ü¨r&æó9­ÃâïÖ}ÎöB†^Äî…ÎøþñU@áœ/ÐïñtÝ1¾	(!ÎÇ‡ý¾xœ£*!>ÜÎ¢pÐs°áv'äB*¼D{FC¼$Í•ëŠj¡“ý•©€b\5àüŠq‘AÃ7&­À‚ÃØ%è·Û2m!Ð‘ù Ü£gO4}b¿vÜkÖŽ‡»35n0NÛ³ã^o× ‡S—¦¿ð˜1UªWkFH3’jÔup^£(Ëc4lã¡æ-ºÔQã¡VSQ¹¥?äR®°N«i¸r*:ÒÁ’ª[ŽÓ9šIàBú"Ë22ª>OG³„<tgOgó2¿J·>¸ƒ2~ÍV¢™‰ŽEzýmØ ûÎVkù)¼­{hØc¸ýmù¾\±WÆOÐ,ZËKtêþ=h¤ñDµucÛsè'›ÿóÊ¹~pXSw±.Á5ðñ°}#šòDvtô¿}çu^)z,/ßäeà\ÿHg .“É¦ÿyý÷òrí/«%érªbV•¿;®×3éÌ`:ç]ÿ€ñL_63ðÏë¿ÿˆ×è[§Îœœýðlž éÇ{FñR :?&,hHb	Þª’)âÖN7$sL¨›åäàÓÊ"\’¥E¼¢+`ê5!ÏŽ	°i0+c%é’\”’ôK‚^	’E%	O‘Æ2ˆÄ”MEo-/Û¯ ^àñÌ'ëä4½(=ÚËf{Fó
¾2Œ¶ ;Ç¡š¸*RU&Š<_1GèD2Yƒd?LŽ–ûà'ãBy-‹ÀLgŠðSÏdq&]NK%gÆ”.›Éš.cÿ“éþ&	D.±é\6—é—ÓU(A%˜:648ä²2¯Ë8(e¤té˜3XÐô’¤}¾ Æ2™û—Ne²qD,A¹°2+•œáŠv©ÝÂt¿»P[€E™ÜPºÏ­ "Ål&]tÆE]…ÁB®/Mùº
ÿÿµ*•d‘ÄjºT–t#Ô;ˆ¾çñ['l„á3®Ò%üñ†ý&Êˆðs,:‡FÊöÁOÆ›™©L_¡i¿¡Š}Åla0ÐÎT>ce‹ð#zÃses¹„óßg±€Íú ¯”ó&üV®Oç|ë©éúÅ’4”ö§Æ+ŽeûŠÞ(7_¹P(gûÙðUnÄßIA»œ4ä?Èêü0aÜƒ—Gè|A+]á–%ÎË€'=B
bqa^×ê*P»$ê1f¸ø³­3æ×>g¼i Y«²ê6®@4W“u9A’b­¦HI6»¾i^“ÈùIÜŸ•ùºJÞÓÌŠ\„CT°š.—G>àœ&ÓW»ì¸f
Ð`%Ù¨)"P*+Èƒ¿“%Y‡&QÖ@`¶^UGHUV“	ó`I§/UFHM,•¨>2ÙÚe’éç¿FÈ¼XC WOÊÔj(Z"ä5)ƒ4CKº³8[sxYÔq 3l• ò‹4DAq`‘ó7õû,A™0j Èb…e.ošrÎZÔ‚n€ÄƒúÎ:J8Šñ¤ZÖä¨Hu{Ú˜Â‡@eH
X+B­n^0¯Ô¤1\{|uIäÎè(¦¡jrâ.†¦@wÎ³ñ¸ÔÅ’\7˜´UÔ™ÝtÓÝ££"Ü[V+à¤¦ã“…ºijªcà0$Å	„%pÐU…½îAäb)Ç
b')W¬ë.¨i2õ—€H)×ª	g"Jng(8¿Ku—ˆñïñžuœÌ'ã8-[4qÆîû˜h²	æMå<R°kë
7µŽ×6W{0vj²]¦Có®Â|ÞUMÕ>%tBªAÌš´ÃÔë%Dd!¥ˆIi›h1wP$[L/[†á`{¿¤#€]á]­W!”ŠÃx3M]u0üˆUÍ”Ê..Šzé«Ã—ÉJ6¤…NÑÙ5ÏºÅ~†\°Å).DÌ-ƒ¾”ê²Œ–`sRV´ÅaR‘K%Im×`gB—€œ¯Ì¾Íi^RK|å»ˆ³3™’P|yÕŠÆwW0ÎE³XÂŽS'ö8l£ŠÚåSVY•’E+.¸<él9åTûhØØÐš;L’>§ª‰*‘7àUûl{ÜfÁßÿôgÓí­Ì:
±Ð)+eþœffq»IHÕ¨ÜO:« úe—•$0+ÖMÍaœ?‡-¶rc)T(}tØÈ;”pÑË—uå3uhRkÐ¯¨ï+Ðm%i“†„}ùOaÇt©}^òêW€P²}áˆ&†«Ž£%Yï™Ü³/S©ÃûUÎK ‚]e×ÒÔ¶ÁìÂ®k¤Õ|OôÖIº‹¡*ŠX3$êçôÓˆà˜tÚöx
ab¢Dy¸*RÙéØiîåÕ­nVö.BŽsn•ó—¥šfÈ,–È/WFÍ„m7fþlò‡$=Òswf%þì(0âÝuØd%YGî7ßªaºWÝÃw¹Ì)QÇËþŠvŒ6ÌPÛ¼ÆÐÔeMÝ%Î8ÙŠ}È|4ï¿G0K)¼l Hªâe§³é˜)!oXR¹fÈ*I¨öæ´»ÈûŠ¼s&1ê…Cô[¦^W‹A‰³‡’8UÂ'Ð†ü…´]'‘Ã@ÜWpy
)m¡­#hè„=ÑŠéŸƒ9R´(Î¥MïhŽ§+`±"¸h]vÞÞ2®Ã ü9Wþ‚¨£½¼¡÷÷éY¯OçÇnEõ=zºvQÔW|4ûC$Ûw‚]öªáÁõÑ>ü9*äkÄ}ªÚ¡v”¶ß¾ð quÏÖ˜¦t*¶ý®b¥jÍ¼Ò5ü½,e¥ƒ
¸"]±ïT’õ%pZƒ¼FYÓ«~ÎQôúÐUa2kEA™²îo!|ùh%Ép»Ð¤“b¥eÿÛåÎ±Hñ…ÏŸ‚>—õâÈ;–
vþžúX:r6T—“UMÕh&O“`dMq93I©Ì4ß¸¾”pm`ûšt•ÍÓì˜f‰µg´—_híå—~°8Ãzn7Æ±VðJŒŒŽÒa˜¨d:^Ï)Cã›¯†’&ŒÛŸ[|ÎÊÁoËF’^±'­Oh­>#­/V¬g;À!¬äHøIGÃÈ%ø=á	S½‚4&87¯ëÛ§ÖƒÍÀsAø¹±Nì'KÍÝ›ô.V¼g—ÞÏ”­;øì#pÈ¦Ùøh/#Þ–·—e¼`A™²c_nùŒØ[÷íÝ,þÌjñÑ}úÄå—+ö‹?ûYÚlØ/v‚€!Î¨¢‘÷ÀV(1`	z¾ÜÀÑ)žþ†æÙë	š"Œ[wžÚë~Yb”u–E]•ÍIážBgµòEèap	»‹Þ%>ÚËæ:Ÿ>!ŒŸ>±'Ø{'~Þ,•ÆßÛ~ÐÎFÀ@fŠƒKÝKÅ¦Ð‘0Þ
	<×s"8êóP4 1õ{†Ê?MYbn´0#éPy ë_—D!ñÐ+8#ã’1¹ovv6ÀÛžY¼µKüüœ
ËUÝ)½++’qxR­»·š/7Is{ÉþiÍÞ¼·'½™¢¦KÝT=îqNÑnÝ'ŒÈáTAo'­¯Ö÷;ûRýI~ßžÞÀÛzC{ßÅCI7™gÝ,C]ïãoîÞÂÇ&.$"'myóÐ<I3ô{'­°£AøØ‹Qz¶Ö&ÊðøÊÍ1¡äŒgHì(F wÉ&a S6-'ýI´ÿbv‡ç¸óŒñò’}ã8ÃŽõÙÊÁ9÷lÝá`8ª¢
uÓ„4w– S¨(´·‚{€ä©.¨S`F‚/IWe^‚Ó$—(mÖã–1ëfÃúf‡>mƒŠ¸¥nìòBcú#ø°Îãç¿¼´·ñÉí_^6_€voÅþåëñÏ¬¦ð±ž"psw)Hµ¹ùÜ­›)Ÿü”mzÄá}ÇÚþŒš:+àú¥÷á;º£©ã/Öùáé!‡=§-–5O.PoˆŽ_]´³yöm/Æ½Þ…éŠ>ÛôðSûöžì^ç€O%Ù-Hs­ÕMb­.£æém˜ÐŠ5¶sðÙ¥Æ×ÎcJ´Þ:wh^_kÝX²®sm‘Ø¨H*ºTŽòÕN»>†t czf½XíÇãAÝ¿ts&BŽÄ{x”Ó/yžã¼˜ýÃ:{*?Îƒüò’'+ÂÛ?€ÀÿŠ›à#~ub›}usn½
*áI‘CZ?5 2´…óXw~"ÁA_ml7Í„ë<MKžSìÚñÌ2œeP_ó%¥
ólto·Gû½¦ß#Š ã³VŸ‰ÚÝñ.žúM O_Ù›KôfäÏoµV× ¹@}Xuró>}Ô¯&_Ì±LàÎtl<\9LXÉu[Ð`ïé`uúòb°À{­yDÀƒ{zóÅÏöãéŽÛlÞ‡·nÎqB¿Ž³öb¿nÇEMÏãXBÎçŽˆçÒ‰xqîêCx.ôŸö­™;-¯±ô9SžI,ð°mÜkÔÚ!Æa¼¹}ÍI«°õ‡ÛX pËúz¥&ÁP6¯m@­¡Šãñ-|VÀ^mXÖø_g¡;à.u)\Å©@E­$QeË*t Šr²
]%=Óœ3#vüì;ËÂƒEçÜl€_ûñèE®TÏqµw8ƒg3è‰ÈÈ^Êÿi’œõcƒÿ¡%W‡TôOŽP5²?^ò_ôq	nsß£·Ëöç;ôùã€ÚV¶­WÍíûNÎôÙÇ±4Í›þÇ´[wŸÃ[,“:––D»Lë!bàSø¶yßþô3|–ûó{õéØ{E*J2EY1‚ÉŽ?·T ûŒ±ýätü?èøôääÁ.Ý¨aceX]¶ž,CDp´¢M×]÷	:L8é9"¡çˆžÛ±§:Dü®(U4Üf,ô<<8^»‰'Š)üÉkí†…ó}˜Ùaß4§ñáÃ ÑÖýua´	rÍÖÆ.j€°Æ™ŠÃ[ÇJîaS©9iê`î6‘ÑFåC¨r~FˆvZ« ÏMTPÜ!;Ø+ÏˆÀzIzQ ­µUûÎ{úÂW¼pÜ³ØëÑˆºaªm:ºr­K®qO„QàB]Y˜ý[{ßÚGy&ÊgýŠ¦	ÐmZ#ù‚3¶ì2 ˆƒ]–“={„v4šé‘:žÓ#K^£*“8{¼Á[³kSÞZ³8[ÞZNpÎ’sªø)|”äÿpžÛ{ëî!¤jOiB¬™î÷þ>÷çyŸ—öÀYvµƒÏ=3]>*?óvz/¿ÈøGïVƒ^ejªSKËÓòþ“óÄÓ¤›ák†Pz|´	‡GÛ‡¢óûïy™]4‡í+B×,z>±ˆA¼Œˆ@;e~ÒQÛJÙàMµ³%ÀnóSgjbzYôBL·ª§ÌÏ›w·?5‚È¸"H{e<éÃVº3VeÜ8Æ	®ŽOøkiŒ)¾’úÀ?:;™¼y³tí¸×èÖ×Ú ?â¡â¹VŒ__¼tª ÇI
¿zîäËsó˜˜Ê_í0¸z½Rü­dâ_d±¿èT¨¾tæô™sPë²G¯+žÿÌ‘ÃË‡ã&ÔÀŠøàÐ¡‰_€Ø">à£>àïé#›?>ä{›nÛ§O¾8wšÚær@£a«=¶„›æ ,·ßùÀ<–n·>@ŠÞk€•Wü’àÎ'Ÿn=zàmÿç#©‚ýJÇóÔÚœ¡à«/B-Øøª,r¼>­xxè±Õê®¿œ¼ßmU¼A34¡¿¤óŠw \vrbhDš¿_Â&ÑZòI£¿¼M}`¹âuÖZ->Yxº‹QûeáÔ>oRmö•ýdßÔDs­C6{¯Ù†ÄiÐáƒIÓ:Þì,5ª3äþ·W~ëc|+O~v'í¿Fÿ¾NÿÒ2 ‰þ=û" ·7á:yOC«l„õ)lí"´Öü{½6XzÝõ`º<s°ä­Ehr¦)õC	ÿ—!]ŒÝÓ]<ì3ÀÜY	üÝÉ×ÎAßŠ´×Ú¯ôÙ1ñr²’àN\ôŽÏ¢kÍ;¥~Âiø1ãmbŠþ·ßãU<¯Z’Y¯l¤ì½h-HS á·“N@_š­n·Ï_[Ý\]™ þÂ	†!N±wV@i™ô¦CÓÚI¨ˆ °&ƒKñJ²7`Åú9š9­-$°!›¾°ío¬µ©Àz³ãÐí54Ó²À¡¦ ØÎ¨&¤L'Œàé<p•A0`Pö¡´l/×q0H°=?ŠÁÏÆvâuOêxûp¾e{H§^qÿu’4Mv'‹#èåë€t«ôfºè553ÚÌò|Òþ3ŽÔžºÚ3ŒŸt×ú’dÉ¯d&t0=aÁ O®tÇ_ªá³¶”K4Î¨…`‰C„Ú
aSï˜wØ »Ð<ú‡×ÐŒàÛå.×€°-¨:H®Ú‘Ã‡×ã6±Ãwom=0•‹KKSX-[Tv3K_>óº÷ø£ûÿák/@EæÎ;ÞöýGÈ0>zˆGÆQ$z‰Ï¢?ŒlÆ­`P[AJœò±Þ^mÌÄ§iä«A,¼+éU†º¡G$U½Áùûà‘z‹bÂ!¦Ãqd
â/k%b6ª­F‡na{xu¨ã÷È¬ÍtÇ\¾ÑìÿZÕÎ–ký—âV+¸XB²‹Ìh9néÎ¢qëò¤d›c—XvKP Ð úe½¤:Íˆûˆ(àe ƒñŽ{H5a@/qÂ2Š"¹dy– k}ÅÆK«I«4©åuy,—¨K”]a@ŠõâlyÔNÝõpèŠ§U@_SÚ{É–»ÎäñµY˜AäxÏ‚XÔkõ8 ™•Iq
ó	¤é…•Eïí·)Šø½Œ§l7—ô·–&›Ýþ\­¾¬`sYV=¢efÐL‹hððé‹
»Z¥ñJvñàÖJvq·¸)Ù/½UvqcQQËÂâ&ŒQýt7œÝªÒ'Ì>ê­¥«%IâÔÖòÑE¦Û>ÌËâ¸4Â§´Iÿbç—z’^ñÍŽoƒ–Ì	¶¬!“ ¡A6Ò42ï ¡Ò4Æ[(Âær	* otqv`‡WÂ¬×ÒKº§'Së%œ ªV»Ð8j3ö´º½ÉÓü¾"±qÿÕ¹óˆ Ž(’wº“é ½ç(è2¨‘¶„²%Ì*n&¸Òé©A„šÈâÔ²/´sòü¥^ìCKxX4©×p|S˜/[¤ZÔÞ,¥bŽR’j’æ%êE‚îxÈ˜…«¶^¹–Òˆñü ¾½µAM—êGØKFu<1„ª &¼O÷£î…Ð¬bJsœZ‰X1Æ	üŸœ?–`³q²gý±¸I¤‡œF:Ôpe¤\-¢|nÐb-ÒÙÝèÌ'ªHÒùz­ÓAñÎm€¢YŸ{Îø«Œ†$e¿¿F5|n2÷~×1úJðq5—Kƒî¼õåÕaÌ—0$"€|8†­Œi1[qJßRŒµ˜_kÓ­7Áw<úè°s™óëtøØI‰‘ê_6ºÖ«òˆÉ>p“×—EÝ*¦š¨ÐšN:c«ú¨.ïÛ|Äš¢®_3T—À¢IŠx—â»š³¨Ý Ya€óþýG9Ÿn¾…6S1˜9”ÓM9»ŒïÕŠ¨BF’„Ù¶iÑûÔÜ€™ÂþY/h»ªøû(<§­áøµJËq”úãâwµ‹+UzÖ))Í«¬êTX~PŸ6ŠœÍCØÍ<òìÚ¼_8Ú^ç<¡TÛËL†ðJY¥ªœa”Ø²~¤×gÃbŸNš.—à¯\dÓâ,‚‰’s5zô‚Çý×zIEæ¥n˜µà0iâ>ƒ¡=QU±æ0fSÕÞ	Db™SD¬Ô‹
*…¦&¢,çþÎÛ2å™ FcB p¹4óëL>(ì‚™*
‚3õ$¢ñîûRIËÌœžÙùqKÌÂÑ÷ï›Zh¦É×â#„.Ì!g¥A+ILË/–-¬PéOUgJ=wd’ŠQ±Aß5b´øa¦JášdŠ°ãDö)¨ž=FW‚Õb¨ ð(ôcá™ö‰ïGk: XÐL9ñ_KÙ¥øY¶F3¡W 1“!ý¯’Ájpfùçq}
–¬tK4W¨ÈöLl -K˜­ÃnUqî¹µbu+qfôºµ’Y2{¼ãÈóYÊ¡DøÝöd`„¡CÉ×3²"ŸeE~œ®+X'%2¦ëcËŒ9Ù:;;€±‡¼8'´ä#¡»	â"û$i,ËÐZ*´õà–¯,°k¶Ò4éÍ,ì0}üþ­ŒÐ"Öâs?Ã…#«94¡-»Ä˜}Q#ÑâLî€ª’UJò}ê2ÔU¦ŒØˆucKšj›mÎn¢V4¼‘»Ž4¼/´U#1<Ž`Âz]6yç«ªÐknvðÄ¨¡TëZDõ3«†QçqÃWÆŸ“)_«¬Âã^´ŒiÿâÏ0ö&¨QN\›ç„¨t=Ácä.%k ¿)©h³¯fÈbÄ>@4ÓÑáMtHY6ò2¢Ô,’áÕ¼šV„‚Æ@ð§Gà¨d"^û/AÁÀ©D ©+!—²A=vqÆLy#õåÊ3 fÊ™1[\AQ¦‚-7t TÉk;¢Í€¦™¤«|#“±}pU+«²u?’*¼i¸²£°±üÆBÆ†ºR\ŸYŒŠ¥EôÙ‹¢:š=Ô³ìŒ,dœ[Å”u:ÄÿÊ‰Ï	Ðñ=Vgw‘)Ö9SGh	Þª¼‚eåÂgå«GíƒU‡ÈÚ‰ûÂ©ØHúÞ1
¾ýðkÇ·~¡©5*®5s@ñ>H±°õ	ði˜\h&n”äÞü° Áyú©œoÖ@6½JQµ‚“èSšfõ?ö®¦ó¦|c6Ò^ŒÁªÅqa!´%£km”¡µÐrÈ´†ê°¥—ÔQTEäö%I)>°ejx.'\‘Ò|!¹ö6Tƒ‹¢ÞÓmÇ°ÖË2_Zòª!èsJ7®yoÜóY­ÒZkFÕíVêFF[Rv¾º‡14nÍè§s”ü’±š‘¤€v×áRYÍµºQHN‰\ÐwÛ .†ˆqNØ‹»½©™°^ét ]'$ácp­4eÖPÒÁx+Æ$`ç³«?ü{þñ)XôY‰N–ˆÅ’”2Tó•"Êã‡–=3ÐÌ€ÝP=^ÛG½jÂú;_Ýþ×ëªãÀé ÖƒLhôØÝÐªl¿wï	{Rö½K
BQrÎÜ¬…)$`zûáöO9²ìºÚÛ!œB)ûyîaiËšyP`	3åº	^cÛR ¦Àé‰ÁFÉ»fy
š<µì³Q²è+¬ã²ýò’ó’é –s€Ô/+BZepYõ Ôì³8‚1†ð¼8Ð6Œ8
zÃ(7ûqæ¼<ÎvmUöŒg4Š"ªÚ*Y@-¨Á ôwW–)‡L¨fo¨éÌâéD¹ûJEË0‡ä;Zœ\üeÓ}³wòª¦VŽø¦ô(á1Üü)*1… ^‹’"ö”o•SDÌ§c2ÅlðÀÌÖ£R‡¨¨,6Q²Ýzx@¯_06è¶Ašä×¤gèwF©S?Éx¯!ÝDa„”Ô'™‚Ê£i¬%.%‹¶Ù¤Í’B2<¼(ŠiÌ	Yþ¨j–@k©µ¹Š¼Ù+6x®âjY5RcÕh‹YŠgú^=5{[zÎk“9ù†v·’JŽÃûz‚ú›-¦AbšAû½Å’Š#s©‡k×5> ,)%†é¨àñÎˆ7Ó8ß†É¸ùP5?—´îŒª—•=x´[ëPb«*¨‡»”Á;2cOràC–*+‚Ä,ÅÈ†ŒXd+*Ax´X<î¹Óí¼`7²¾t9¬žº´²Û#fÅ8nKbG8S3©€Ew×3¼V—‹»V­ d]ÔØµüÀ­B,µ”íeÏÆ N[t	Æò°éêê'Œ¸LÂ%@ûº±åH§¬4z‡ú¡©–9Õy¨#P·¹ÛòÒRâÔÐ¸¢í÷¦ÌZ. woøv³éGaNÇÃ$œœ¾*<|äìWàÁNatŒût0ËW.t b)ÏÌ£üò&æê ôD'ßˆÈY¥\Îî¥ñà<_Ç´ºµFÉ›>„!iC®'Ïkõ»xÝ<ÅBŠËº13ƒ¾¥²fÃ ì]ãgØèDµÎ²äñWŠ„o® Jw@óO6MÐeKfÕtÉË¬²£ÌÎn\½¼¦V›Ø[‹l)”£ÂQ^¦ÚôÈËïx¥÷Œ=UAn³ÈõÁ›Gí8Mám‰lŠ¡Êh\¸•fè‚câÃ¼è¬(œÃÃ±Ž…©š*vNJÓÕ×€Ý‹¡~GäX=m ä <£‡„•ø"£7\Šl|›ô6äkA Õ´Ü"}íéK¥LD“¨9úàè(=GÊåôêÔÕè‘š¬™^Î¨–çEV/`O­Ý$t¯µé8¨qYé·ø1HAœ²#ìjdäßC„h[lJ~C„iµO´§%ã×ixqH£Êzr†uàŽ™d½:Æ¸ŒXÞ!–¨ºç¸uãò#§%¢öø£XãËrm¼•]Ër£èu–š8‰C\2’!íLLÄIì“4n16:Ç“-lå¡'m&wü(ÂU|nÞuÞ"ñ¡fK¾{è™}¸ÔjŒ£#pž¸3q­ž$6q6ÔäPOÃ~×úf=œ¨1# Èòh%íd0ôŸù ,0¬ç¨ïY²YÂR‡•Q¤>Âsï›‹ê%{ÇéˆQäYO]Ë+&>:+úï÷vn\Íä=PgB¿|¸óÑ}oçî?¨;¿¿	ÓBõ0R¾RIý"'rù¶.ýÎ¶&È‘P¶@›³ö~žàÛG¶w¡ùÎ¹l‹ìÓœÉ•!þÖ&Í1(v2´UUÀ]Ó	¿0Æ~OÂ‹ÀF´äRîæ¸”»9å¶	ŒÆ¥!#J¶w+íBÇ´gPll“Í#l£È]Ž(Iïtë,,®CáÂÜ)+'%Îh‘‹3œ8D²Ç®(­3ÒoP˜Ü¤UMú1âþ	9(â–¨ ·N©ç°>]kt½eJu&¼Éö¤Tˆàéäd›’êyN–Q;Ë£ŸW…yäµÐô–1,C–k6»¦«Au‰³/`Ý¨ÞmÍãñS<)•‘:BM!xxV,ãæPñd˜_dÂÍc‡‰Ê%ãÔ¨‚Ã-ôzw{êTÖœZÙ½S<¾G‚gˆn1§–kb’ë†ÇèÖöÌÚ§Šú4a¾:½YÉ9G5P!6*Ã?ð9jöbÌú³Y£ú£ŒQ|Ì~ûË+[_üÉ×à:Ê$åX#žçèõ»€0Aö?ÆæüÓ4æ;Ç¤¹TH³Ö jL7ˆßiÍìó£ê-Ë4k=à¥1‘\4\&ÇÔ¾pw!þðÕà#ùîj`ï½©hÒˆvÅ³Å¥¸ŠqÒÆ¶gg¥ðxk %‡/Ápp(€sÜÞÕÂ ”XÆV«"Y“({Åï®íüáS%¹©$@doÝÙùìJ¨^•~÷.CLîPÝÙnf¼Ü*È˜*ž‰!PBºãÖphøÅìÜ¹¥fÛ@þ‰ €ƒWºfÒo9 ÆÕ ÄßÐd‘¡ä&Ôéãw¶þxäÒovvØGö±¸l¡ÙúâÁÖ—_cª‰­Ïnÿö°¾°u¿Ö¼[EAzžEzßì¼Ùq’vHùn2™_v¾¾µsúýäš$dÃM»}]2PfÙÆlè†“dáu¹lß¹‹-<ïÚóœå’ËEý(üÑO¾ý=cótê£ý+È ‰±d@éŠû>Þy\BøÁ­š n&q«‘ZvÍ±&ÎX—f$HÅ2&ÖZqÈS<Ïö©hÛ¡ÔÊ.XÎŠ8S+¢‰<‰¯§+^ÁÌ'H)ê^9yÚ$æQòñvÑyTxjfÅTÑ'ÐÏÈ ÎM¡7 /JÞ—B±{–KqöVv}m bêÊ=bÒœ5ï’p~A™mä-Y•ti¥7yüá5¨9Œe8C®'–‹:R‚±k1Îu[lÞ}‡ÅNÿ·Ç”_ïñ¥†g•Ð“‡þ	$…±Šóç0Yˆˆö®ÑâQøQ Á<É~êH:"P²Y (íµ’A0õfëTHq)™g„Ó†ê¼
?E­éé…·þ ¥P¨C×Åˆˆ²>EŒÉf´­„{/0òºM˜«Ÿ´)¦¤Bçø¦þ&xs~øfº/ˆö…?šÒåpÌÏCf›nFg`l/Ì,âŠz|ŒK\V¶7Ív¬G)
ñ_<H*÷ž{££ø×¯H¢2#q›bðXë`óÍ@Ÿ?d7¿SìñUÌ}É­w\lôÄdí7aÑ¾kÄxB×	DGA¡Àxõú1–x™oÕCXNW»ëçkËÊu+àÕöùÎö»÷<L ðÉûmÁŒ<>8L¤O(ÚI0Èd“WkŸL&u›“ªÝŠk}5sÓ>½sº³H9d7œ³ 9.yG3€Â*Ãý“`rÖœ—j¤À½œ,«"G‰Kóîûß^ù7ÇÊ??\¶aÀJŠÿä´¨óDGá˜;:¼OMo3“ñ‰ŒÐ™ÉÞ/V%DµŽB[N³52‰¿%ŠZY³ÉlÅKÙÈ®ÝÂB×9ùÒâ|è;¢Ü87`²V´ÿ:Þép?êÇ)à^ç\ç<m-±—!ÖÅµžæjÈ¤±wq6¬3ÔâŠÕê¿rÐÚëIµ4±ŸJÚÄp,r?¡÷—¡]Ý{0Òz©(¤b"Vk*²ãEÌ“€9A1Õ{üËÿfÙTd“‚ì>æéF½Yâjd?WqGo­ÅýKó”s¶KùXÒ7näeê2‹’8•hÐ]YiÅLÃ.âl–#´ÆÃºp³Üïæ.ýPÎTÓWÜÙ=cÿï¡DN†VÌ©Jˆ§›æõÁi¡|âí¦«Et¦GF®Œ™† óþÌëUÐÙÇÂ¢ã:¶ÞªÀ¹±C7`XauŠ&Ìºû$§±ÕbHÚ¦b³ÛxA˜3Á¥âÌœsûÂÀ6Ð{û´DeØí¤£3$ÑiG¡JÏÆé‹¤]}MIÞ‘Æ¹01"Ôª¤£ïœ	¥#«yN§$Á¬[®n}ñ;¤+H»õàsPÔUL½¶‚ÎG*ç[‘ßˆøöooáIj”4’SŽ„’ÑkYä*Ôº†¸(E¼¢ª˜¨rªñ/ýÎŽfS%ðYµnvÇ³J
áTÕÃj×UAµ"P0—ÞJ[I5}ËR`›XYlo¿¿ýîï=ŽÙ¡#’¶#Ÿ´h;cÎœ–N6É(QŠbà¸ðû@Hº^`ã<½m9Æ`Âô» $&ø*S`Å²’ó”H}lJ¥†<6%W2M­Ú­ãO}÷O4unîäË¯ÏEíÆ÷heôgrøàAúŸÌßéÃ/˜yjúÐÌáƒ½ Ÿ*OOÏLzÊ+ÿ`#²>k¨zÞSH`G•ÛíýÓÏ3^ñ5] D¥â\'&Ü‹¹P¢•Œß·¼}û”krß>”Pñ™ 1˜¶öòE^â~•?ù•ˆÛNîq,î’€|ß¾`©Ð;ºR„®~ê¬ÊBþáC=JöëfÚvM¶¿ÓC{ô`ç_Ð*{oû7¿’p,}'ðT­„5„’ä¦|ÂÓ!Ù‘¿zÄò»5í‰Iò×Ü¥¶âöÃíG×a½a…(~•5àì¥Á*ûÑáý%¯—ô¾ù
Ã,®>Ø¾ú•·ý‡ko\U"ô¾½«ü›÷vþ×ÕíÏn{ç~2wÚ;"[¡»–áC·0«í/U®oXmòZïÛç9¦qÊCMé§'&žyÆÛúýýy01±´´4±à˜ÐOr±EïÛ®Àâ—vÉJnro?üƒ·`vˆ:‡Ê]á×®,È?=Ø¹s¥â^ÞÄÄ8a(™1½èŽé{ýÃ¥Ï·üB[ü¿ýðoÜSïƒF÷ –xãO"ª­Þ¨ÿnÒöÀg“õ/é czåO=¾Ä™Û-¬È:(–€‚ºD‚D?^A¹Ï•?y³ð2(}ó•íüæ«­/ïìÜºã=þÅ]•Ãþ—ú=Ó4£<gŽ|Æpóà-ì5·
Ô ;2W
|v}û·wŸ­ûnÞ·n²òÓÛD‰ibàOñÞFžœúËç€0ÏÎÐ/þ˜ñ2òo=ø˜<tT 0â-¡¼ÄBYõB|i)¤vn\G9ãË‡PPÍý;>Øú¿_°rØÝÖÿþÚu!e‘Ø–WŒO[ý”ˆB ‰ÅËŽkì“÷(ŒÌhB™wn¾óøÃOù&{ÉpÍìAwû
€#¡ª'Ïž
–´IbŠ]ú@=åÅÓ¿1¦y	ó=¢6¤_Šò3	í4tÖ¤Ìöí3;nçöŸˆÜ¹²óÉ§æj‚¬˜¥‚Öªó¶¿|çñÇ¿#BMÚ Ã@E)ê	 +î¢~ûwÿèehŸòä†%ë–s*rjø€ép›ø…Qå3pÁ ¨Óg¨XÀÿL IGBü„S¨0Áýš ‘òžàd3GÐ±(‡˜µ$f!4yBÙb+îyŒ’
/tl:ÁÝIÆ4\2ºq2–öê‹!túÚÙS…r|Š~Ê´’aH§`Q¿¬KýPÁËßä®ýã–
îïÃy¼:öâïa©'Èj =‰ôŠîÛWqY¬¼KV§N…í×ã‡—z\ðÝNùòÍWN&¨e~ÊRJ'Ùô*%ºY¯P‹ˆƒ9ºrWÅÀZGÝðÓ³Ä7¸Ñä	$éKt¶0¬x#¯‚ƒÙÒóíÏ~Œ7ÃÑ(_AÉÅ‡Üq”8.ÿÛ¿{Ï1|…¿AR¼só÷†ìÒ.œáÀ=ËßL¦î"SËe‰Dæªæíra!<M»»ÅûVýWaMBÚD$§ŽÜ¨¾ÞíßUþ#	€Õ•WÜ~ð»woËU+S`:à#’ŸU²2ÇA¹’Df`um‹7Þµ/VÄ.¶€ðý8ß;üâKÃ²@AöJ`
ILÆÎ	'˜“E0;–³ø£ÛÛùèWˆw®áŠ†x=Ø”nÐÒ7€„»õ9)×+ëKg¸Ë  0ÁÖ*xoeYwo–‚\qÓöT`·?}dn
Ú½‰íË,	âÕ«@`¡žýú®&\Ìh:vo~­#?½óZ%^Ä¿skëó^ ò&HPÃ!r­P¦X€‡{[¼*y;½ý´žÜ’î}I!`µr_Û¸òø:j”·ð+GÑ¼ÔF…Ý¾˜ùÉ}),qWõAË#7º™å²>^fÁdÝ?¸ŠjçUd Ä?-&Ëwd‚ÀyÿáÖ¿$q5ïDìÿîû@-Kˆ÷H"¿`Y!uû:É . "± »¤ÔB–ÙaÓØË¡V!.ï’µ¾K&¬ñ­€:YÞ³Ñh7*†ZàÇ¤YÖ/Üâ‹‚hÃŠÐlœ>*7žÉ]¡¥wìk\´]Ûñy&O.r³M±›n|û3 „·¯37AÒ·‹j4^HƒKêN8Åç—]3,È¿ûö)Y±þ=Å@ðûõ§.ÊHcŒ×˜- ï|q“H¼s}Ö—”:(º”Ò³ñ‘&ÑïÜvoÌSºãÕÏ·¾xù‘WÔ_çèé™4dÄG½,Kt÷Út)³K„"ÌQQÌu[ßŽ¹ýîýíÛlˆ3;R>Z*€º¤mˆ7Y|…hŸÿç‘DZ†„_^“RlGÐº¥Üº	ä¸fnS§\4‡>·è/ao¨"ÿñ&ÑOî3MÄ9z4Ñ±Ì6»Rß{[ÿuSï«?ï9*Š‚<žÙ¦€–Œ ¥ª·¼³/M=þÕu–º¥[‹¾ðˆ§–×’VCáEÜÅÑIj±lUgò³µãÑÈF''Åà˜it¿2Dæ[Æj+º°C´bÿuwûÁ»áDTÜƒT	9˜tŸ‹‚ÅY—$«ÙeH…==/0£¾‰Û ‚Š«´+$ö=´Ö»Þðìž{Î‹¦ú1ñ>µÞÏÐõ“ŒQz1Hhüä>Òq PŠj‰~×ý„Ù¶ÓA·‡»Ñ#Ëëy7ÅÎÛ¨wÉtÊf0ð;7¼Àab0·ÉØó¶˜\·ü#|‡²¬ÿöÄÛ“““úÿPt	^‚lx;gÈRä
³í¨ÁÑQUSíofÒyÙËî>¼&25Èz“ê˜¿Ò“ñdÜyØÃšË‘m£%™=v^¹4ïT©-ibšZjt!ýÉ6´m¹¿µ°P°§Ím?;Â/þÃ#U€ì_[®Zí´kÕ^­èÐÂŽàâÿæc¤?ˆ9Ô;ò
·M`?T[ È©ê™<Žì@@CZ‰„;vnÞÏØ€øèVÙáÊ»,nWl“²™æA£è2OÇ¼2Å	¦`Ò°†PÉ{üÑ5`=‘×¬µÒ˜´Ÿ/Q“'Û°$Dc¹ŠÇ±c’ãšiUp§±Œ£!Ô‰™Ä¸«ˆÓožœ<{
‘bûw MáPƒn…¯Î‡×K–{I÷MÚ^/°-j@Ù¶Ô©]>ŸûÞ]¢‘pÂ`6¸[¸Š6ÆQéfµÜ[º¬¼%:–‡wåña¯Í¥ˆÚJ¬ë‹A6 ?à}¬|¨fVì‹l)ïQ>ÏÜHÔb-]¦0†ôkkyÃÚ˜:–4ŽK <¶‡M(a€ì‰’:r‚Ú–Ø÷‘íðI*?¬‘wC(C'Ë ±ÑÆaú³–Ë†&$²7%Æº‚&U¨Õ~ë$kyBtì¦LÓ”)‚EQnC¡¿ù
p»Ã»6¬‹K#â¤:’VÏ¾¦1_‡õö˜A‘-ƒý@>æÑþÿrùÀÓÊÿ¸<}è©òôLùðôžÿÿ/ñÁxI†_aQÝ*~^ž × N”¸|FðõÝ˜¾Ãà±?.àÎæ¥ÍráézXÈI©ŽŒ1Ï}¹²_·Â¨Ò·ò'6¿OÌÌÿOŸÈH³?X£ñÿÐÃ_ÐøxæŒÿ9| ¼‡ÿ‰ïûZ¢Ð7Ô‡5(B²âàžáQ=ÀUCZD¦,yV<KaŒQ†Ó“ö/l¸îü±=Ët	°ORzHgàû¿ÉøA>à ‡' '”óóªö	³KÜq	‘,[v2ÂÅœ;ä¶om}	Þ"ëëºO)˜F³ÅCí…åE²§i]sqöm"iÓ“Zˆg«ßq¿ßéª ¨¾#‹Wß»©úÖ×1_NM—N»õñ@ÿº¤+Vûq­‘tVô éê;H­d™ÏÙgž	˜hö»m´9Ö×ú}ŒÊn®Ö@pñ¤ôyjþl·ÛšÛˆëkh‡jàíè/*úb-qÏqË?©u-ôà3Ž¨æªÈ`ªÚYøÉ/xŽn£çÕô^O6Nu¸œÌ€–Y•£Õ·R’|yÔ„ª ÕR¯ÝXž˜xñäü\õåSx¯6öT«”Ëªâ‰në"¦j†6`9&^:óÆ+§^­ž=yþ'PZWœÂk»µ¤æOÌŸ?yþÔKÒ¦]
­±IÝŸ8{êåê+§NÏe^‹G/iø/Ï½rò§§ÏÓ5Ùä€s¥ó•eþùç?ºÖn`„ôÀš"{†œ0b¢ö9Ô¡†X,€³÷.	n¦@Vq­ç#cAÐÐÄqàŠœäB¨Kîk¨ 4lÈY7“•²›3†¥‚[%_e4ÚThý—m…òÙyºR=ãöø~Vîn¤¼WÂØû	€H
–¯2"a…Cå›˜Ã¨‘ÔB†^$MÏBÆ(Þ U>Uµð³žV)ÍlúU6DE¸ÞE*2ë¯š“GüiAÓÔ•ž#Ö£Dêˆ"½›a(Að|ã@s†þÒ+¯RÚ!kð/¿¨ˆ‘(² Wa1œ€ÑwºOJEIZ­-©YÃ{´y¦‹@ÈCÕºP¥¨}¡‘ôþ‘Îò.Ò‚T»è':Ã=ƒûÃŒ;ÍiÃlÜÄfVÒÁÇ7ÑÜóå´r!q¯öúÝKÞöý‡˜¸d¢ŠKáó.ÿˆÈd-oƒÌ»³Ø„ðº³“Fµ;¤‘Óâ*èûn"‚“’>œ­£‚Àã_Rx%Ðy
ú÷ÄÉWçÞ8_Åh‘¼êª#'j	Ihí~ˆ”ÿ<Ö:ÿ×gç,z!G¸Æ“,ñÔ«¯"ÃÌ2l•¤`=Mu9ø>¬ØÏÓÜ½ªµ‹5>\0¬Nzq+%m@è)ø±ÆÄhEç¿<Ê«À¡ÎmÔcÊ¸'pÖƒ÷‚~n¿]káýŒ°qA¿¶.E@œy^!<_òô÷
±|‚R™šB¡ˆN=O‘qÎä5ÏG(a£x¢ûðº}<ßG—ÄöÛˆ©AÈ~-æNð4|ã÷R¢:¥nÄ‡®}j*éØ­Ñ(24<Â—í­14“´¤º‘µ(­¯ÆíXµPMü‹Ç¾`ønM'ˆÚ}ÜÞã›7vÞ½M®½›÷1õÓ‡Y×eÅ{6õ½g=ÜuÞ´,ÉÎÖ8e8.“™¿ÈÄ´÷ÖpFÔø»Ç!IÅ³ÖJ˜ðqí¿œ:{ñ°î[jù¸ôc¿ç/ú6¡õŸMa¯àŸgØa 6…í´l³ŒyþBt‚eC«dUå4|)ò¬ÜˆŒGufßèvðó~úe ?G*åp0Ú—)¬eçO ¹)²õhûþ#oS–<ûžd¸ûÍõí;wAãbŸ´ž‰ÔÌ ¨F˜@ž¼žËÌ
MÊ4-d«³8=Cþ£Á˜.dNR‚Tœ¢µõñ[x¨²Ê=îÏ¥‚;ž ‘˜­ýˆ˜.´jÖTþ"˜6O
 I]‹!ñâ¾Ë‹
ÔUÍ%:¾Œ¯ð›\P­Äƒüà}òm(BE„–;tÖƒ:‹#‘ê®â'é*púúé¹ÓÔUI´šHæ\òÎÌÏñÍFÙAÔ0|iÖƒ®j`bâEøS/„Äµ|d	ØHÖ”H=…¿^ðl*$¶0…û	]„¢‹·]l4Q›‚0Xòªx¦q
@OwùçPIKY©º­7 P"Ú˜$Ì^	e‘ˆDmñxàÇfúÏ¦¬‘zÏ6ÂÌ*0b©ËÁéÜü˜FaTç®¬Lg±CÓ^x»£.ÃŸ´gÈrÅN(2²“Kƒ(óD±þ³x‹^?èRÞ]C×¶|Ž±Gx~‡­ TD÷È›±¢èµš²}ã:Yu2^<Ž¹‡!- Åmß¹†m=þÇ+N6
1¨ a£î¦ª !&ƒj5HãVÓ’Úñ'°4:Îš76¨a­wû 	gñ®¡é’á{Žöµ¨–L7ÚêÒ}¶Ú@îbâ·PÒi¶’•ÕŸÍ¾¥¤‰MLR7‹‰ðéóŒ§rÌê3âÒ”ÈrÑlQM|'0Üè›¯$ãFô=¼RÔJœ(ï†¸ÛÛœu“Í‰›sÕgÕ¸[³Ùí×éJ
]jŠ{ÎñE·úzíBì¬8Û‡EÕP@Ñ!Y8u(H1KíV[ÝnÉMÜîvD¿Ñ•9i‘Ý	Í‚:)éyÚ\?Ä¿4˜¸Ì'išµê2Ï‚õRZcmÁOþ"eDª¡ôÓn,ÓµX¬w§hq âÏ÷n˜u ç—<bÈ5¨†Ë•]äõÕ¤“ÂïöåÐe§i`Ó¾ÐX™k‚˜ØFD<MQä€YeþõO*`õ‹ëùn.aÊ)`°ýh½ŸÀ
úÚ ¶¨MN‘?›¾ÙAê	Ý¹c2ë€ëƒ™aoé¨¹³N4ÁÌ:uºxÁ3rkbÙÖü­#õD‰Ê%[¶ÉÁm‚„¶­ä¢Tqjºv/»Ö®€äî\-¡Ûd
7£ ¦Ö¤Ê¨4ÙD1_?h>J:kqQ+(lÂ $îÀ_,nÁ†íFóï|Û =VwB—íý"ýlÝ›Ìqâ²5ÌÒW1Ã„Ú­\Ëo­%Ä:ì¦5Q­u¹Ö™vgÛ—M¶NM ÆJÝ…O¸Øc¯¡³£LJ²Å4ŽÒµåvÂ:"˜,áuMrÉ¼Á6}•f´¨­ˆdÈ YR?à 9
4i°uÊLmÉ¨$¼ùÙóŠ¾[­¿¦y"^¦D—*ÈZ¾”@ùË¾^é‰i½–VMOEðS¼?-@-¼;V!W6pšÂÍD`RR¢·„@F˜ßs% ŒŒbÅö;··q_YüAûÿ—ÇÏ²H½=gFŽRPK”Ë…Ð®n¦`š!%øô)ò>RŸS÷«-‰}†ÔÅ“®C«ÒËP$ù¤ù
‡µdnÖ¶+,Š«—üyZ¹Ú‚í$Z6.ö',“XµºÚ¾pØ›yXßðãàQ ,.­]Œ© bp%¦$¬gB­q'ÝQ¦!Òr‰Æ(rJ¤y"¼/žç0¦kdñ4¦z6dVÈNÍ •ìžrSË	k?àÌFW_¿&ÙwY†3é€nwé;ŒW³;g]'&Îž9}zŽÜ¾¬$‡Y­#ûl•šØ£èÅ$^jBÑÐ¶DìàïÂ–ø/0IèÒF4…â_ät˜ð^ä¡’§xNIeÇ/&úƒycé6e¬AÛ@’¢õ›rú“uZL°ø=éé÷ra€nª‘/ø˜ÛÇ}\¦z‹Ž†U$‚f_â9iO‰ÐÖ’"£%¡‰Çö¡â¢kß©Ñ³M~MÌ
U+ÇÎ±6P&¨^¢„]i\ŠÆáKâ¬Š·ànÑîró¢YõBïõ0‰ÞªædÝ‚*´’lŽ/pµÚÕúƒ±qäùÝ¦5u!ßÁ[2yGF"‚¯´&I0Ã'[FÞbZNe`”ñ–å]MiªI(NÏxôœ)K£ÌDÄ2¥î»Óà2¦¦¢µkiE$d¢·„hi³dœ´Yy{nbÏ´i«`Î<`È[È¨&M…¤ÁkQºa™”âïÙr¥”ùí
¥x5žä`ošuåûþ Mf[µör£æ5+^SDÖäoÁËh1IalÙCŠ'¯PcÚÜE¼ðÈ
,ØUR°Á½ô<@¯BL²°ï:±,Éà0 ,6ÆDx¾¬L¢fuBÂäòn«}ZÚ0ãY\¨Lcl3iÆ›f&š7éü6¤ã¬HòÇÎ(éš‘ÿ|dŸ€àè•\Š“áA<æG¬ÆÞ/Ïð V„â2V¸öÄDõµ¹¿®žÃ€¢>z.Ú=Øó ïÿÍÂÉÉÿY›üÛòä«“‹—”Üü‘Z›©NAì=ª·‚û^±l·ÓÙ(>>÷•¹Ç!œüA¹Fnˆ³LâŠ´OŒ2©Óæ›Í6¼Jí¸Ú*Ô<dY$Ï8”
w…-ÓâHçgäoæá^¼²‰ \°– #C›öŽÍrø{øÐ¡‡2N¯ŒKÖÆ— NâQ2%Æ˜ö7Ö´`$ü:%‚¯Tšð©ØL^Ä[øÔ÷…VÜ±K3êßøuý…gÓEüfš4ÞcóŒh¶þ)î_ã‚ŠàÂ‰¦¹
L*3A(yœæWQ…Yò@G„ˆF¨‹é„´féû ·ÂU¶,Ë¨œE€¬pð0áì¸±Çð8è‚‡¢T&±Á7ZH§Å0á6ÈM¡Áä7gúä¢ŠE>ÅÆfqEò­æÌEª²*Ç„,ÄÊˆF •ÍŒp J¼¾Ú Šwª)ï<K½
ÈËÙ­u@ÀU¨ä¶“ïÏ–ÔæŽ²<ž†DÚÀÊ‡Ç°ÊÀpÎ+DzàÂE=Eµ†™h¯úÎ§¿‚¢8uä?7î¹©ÞCÍŽd[†‹ù[q ƒpVvË|„å[;>Ì$	3Î{;ÏIA÷¡ÚFAx¡¶»d.ò±†ÐÅ¬·®Ž@¾ÝBj‚—¶ÖÊo¿üüeR%}¾[|óy×œPèœ’„ô»Çä½ê®ùh¸:”ëJö?³¹Š~+ó6SµŠQ¾9Ò¿<à%)6v/…‘[ô'üð—Í,Ë˜¯
©Ø¸£UûEy ÛP´Oð–® »]`³…|'nœAø«†ZõK•æêŽünõ°€^È(Pßáo›¹`‰ü)N}€3sè3tì?Õ“gOšHÚ¾,øÏ/-†Ø¾ï»á3=ÌÈN_‡ÖÎ¡”Ÿœý4…=øgL÷‚v(>~ö±/³böIˆYÓ0Ù	åFúA^Ø»W©EŒÞ¤â1ÆÂYËKƒxkìï#q¾2»Ïð.Žÿ²o‚ò; Gâo¨q\C•Á<ƒÝü¾7¼R]òþlƒ7Ú±Ov[öŽ¢»+»]ñÚÑJ¿»Öã«Ó¹éUãÎZx©ñhY8Ã2XžuuIÿødÍ^«@í£‹#uR_1$rÐnE1Ê^P¯œæþ›¯<(8Í£Y®u8Û¸ž?ÖH.Âú]jÅ³~#I¡K•f+Þ8ºRëU¦gzGA.ZéL&ƒ¸Vê1Ú¶Žö@%N:+•zÞôA(Ón2‰v®ò¼i¹V¿°B™þ+ký`r2]ë7a“3¥gšåf9n„G—»ýFÜŸ\îÝveM»-P¡¹¿-=ÓhÀf·š>VóVaÅgÚÔêÝÐd®W«ãhKÏÌÔ^8Ò8ò×crR.—bõ$BHŸÂ+ÐÖöŸkÕúý£îñ±cSµãÇÒ^­s\Ýw~lùø³é±©åãÞsí¤ÑèŽzø›ÊØƒÅEÃ¤a´×@x)=säÈ˜bQÎC9¦Hš>6gu zQJXØà%B-ÿÛf2•Æµ>è¿}ÿJšs|qB™fÀæ¶¥Æà\¨´#´G…xG–@Ù~~#/D³"L Mç+,äÌÐ_ÂïÇ7mÿö.gt),ÅæŸ;óÓóy[†`uðfcLEûÂhÊ*H#óL¾ª5°¼ú6•o£Q7d{‡Ë©ã	Å§×TÌ|¿;èÂFWÑâ–P˜¦…§¦£i¡©tjÍ~¯#Y¬ ¸Vw¥*÷ ˆÿ¼Ù¹¯Ö_±ÅxÑW•ª)®:g’]\êÅ*€p–¸  ^¿–rbÔÒžöºs·¨«[dH40õ5NùÓtQÏ^)4àXsAynÕZ}5ž”ë,ÈmÒLÝ~lIjäˆ(yÉA³Dêzy3ŒˆŠs®¬›ƒy›fþÖÑr*ÁH4þÌ6°£–÷¢»üs{²ëÎÛF2jc­ÝK*w€f‚"”Ö“d–„«0‹<…ra.(;w4D3N3bDýl|“Ü§Ä&+haŒ³ì&ièe;øx¢¡ZŸ–ŠbõÔ…t@S¤y’ï–-©Yt×Ö­ñá<
iuÃï­x¿¬J‹%†Ê9U€Â$ Q×åœø<Là¶­ò&[LRJ§ÕNN›‹§ÖBÝ‡™ç*	Ó·±¶±áœE¡x:Mw«…ÆÂôrø’´IÎ1tUŒ¡Ô†«¹\ 3K^‘fñ(WÀcgG“‘–€5©3bÒ)©Ò%Où>©ToèXÆ.#@À¤±—Èãzq¡¼èuö7púTôa3d·Ü‘-»,ãg’µmÔÃÍ’w¨<“k8x±ß½wÎ&Úž8×‰éö sxö,kÙeIÓlC£ýú#â:wu¹PS–“ùf]~ÕèVaSã¼&Ð®‡N4Œ®C&›¼!\0N	t¼åºgP;ð5b‹NÖ	î)ÏO:xƒú…DãªtÎ…8çä< Xãvl]ð´ËxGl¿÷¨6u Ñ¸r˜¥f# ÂGsW%~ ã`ù ˜:`­>>RÜù'^%¥ªöj—Z|IU;rœ%J^V ÊD9ÆJÆ™FÝŠŸïÓY¨ÕŸ{„tIèèîP”‹J¹Ù#t‚ögë°˜	Ï(¤»z£ž Â’Ænî)¼òXkx™‚60lSlÇ£VQ_·9Î>Ëó÷ÚK‹3ƒúRÌ—ó<™Œý|­nC˜o–Ïª:0e¹*½€'ÎwˆãÉ†–Û…\C?n9wA¦ñ¢à¾bÅè¾ÄJ˜Œïµß“pÚ"•-Š[“¨3#)ÆŠ©¦ƒm³£Ü}6Q$>‹C|W— LÍêOÐ°+Ë]ö)~Ç÷Zµ¤CÑJÓ¸U§»¬èàhŒaŒzIc³¸;x‘D#%Ëür¦Ú±ø;E8ãé\ÛMÎ†Çð‰—;(”×–ÉÀ‘Øµ®zXtH…™0	HnÿÎ°`i {‘“îÙ4	ß‰žŸµzãxÐvé³HKþKzÚprÂBÖaYiv1®3ªkoî(ËþåM¿p£œpLÉTñ$T2OU¿Û˜ñ¢VÿÚª‰LáðøÉ¾?JÈì®P[|Ó†ítV(Î+¸Y¢ì”S²:|t°Ê§Ñ_…<€Þðîöã5P!Ebƒ×Ý”/Â~Ðª3°,xbç[NÄ$çjªÚ,W#Š´ZKé<7Ÿ‡m›?Sû/þéü©ŸÍ|ùås?ŸËn"[±øà8¬~ëöÒD4ætuþÌK¯Í×§ËÚÔžü˜‰r3¯UïÛÚ©:´±Ëá<q¥ÓÕUÑMñ¦Ê€ÄÉ „ÕE/Á½•\Œƒžp†§Ñ…¤¬Ÿ¢¢ç®ö9ìì>åYÃ…§/ÑÜÙ¹s¯ÛfjÚp5ŒnPM:UØóÀJ'!ã¡ƒ§ä=÷§g^ Ì'Óþ"n/¥ª Dô“dpøµRQáXÆø5¹1¬#ÍŽp¥sd;ïgàd£º¶r V†j2-L—º5ŒçWqDP­T&Û¤Z°>`ÏÅ˜¶­~AÑÖÁú¨$g¬1#gtlnÚºdh„–@¿uG¡k¯u@PS'O‡ÛJcÓáA©†!i*_t²¿BwŸÅ_ý sZXÏY?{ÓjqÖDsïª@u­Ç1¤Òràsj@€IÀ2¼Í Ù€maO"Î&xžNµ%QºVXaIn9QõWR’§9¶šª3®n "…Àb{£vÉszt§»gí´B,V¦"þ´ÿ¤éq,’\,€q;JžôphèŽÌÝ (|Z—
ø9X÷<_.'x|ý=,m®á‘z¦ûïÂ€!+{ˆ•=Å#•~+à6D»ÕÖ8¦!U¤|˜QêÙ†COb®ò·ýÐ*Ð(‚Ó§æAØeˆT²L»Na¶msçIáºHŽÊcÎEOÇÕÝUö=3°Gox½éË…!ÖÍP8—Ï®ìÜ¹á®BZÄix^ºJ¯™¸š’f	NÌú$	IûuNÃê‹.)?Þ,FªØù”˜_ ×<õñMß þþÕüIópr:KºŠgƒ
`tDÅr`4–uðÕ„CøˆÏ2FfI¥°TÊ	ñŸ@~ÍŸzõ<0»’'‘ûjÃ{ËRSDB•+ ¸ÔÀJ8‹’â™WreQœ®FK
Ø-Zþ’W0T€EEÍÖZºï0‹#Uà•xšÁ¥ùÁkñ¥ån­ß8…
ýµt4OØ=S+ÂÇÜ‰1ÝC¿ZouSû¸Zž©;A(¦ãÕ*	qÕ*2—jUÔ*æ4?\¶êhêgsçæOyãëa÷üïåÿý…éò§ÊÓåïåþ‹|fÊ3‡§ËÓ‡'—ë/¬™ÞË‹¾÷Ùûì}ö>{Ÿ½ÏÞgï³÷Ùûì}ö>{Ÿ½ÏÞgï³÷Ùûì}ö>{Ÿ½ÏÞgïóßûóÿ Vú‡Y @ 