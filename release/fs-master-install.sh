#!/bin/bash
# =====================================================================
#  íŒŒì¼ì‹œìŠ¤í…œ Master ì„¤ì¹˜ íŒŒì¼ (ìžì²´ ì••ì¶• í•´ì œí˜•)
#  ì—¬ëŸ¬ ì„œë²„ì˜ fs-agentë¥¼ í•œ í™”ë©´ì—ì„œ ë³´ëŠ” í†µí•© ê´€ë¦¬ ì„œë²„
#  ëŒ€ìƒ: RHEL 8.x (íì‡„ë§), python3 3.6 ì´ìƒ, systemd
#
#  ì„¤ì¹˜/ì—…ê·¸ë ˆì´ë“œ : sudo bash fs-master-install.sh [--port 15900] [--prefix /opt/fs-master]
#                    [--agent 10.0.0.5:15892 --agent 10.0.0.6 ...]  (ì—ì´ì „íŠ¸ ë¯¸ë¦¬ ë“±ë¡, ìƒëžµ ê°€ëŠ¥)
#  ìƒíƒœ í™•ì¸       : sudo bash fs-master-install.sh --status
#  ì œê±°            : sudo bash fs-master-install.sh --uninstall [--purge]
#                    (--purge ì—†ìœ¼ë©´ ë“±ë¡ ëª©ë¡Â·ìˆ˜ì§‘ ê²°ê³¼ data/ì™€ config.jsonì€ ë‚¨ê¹€)
#  ë²ˆë“¤ í’€ê¸°ë§Œ     : bash fs-master-install.sh --extract <í´ë”>
# =====================================================================
set -u
VERSION="20261016-4ceb767"
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
    echo "  ì—ì´ì „íŠ¸ ì¶”ê°€: í™”ë©´ì˜ [ì„œë²„ ê´€ë¦¬] íƒ­ì—ì„œ ì—ì´ì „íŠ¸ ì£¼ì†Œ(ì˜ˆ: 10.0.0.5:15892)ë¥¼ ë“±ë¡í•˜ì„¸ìš”."
    echo "  ë§ˆìŠ¤í„° ì„œë²„ì—ì„œ ê° ì—ì´ì „íŠ¸ì˜ 15892 í¬íŠ¸ë¡œ ì ‘ì†í•  ìˆ˜ ìžˆì–´ì•¼ í•©ë‹ˆë‹¤ (ë°©í™”ë²½ì€ ê±´ë“œë¦¬ì§€ ì•ŠìŒ)."
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
‹      ì<msGš|ö¯è—‹”“dI¶lccsñÅ6¬mn7EQÔHÓ²&ÍèfF6ÞUfqR¼m-fãÍÚ¬SR\fqvÉ}ÈOÉGÍø?Üót÷¼Jò[Ž\®ne°4ÝO?ïoÝšq¦ûÈ[eáÕ_(°wxÅßÙç\!ß×ÛSèËö!\¾p„Þ>kGŽ4,[6	9b†½Ü^óÿG_™îšlÙÔ¼¬”2õÅ·CÜ×ÛÛÁþ¹l/›Û¿·§¿Ð$›Ëç{ÁþÙ·ÃNôõÿÜþ’$U¬4÷ân,¹“æËewûILÿb\µi2CvV·Ý¿¬9On8·÷oœåÇî§«îú2q¯ßp¾\#îç[îï·ˆ{ë‘³qÃ¹n¸Ë;V›/î÷þ,Ì ©.µV7L›|lº÷Ùú7¨ôtuMŸú 81J†	žš*ŽÎÉÌèÉñ";C&ÏÍâ¯Æ¦g¦‰<KuÛ"‰./U!c“3Å³Å)r~jlbtê#òañ#2zaæÜØ$ ™(NÎ¤¤.×(™)þj†áš¼0>NNÏŒ^Ÿ!ï½ÇA¦ƒ¸09ö‹E>Ku¹¤Ñ€^š‡“…*—e›€ã>Ÿg³V'6úœn,èï¥ 2&â’ü;1æà5MÃäœà§=dÑÀ¤—ë†¦yœ„†¹è`Õ°ì}¨G­ï`•e  „Ñ-×Õnœè²ÿËô¹IÝ¨Õds1XàC‹	cÏ
#ö ù„g›”¶¥Ï&àžî_Wˆóç§;·¶‰óõ3çËõd°º¬QYoÃ«ÅD„PTE¶)'I;×6‰{¼ýú5wm™L67×’]É¡.tà®.…VHÙÐuZ¶Jér]¶«ÉAFé(9¿hWôdúÜõU/2Ú¹µBÎ4in®»/¶œÇoˆ³ùG÷Éðü·k…?,­€3™|Îòjs›E@Åp& Øç"ElµF†=Ü“Mú‹2¦±p¹"—mt ˜2z…–6MHç§FÏB°~l4L]Ö.×…ÿrt\âèLjÃ8["¡êª5&¦ˆ¤ŒëˆÈã qÒVÙTëv‚'‹¤À®©àÕ</Ž‚`ø¢¢˜™$ˆ/˜ŽI=]/žš!ï“3Sç&¼Dtnê4dƒ“ñ3ŒÑÀ>¦ 9IÉK‚ÅY*8ô¸HYUÈ%`ßC¿ü 8UÄÌ8LNH)’ :©d2S¡vœŽ&"6ò$V+€žj%“ #˜†Tgr¤'$'Á¿m.\îSfØF«Hc“ÓÅ©Ì²çüT"êe×$ù×ÑñÅi’8‘"ø/‰¢Æ¸KF¨y^Ù03˜ÁÝU…çÓ+eZ÷+QfL·é¬©Ú‹EÌ³-NÒO£Žé ]S¤¢RM±„~@¹ºa‹±„3fƒŠÓ,¬)"e>6T=!½k1#’wÉóÉ9ôIúGi8’@YR€oó’ûç7îgwš›j6Wœ¥;Î3¨ê«XË!Ñ­ºOî‘æ‹ÍæË7˜¢œËÎW›w"ˆ[REË,¾¤çOc}ž.ÎˆÒ8*‚¬Ìc8aýfUÔ«âŠ ñYjO	s¿€‰\\yUQPëð‰2:yšuï°0j‹<2õE¦ÏK1Ÿ‹úv«ÔïÆÂ,^b)-Á1gæe­A­D2Iþ‰\’—’]è`®|F†€¾¬P¶õåÃçê„tò¼wvL\F£\6*	´¸olÁ€e–ÑeÙ<ëO®
¯a`×É¤Ú„Ä„’’b<àœðp8Ï¤ä`»dÑ
Ž&Aõ'Ô:B*’N­¡DaÉóôr¥¡i±,éC'R¤ŠñÕ€ó%&Æ%W\ZIxÁaì‘t—X4æ"aî)‡O¤BÍ$^± =Dè‰xHJ<ZaœÅä‰  OÄ¼"²,êa:J±}CFiÔêVL3T·&8¯UVÕaæÕÉXÄ¶.õÔx¨ÕL”C®Eé¹T(¬Ój®É°Ÿ£#(#ùiñËŠqÓ\Ì^â	ôbî’G5äéh–˜§ó€îìé|CægéÖwP.ÐÏÙJL13±±°`/ã~¾	UŸ¸·íÜy
o°åxr¶#Î“›îÚ¶íÉúq¿Xq|‡Ÿš¯·;KlêÞÝæËÜ"í\_sžÜÁÆ¢ù_o¼Ãšzë2|ŸˆÛ·ESÈžŽþ·e~ÂW†mËÕòÛ<>Ðùoàr¹|¶ÿïç¿?ÅË·¿ª+ôJ¦j×´ÿq»Ÿÿö÷òqû÷äsý?ÿý)^Çß9}îÔÌGç‹M?Òuß cê³ÃÒœ!á •x«Q[&åªlZÔ–v%= yÃ¬Ió*]À]	3µiyX‚¶]Vè¼Z¦iv‘b'Aª¬¥¡>jt8‡HlÕÖèÈÎ;îú(/î­G;Ÿ®‘	v(}¼›Ïv·ìE|'dmA>ñ¶Ì†	¸ª´FaÓ4[µ‡ØD:]‡Ú0HŽVzà'çB5®ÈÀLgÊðSŠÏäq&[ÉRÅ›±é;]7Ula2[ÂŸÈ¤EAd…Oò…\/L× b)05pl Àgöe8Hs4«óK†©Ps˜³%9‘Ë¥ø¿l&—Oz r¹Ê…•y¹@éó†«Æ|»…Ù^¡1‹r…l/ZIFÊùÞ\¶ì-È¦ƒ¥ÞBO–ñuþÿs*ªLu“V¨i¥£zÑç’Â"aëÄíƒpCbÆ7PVÁŸ`8l¢œ?ÇZçÐHùøÉs13UØ+66T¹§œ/õÇ Ú™*d¬|~ä`8b®|¡òþ‡,±Yà¥…`"lµèúl!´ž™®WVè@6Dœ¯R:–ï)£Â|•R©’ïåÃW…ß'Ÿ’q%m©¿VõÙAÂ¹!®±ù’¡,
ËgUÀ“"%¹<7k¨ÍËf‚.9Ämë…µ/¯@HWäšªº­EˆæZº¡¦HZ®×5šæ#°Iœ¦³%Æp=!k³œ5ìªZ†KÖ-°š©V†8>àœ&×S¿â¹fÐ`ŠjÕ5(U4
òàï´¢šÐSªÌ6jú©©zºJ1O –lv¾:Dê²¢0}äòõ+$×+~‘Y¹Ž@u¡žŒmÔKP,ZhÉwô´
ÒX@MMoq¾îñ²`â þæØª9@i€âÀ‚à¯/êY‚1aÕ! 	Ä
Ë|Þí œõ!µVú’Œê;ï)á(6ÒczÅH‘£2Óí„5„Ê¢X+B½a_´ëtÂVßd“ÊÂ}À4LM^Üå`À24hæ9a>žô Ò¦¬¨‹KËPµ:³Ÿnv÷èV"î­êUpRÛóÉRÃ¶Ý3p(’â’öùNè‰ªÃÖø rñ”…	±“‡+7LÔ•ùKD¤ŒoÕ”7¥¶3œŸƒ¥v—ˆóðž÷œ,Œ'ç9-_4qÆ¿þ„ªæÍR°É–š0µß6W»0vçêªÕ»,L:æ\…ù|W5TûŒ\Ô	™1k²þSo‘…Œ&—¨Ö6°bšì H¾˜mÇa{¿d#€]•á]oÔ ”ÊƒÄ–KM6qÀ
#Ö›”)\\–Må-«#”9Éj>¦…NÑ¹kžõ‹üø`‹Sžku0¿†RªÏ2X‚ÍIE3IUUª·k°3JF ¡y *³ï
 ÎR]éàë<ßµ8;—)ÅWT­ÖøÞU'œ³Ù.W°çÅÌ‰Ûh€¡öùTuMÕiº¤å9Ÿ'“/g|ƒª`VsI:äTuYg!ò¼jŸmß,„ûŸÞ|¶½•yG!—:e¥|ÄŸ³Ü,~7		²Ö*…ð“Î*€~Ùg%ÌÊÛðçÅÏc+œ­üXŠÊ>rÀ%^4âòå}ùlšÔ:ô+:äû…*t[iÖ¤!áP¾Æ3Ø1Í·ÏKAýŠJ·/­‰áªçhiÞÆ&ìËUêqƒÀaUÆó€`W¹kijÛ`v
aß5²‡j>'‹.ÛÅ0
M®[”ù9û48&¶}'žBØ˜„Q®­ØC;Í½¼º£ÕíêÞEÈ3cÁ¯rá²T7,•Ç²ùenqˆ°LØvcÎ&¿N³#=‡`W3àÏž[¼»›¬4ïÈÃáZ5Èöª{ø®9#›¦±­hÇX#Á=µ-j[Á\Ö6}­¢±/›C±™eâý÷¶’Áo IM¾âu6Ó!#SMSë– ¢f‹Z`oÎÊ±¼§ï È;g«Q:D¿e›½•8(‰3
ðx6.¤í:‰â¾êhŸÏ+PÈsmÁ˜C/à üFÈvP\ÿÌ»‘²`Dq>mv{A;p<]ñ ËU5rð DÛeç,:ŒÊ_ðå/É&ÚûÀúpŸžútqláW„XßÓ©§k×µúJˆfoŒdûNp—½jDxp}4B	ù#â>SëÐ{JÛo_xÐÎ¸¶gkÌS:Û^_±´V·wÿ`'‹GYÙ¨Â"®ÈVì;•äC	œÕ `‡Q1ÌZ˜s}ˆýt5ƒLÆ[QP`®b†[ˆP>êçI2Þ.ôFédxiÙÿv¹s,2|ñó§¨Ïåƒ8
Ž¥¢]F¸§>–m9j¨éš¡,“§È)0²¡ÉVŠøƒ‚™*Õê3Ë7¾/eú|g›ÅØ¾&]åó,»F¦ybí:Þ-¾h9Þ-¾úÁâoè¹e`Ü–äz]ÂobÂcüp”ÃD5×ñû˜â0,¾Åj(iÒˆûùsçOÏ‰»¼æ¼XÆ£+Vš}ÁOv>{µóàÙùÃŠól8„•‰8ihD#"Uè	OÚºDØ7HÃ’sÿçËuçîq¾~êÜß îçwÝõ-|PáÖ6~^^#î“¥æöv÷#>×ÀîyÊÎm|ö8äÓ|üx7'Þ–¿—å¼`A²ãþæ¹ûÅ3â>ºç®ow`‰ˆ{ÖQ‹ï±'.¾Xq_üG˜¥e÷ÅV0ÆS4ráØJ#%F,ÁÎ—Ûx:ÅÓßØ<?ò=ÁÐ¤çöSwmY|-qœw–ECWíiª	Oa³Fù"ì0¸„]
Èõð®ó»?ïæs'NJ#'÷;{RçÍT9»7ü i™!u7›B7DÂHW,$ð\Ïˆè0¨/4ÀÐ€ÄÌï9ªð4c‰»ÑÜ45¡ò Ö–î·Bâ¡WpGF$grßìl­ƒ·=sþts– !…ù98ž)0ªv§tFÕ¨uxR;¿»Ù|½Aš›Kî·«îÆÝ=éM—“î¦ê‘€s†öÑ=Â‰Nœ¯ž“?.;/·ö¥úSâvÀ=½A ¶õ†ö¾‹‡’~2ÏûY†¹(LÚÜ¾é¼\ö¹9YËÃ˜…æ‰N³ëNZáGƒ!ðq>°£ìl­M”áñ•ŸcbÉÏøQŒÄnªMÃ ¦l[^ †“h;áÅü†Ðï£;Kîõkà[ÎoW†È»Å3êÃQ“u¨›ž ¤¹µ˜bE¡½ü¤@uQ" 7\¤}•y4
Î|F ´9_-csn,;·ðñ‚æëíPÅÇG©–·E¡Opý¨…Àÿ÷¯ÝM|rëû×Í Ý›IÀ†O:_}Çka¯ˆó›ÛKQ2¨Íç~ÝÌ„ägl³#ŽàGXûsÜ6y7ç?€ktGÛÄ_¼9
Ã³C;e,X–7O>PwŒNX]¬³—<E~Å·#AïÂu…h¸ŸæÞzåÉ~\&U“V†¥£"†Œ‰ö^ x½N¨×O~à³fî_V ûÎƒU0tQME/vsÿ{ø‡×ý~Ž£„ûj?c—!E¾-RáÀžð¿êÇ8|ÄK/Rù¥ŸA5PŸHqÒùvò|[ÈÎíoItA"TéÚMsá:O³æ•®v¼Fs†`Ô×|Í¨Â<ÝÛ‰Ñ~?Ò‹EÔyãŒnÌEmuãv=9óÎOß¸KìNäßßüÑêeÚ}úhXM¡vV`Å}
è*ÚFzÁ7HxõÊh'éaõºìr´\v‹€÷ôæ‹ï`k³O÷Üfã¼íæL-NöÏÞ,ì×í„è?Òó–˜ó…ƒ£ÅóéD¢ÔîêCxÊõŸÐ¤i,Dæ`–Hv !á §&+Ê|b¯®Á­jh
5aÙšÃIÂ]½Gü)gõ.>®ç]æ
ÇòÉ}ÓœÄ‡ž¢Dwî­áS ¼š¹åëë-wÙ™ZÜ	ðRïmâÑ Ð-[Ö¶¡€Š¥¶¬jV•x@Lð‚-þi”²ó`­ù×7Î‹lË-˜‹b¨B–ãh`-ìá—q%d$ç7«îÊ3"	S\ä:º$‘Õîíuñ¼„»ÅìÈ^
Ÿc‡ƒ¥÷úºóð¢Ž…Ù‰mùW®µoZxèx‡R¨ªRC››aÖ‹Ì³ý?Íe‡ÄEwrú$Ol®jÛõÁîn]¶²91?9:ÍQé¬æÈ»Ÿ‚ {ÌðXïïªöLŽ€a›·º»¥[aŸZ¹õhgyc¿¹y-Zk éà]'=?ÆŒñç7ÍíMn*f´õïØ¹Xm[«ˆû5{òÅ]~y†8/— Ñb‡ºó`¬Œ¹¦ùr#Õž!¯ñiÓ—qçH 'ÎËmîIîB÷ÜÏ~Ë¨¹ËÜÅ¹ëµ¶äÀ¥ƒ=µ¤~æÌÁ%óñ …ZÝFiÀ“¿þ”t“±óAð9¿i¾|`çhÞåê#çqP8ö[2j³û«á-OlOém-ó?/0Ò%5,Š`A-ÛÒP8±e“ Ãì±¡¢åFê=>ZÔ(~<¹8¦$ð¼_ Ÿ=]œ†¥ªaã­­2Tx/CPâ;l5*]Š,¸|êÜø¹)Xõ	aÓƒD::ÐWê£Xq P86@ûa 1â ¿\Âg½l¼ÎôVŽ$r5Š{|ôdqœáæpîÃ»`BÂÏ!tÎµ•`Xm~³Éó7 !-á­¹‚A÷ácðNâüç¶X‚táiFOü ðìIXÞ¾1%à$ñ	5M3NºmÚ ±Íþ<­‡njôd³ÑðÁ/¦ý]D”x•"Šjâ½7äªÿté ÑšÆ7ðžé,ã°û}’ö_gÎ“×á‘÷»»*˜’JlS+¡óÛÜÕ
Ièdx˜¡NzüJ?,Ý—ðîB.|ƒY…–>d¿'Øo¦<`„ßçO¢p|ÓÔy°ò#Ð¤ÿŒb›l:ÄÕ„lW3uc!‘Ëæ{S¤‘a_óŸ«ˆõIqóµ`i>cã>j1Î¬Ï&¤9#ýáÐf_«µFíŒÉ…Oÿw{ßÚGu-šÏúMƒ¡[µF22¶ì2 À.KÉ¹§„2ê™iIÏ‹îÑÃe«Ê!Î¹Nð)B‚	$†rê˜@n9u8àÜ$÷C~
-ù?œõÚ»÷îî ¤*§<	ÖL÷Þk¿Ö^ï½v¼ãJl:'æÐ±áœ„‰R?áÇü˜uvðºÿ;ìpƒ*šRMÉœSÍ&¤ê<kLHC îwâ®G_VÛ½^Â_Û½5œ] þÂú>±u×@ÈœrfüÚ	‰©ˆtÀ3ƒSñB¼µ<è`Íø9ãgcÚXŠaAv}aÙ_ÙèP;°ë³h´Ö ¦;d‚}M	úakV2]?€§ÀPÞ, AÕ…Ò&²="ofÈöþ(G3<ÈØ¶©ãLâx«æ,´N½ ýþ÷(L<ì{æÑË—aÓ­Ó›™²×G´SèåbÜùöÔºZ’¬/õ6IƒàÖrˆ»˜¦¤“§Özãö/Õøn{Õ
õ3èf!ZbW¡¶Ú°©sÜ9š!»ÐÜû½»WQísÍòGŽVËk@ªí~q¥Pí™£O¯Ç0±Á7oÜ¿“U./- °8Z"¨ìNž>ÿêËÎƒ_ß~ðŸu¼Ý·Þ!ÈÙ½}Æ¯ï¢”ƒÒàs|ÊDÙŒÚÞ \CJœrP?/Ï6æÊÑŒ´	¢å ^Š•ô,C]ß‰ë^á;ðH½E ˜¡ƒépƒ‚øË˜‰ÈÂA‹j«Þ¡SÎì^êCÿÝ2ël ºa.ßè¶…ÆšVc0y.j·½Í
’]dF¨=¤9ƒÆmÉSN]Hd„Y¢a— ,ÅÇý2^RÕ€œ»¹¯á¥qN8H5aD¯ qÆŽòErÉ(sˆ«Gn¢në¹õ¸ÝòV	ò–<ójÅvèb½8ZîµUwË:c™ËÀ£¯)­‚9eÞ¶5x|MÌ ò	¼gA,H¢ÖF3ò< ³æ#)Na<ž€^Z[v.]¢ä!(Fà÷*0žª	.î#;'n- A­Ÿ›ëÞ‚Ë³ê™A3-¢NÂÃG6Õî>f J£µü
â±™µü*âj1(Y/½Tfñ,BEM‹›ÐG9rÑÛ¶VªJ›0ú ¿‘®{†$‰CS4ZËG›L·=|Xè–Áq©‡>i‡þÅÆ³½Ô—H¯u]Eð¨ZI ³}o­l3	ºrenšVî}$tØ4­ñ&J¡°‡	\l†º÷+½V”Ÿ'Xá5¿€ëaz¡Ûtô`Â~Ì	¬:Ñ`½ÀQ›1‡ÕëHžæ÷5ù‹ÀÝçq :¢HÞíM¥ô]¢ Ë¨FÚÊ–0ªh5îF-ŸÎ®Ô¬@'È®ÐÎ©ÅýÈHxT/n†Ø¿iLn©Á›£DxAJRM¼zZ‘'î2æ÷
·Bk)ýê›‹B]*	°Ïš¯ïy´U=Ø>šð>’½ó¾3XÇ( ”&æ9@	Ø&€â¹/-.ž%ÜLÎaÍ?·0‰ô3H§¼gFÊ…euˆa Ó$Ò/	TˆÓ…fØí¢xg XÂÇw<þ*½!IÙM6¨†Ë ¯áwc/¡²¹4èÎ÷?¿2ŒùÒÎ‰È@ FŽ ªbâªv”Ò·=Ýú¡õ&øŽOá5­r2”.ýWxóAý‹™®õ¢<b²Üäå†¨[åTÓZÓI«oMØ~ªËë¶°¦¨ë‡Õ%´IÐiR|Z“Ú;š†—>|Œ3ÞËP`)ƒ‘C9ÊZe|¯fDÊ$I€ÈDƒÞ§vçÌÏ9i@ËUÇßÇà9-¿À¯ušŽcÔ¯¿7×êô(¬URÀ«œ–TX~P›&
¬ÅCÜÍ=rÌÚ¼^ØZ^ë<¡Ô;&Cx¥ÌÒ6UÎ1J„¬éùÙ6Ø§U€†Ë%ø+Ù18‹ìÄÉ¹z{$@Á£ä{ý¸¸EÔÎÉh”Êý:gàaÜD	£a†{¢ªbÍÇ¼,\ÇÏ	¦
ÞIBDb™ÓD¬Ô‹*…YûÊ‘’9aïæuŒ,˜v²ð±Ì„@èêsiæ×¹ä=ØÊª(ÎÕ“x²[oK%],76rRåÇÇ˜…£¯ÖÍj¡™&_\‹¼!taø))Z¹'›$ƒLÑ:ùÂj+ä¡Êæ™VÏ-™¤–)„PE×Œè­ ¾Ÿ«R:'¹ME»ãdþ)¨ž}Þ$¶á«ÉTAáÉSÛ…wždZ'~|­Mè¡dA3&¨Ãe—’ç°ÛFt„^ÄL>„‹ëÞ«EÍA *X¼ÖõÑ\mE¶g" ´,a®ª"âÜr{ÍhV¢|èu{-7efÇ‘çó”C‰ðû	ìñÀ}‹’oådE>Iˆü8ÝW°ŽJdL·Æ–²u~t€bõxrNjÉ»@B÷ÄEg˜¤wYŽÖR¡ûwn¸ÊÒ«f*ñ@“Þ¢ÀÂ‘(Þ¾‘ZÄZ|î8qd5Ú²KŒÙ5-Îä– ¬ª¥$9£.CMåÊˆX—ÑŽ¤©vØælW!*aÔÉ"8†×!2cÖ1ã6†Wã‰6ê±çÜáˆ¬×c“w±ª
e0Æf:»Gu•°Z×"ªŸ›5ŒùZf¿29pråÃæÀ(\ÒïeÃØ™&›?ÀX	/¬`u“„¨t+ÆC¼ž.%Cß†Ô´ÙW3d1b!ši‹èð&xJY6Š2¢Ô,“áÕ,¼šQ„‚ú@ø§{`©d"ÞŠ’ç  gU"„Ô•K™‚ ƒž³8#c®|&õÊ3"æÊg2c¾¸Â¢\Sn,i¨VÔvD›M3N×9~fûàª‚WFe#;½*¼“	pUKacù…ŒÌ³¥¸„YŒŠÚ£I$¥ìEQÍšyö@F2Î­cÂÀ&?b‹2Ê‰Ï	Ññ=V''‘)69O‚oÞª¼ÂeåÂgà8¡\3 l¬[DÖdHtÔ¾HÅVœ8ÇY(øêÝ¿R?¾z÷3M­éHgØjÍo"‚Æ)LH±°ô1ðiœŸ?”äÞb· ÙóôS9ßŒŽì8µ²"j§Ð§4Ãê!ÌUM=ÝçùÆ:,¤9ƒuƒãd„…¶-]ÃQ†Öv4@Ë!ÓªÃ–^RGQý‘Û•Œ’øÀ”©á¹œ/DJÿþu<ÌäÚÙYR —E½§ÚŽa(¬¥®@r©.èS"×¯:®â²Z¥µÖœ:ªáÐ®Ô@F[Sö¾üÃU¨ßšÐO1æ(ù%g5#Ií®Ã¥²šku£”œ¹ ï¦A]5ã˜°{yÓlÀz¦Óv,‘„	›µÒ”›CUÐKãÍ“€½¯<x÷güÛÏÄ§t`Ðg%:"KvP*£ú˜\zP5´ìeÍu¨ÕëeÑý5ýqÔª&¼ ÐÝ{ÿÊî]S{Vþ°dÈ@£Çn†fe÷Ÿ°%eoÑ«Ä¡ e §|³¹È
	š~pw÷æGÍ÷Á5µ¶C8…Rö‹ÜÃÐ4šyP`	3ÆÝ“µ›¶¨)pz¢ƒž·]q.øyž‚&O-ûlWú
óØ0_^°^2Ôrú†"¤!(ƒqÔƒP3ip„ÌÂãâÀH?à¨EhG Üì'˜ór?;á6ªì9ÏhTµU²€xZPƒèï¶,Sõ™PÍ3ÞPÓ™ÁÓ‰r'JEË1‹ä[Zœ\ÍaÒýlíºçåU¨V–ø¦ô(`ˆ=.þ4•˜Fƒ¸…{Ú5Ê)"æÒ!…òãx\áþ½;R»¨¨,‚¨˜n=<‰¹ò3ôIÓ MòkÜ7ô;§Ô©Ÿd¼öËçáBJš	'¹‚Ê£i
¬….ƒ¶™¤ÍBr<¼å)ŠiÌ
	Yî¨j†@k¨µ…Š¼Øk&8¶âjX5ÒÌªÑ³Ïµ½6z,jô¦ôœïÖsò!3p·’JÿˆÃÛ:@ýc-f@bšEû½Á’-Š%s©‡9×5> %†É€àAæœofæ|&oàâCÕâXÒ¦Õ«~^tàÑ~Ð% ÄTU4Rw#(ƒw4dÄŽœØÆ‡,UÖd³Tt#rbQÖYQ	ücåâqß6hç%«‘÷¥ËQáÔ¦•½>1,Æ!»XóçQÇ™šI,º¿žá´{ì\Ü‡°j ï¢ÆfŒélÄŠ`©¥l‹({6uš M0Ã†««ŸÌÄe~ÚÕÀN˜éê‡¦tXTç¡Ž@s¿é¥©Ä¡¡qEÛï3 ¹¹l”lîþðåfÓÚ9e£“­ó®*<¼çìWèÁNatŒ»tËW6v b)_]@øÅÌ” Û|gŸ™—-esv'‹|š×î…­Š3ó†¤E¸¾<›{òzÛEŠ…—µcf‰¡²æÃ ÌUã…gÜè4¡Ö´÷Î	ß\Q”nàãŸlš ›q²YÓ%/²ÊŽ2;»qõLðœ0-´7&ÙP )A5¢¢Lµã—ßñ0ðJ¯{ª¼Âb‘ëƒ1
:QšÂÛ
Ù}•O¶t)KÌÐ%‡t‡yÑYQ8‡‡-Sš*wNÃ–¦‹aw/-ûúEcuö´’ƒòŒvVâ‹œÞp!h±ñmÊÙ–¯%NTÓp‹$Ú-’H¥\D“¨9ú ß(=GÊôjÔÖè‘l6¼‚Q­(Î‹¬^ÂžÚûIèN{?Òµ6 2Äå¥ßòÇ qÂ0Œ°É
È¿‡Ñ¦Ø*•ü†ÓjhM+™_§UâÅ!*ïÉÖ€Ý#d’ÍúýÊÄòÖ±|D%Ð=Ç­ÓG9,µÇÅ·X–ëà˜Z–E¯óÔÄJÛ`“‘igb"Nb‹œ¤Q›w£uœÔØ­|U"ã”¹äe{Ÿ›··¸øªÞK®}H•}¸ÔjŒ£#pÜ˜½q–$6÷¬¯É¡0†ýn$Ù|XQc™€ Ów²wâÁÐæƒ0yÀ°§¶çÈf	OHVF‘æÏ½Ìæ»È]ùŠ (ò¬%|už˜øèÒÖÿóÉÞõ+¹sêêÆ¤Ïïîýú¶³wë?ùÐ–ƒgÜñ("t¯‘”¯Toðmµrµ’~gZäð[ ³³Ñn‘à›Gl÷¡ùÖ9ZƒìÓ˜É•#þÆ…&«cPþ’ÝÉØVWw«Vø‡Y;ªÞÚ4’M¹WÇ¥Ü«ãPnƒ@ol2¢dg¿’Á>„pL{ÅÆ®²9c„c¹+¥2é}=ì®¡ËÛ¢p~á”••Šb´ÈÅÙ+l¯ž °ø…»d÷×‹qÔ…†sMû¦Û@…ƒÏ›cÝ Ùk/àÙÕ9ç™Â7qÚKç×1‚w†RØƒm2h½²°V²îŒ*8ÜTH¯÷7HNçí‘µý5}¥––²ŽdWC¬Üg£ ”úùÅÚâp >GUÌ2ÿ0»J2Ê¬Â§ìù@±«ñf”qÅÒ¡-sžLè'=@\/Š£L~sÍÒÖA^.åÓ¨5ÎdFÜg›4gæIHõ–¹3ß’LÄUÚ‹dêÆƒ…Ú«kOd«•Ÿ>WoÏÖøÆÓQ’Iø_>ZœŠMPñâÂž›“ÂãÍ”>ÃÑ¡Ï5rgø®&°Ä0É.BUþpuï‹”ÂdŽ±ß¸¹÷ñeŽ3J¿y‹P†Ôú,¡nl?ƒTa¤O5'ó†+qSzQ{86¼ñÇ½›7Ôh[(Š8£×]“ŽW06ÀÖ¸â ç+éKŽçS£®ß¼ÿçk a|­ëÙ¸ÃÞž÷ETc[CvmöýOïîþê°?˜_XºŸkžâ»~9îŒ6ñ½Í9˜U!^Ï2³–´„®UOð¶Ò
Îâ·nâÊá\hž¹Æ81.`$bÁ°,…í(ÎDÃ1ìÚ$µòV0)ÍVÅ¤”…!Dƒ—Ó5/Oåã„‚­,þ’X(p§ìp"<5O6bÖÖ“ètbw î>NÖJq úHæ”Rl¢gfÃü‘œüüšHÄŠ[Ä´3>«a!Þü‚rÃÈZ2!*mnSÎ(öîUë59™“×BK,Ê•5¤d<Û|Xh¶ÜH¸ÿ
‹Ñþ3ûTœïóÑ…ÆêTÐ­ƒÆj¤&‘Žrç1sˆ;æªÑyb^~ÌÓ	Q²žÚmM'%}‘	
Ò~;xÓ¯%@›¦}rÒ§¤«³òÕá~Š>‡GR”’AJáÞ ]ù:8ª‡îñª>RŠIW´á¯d÷²9½Uî˜-jw(À B‡º¦è½¶pØ-ô‚Iÿ±i-“ßùEÌìÐÆŒŒ¥ÙeœQ‡ÏôˆÿÂ4-c§ÙÜŠõèüxéþ32!’ÊAƒ‡ è\6hçŒÉdS`˜¢ýŠãÝ8ea½F›À§wÙ¦Í/$ššMã®
À®ØõNˆÁ–ø”ùÆ/[w½1ˆã:Sà(,‚~a‰çù‚+Äåt½·µ6<•vRÐ;¯úýäÇ»o~âàiòßÎ©~ˆfdþÇn"}BñÊÌˆ@®“¼ë”%56)0™=@MÔÈ3øôÎjÎ˜ åyzÌ\0!9®8Ï(f …U²éƒìä<®—x²TO{Y)EÿÖ­·¿ºü{wÇ*>?Z5qÀÈO}pZÔ=Ð¹(Bæ®ŽõRÃCãf2>‘“Ûr‰´ÅÄ€[­«¶-§›™OÛæ(5Ty&J1ÇQz¨«7°ßrÎ…´DœåÆáÀ¸ SaÙúkç;Òá$H¢öžçmœçm<kL±“#ÖåµájÈŠèîB½mã@­øå´­¼uæ|R-M,Ç§’&1EËü…t2¶«ä#MYŠH^bµYE¶Â‹­
vŽWNõüäÃÌ\ŠlRÄáÇ]n5G\Œ©*åõ(¹°@	#{Ô˜‹%ÝÌ§ØÀ®6X”Ä¡ƒÞÚZ;b¶‰£ihš…yá6æ¸^Í}Ú¡„‡Y[}òmö3cp%rŠeÀ„ˆ´ñ4hž&Êh?RM¢5<²åÌ‰ÔfAÏ‚NEå—Åžë@k£'¶õmÏð°ÂêH…Ÿ÷ýÈwb«å˜<¦b³9CiIÌ+á¥ïÊ§]ëÂQ¡&ÐkûˆQ“9@×érèèôPåêâ\6WßPôªP†ÅÄˆ\TÉ7Eß9JGxÎ­#‘÷ï\¹ÿÙ®HTåý;Ÿî½ySXkCâB €•9ñ€ˆƒVŽÇj¹S¤(¦,	%§×²ÈUªuñW‰x+DU1Qåaá_úÚ¤Jà³z3[Çœ()„KPWëiÔTÕŒ@ÁB®#mhÔô-OM>`¤2üàíÝ7ÿäp ÷p‘´-ùl E3X™ì BÆÒI"øð*:Ð`•Ÿ¨8{×¯ Ç…ßGªð zv,`á½lÆÅl÷ I²H0<öT•¼ìGªJÎS"õñi•'ðø´ÜŽ2½>è´OL|ç_ìLŸ›?õüËóA§õ­µÓwôÉ'é/|rgfŸ>òôwfžš=úä‘§ŽVÀó™™ÙêÑï8Õo­GÆgÕ^ÇùRõQåö{ÿ/úyÔ)¿¦$·tªC_ý‰	ûb£¯ÜÚûó{˜úvrR]Ò39‰b1>³Òâßýü.Z?å"q 
Àª2—š†TÌyº÷»»@‚€L ä6¥¿>™R¿¼§äï_ÝÁìªYFUJŒúÎz'}ÕéQ'¦È«qôøwwï]ƒÑA(^‘•	ïì…Á:Pô#ÁÑÃ§÷ÿþ%ºÕð•/Ý/®rVWßùê2Œé­_ìýï+»àœ{iþŒóŒÜèå+‡f%‹+çt…©›yê»Õêä¤c)Y3åy˜xôQçþŸnïýîÎÄÄÊÊÊÄRFf©ê²óÕ;—áÿ^I®Zø]s(	Î‹ó‹>—ûêÝ/œ%ËX}Š›ZfƒñWï¼áŒù)‚z6êhÐÁ¹…IþôírÍ¾Æ	CWaŒPA@ã†©³’÷fÊbY_Á›SgO{+Z·šf÷ÞJÅ‘g|ÀDÿÆH½<ÅÌ?IÈÓ/EŠ›8­­ÎéŠÈ>9ùH'Ìu`U†à›—÷>ü(C¸<7Ë¯µÁ¹Ô)²ŸüøÁû tZ6§ðâÊ§ÃS#hÄ0X’ÉÉl‹š—Ù²vnñ•©©>ý$+´Ÿ¾xŸbVd?½'ùŒaß—ç1.[Î)-=,Ic³¨lo÷Î¼ûQÍ÷WÿñKª="ÂMt#î–®ù8‘ùJ÷ÿß_÷nÞ#ãÝ»»o]qô!w±sç·äûÍ;{×ÿ&8²¿U0lÂÏo:œ ‡”;(ŠEÙj#ØâŒõˆål$«ÙQÓ§ìŽ/ï@÷‡‘•ôj¾•K¥“~ñYýÞÙÓ5Y9ÏºNg°}ÒØu¢õË¸ø%ïâÍJ^áj$†TrÇŽ{äõB°?ƒ©ž u°„ñI.:9Y³‰Ìüß¿4ØÓ§ÏéÖý‡—º_ðÝLÌð÷/­|PËì+ü”©”FòI*tû_3Ã)¸­Ko<IÃ¿ÄÇ$–ýQ·àÀðLz89i{Ñõæä¨¿2ØLÍy]Œ–žï~ü'œ`¼=‡z™íäÞH ·êRb¿Ü¯þã6wÕîxëpù,7ºZ¥’Hk\³â}/ê†…±\–m%ñs
¼¹B6.äõf(¬n¿¨<Ï¨ý
Ì‰oa›ˆ-Ôåñ%¯€‡¢ZA‰,¿Z ö#¬ÇP1’9NUÄÅL´Aè²—§±
Ñ÷I.h€
6‘n´z~s´ä6ô 4Ä –4|ÁÎ½_ÿñéæUì' —‡÷•Lk€%ºôáï×æ”ÜÞ¨¯¢È=PWdýà«
ùýþÍ	ÃúnuÆ"àãîG÷2¦³?	ÊM¢êM\;X  ?¿¥i3‰ÙüFW~:KÐçd-ZÆ¸yãþ§wO‘õ›u]Tâ§1 €LÞk”"ÑÙ}ã“û¾ì+ù(½ ítZNÖ¹ÝúŠL neªõv¿¸üàÚOŠçCŒÅiv	Èþám) V¸©æ íË0å
ržfâÃ2ïï\IÇpTØÙÈ’¾ÅWsûîýÏ~‚l7AõÖÛ@€€y0 Tç3f¿ù8Š®[·x÷ú5g…æoE¢[$˜íN™áãô®ó»’EÁLLd¦ÌC *“ ˆ×3Â @hNÒÈÇ—f‰µµ’L«‰6´OJ‘¥±‰ûwÞçË&´Bfòý÷/ç¨úõOîÿå=Ý$‹7JÊr<î'rC$¹~Ë}mwi-ÅLš$œ¸û«[x€‡$öÎçìsÓ~zY°ôÑ TŒ+Ó¸ÝR#Œ’z¯÷5(*8uœwá‰`$¤©)¥5¤ÃJ…,‚Ã²Ëë°si"ÿrk÷Î›²­p¬ÿv·¨pÈ hè”kà®1¨fËaÈèL¦“ˆ¶†Ô£ÝBó+÷Úriñ?¼âl@PýÓàûyØé ×ÇÑ÷IC="ï¦ÙŽô/˜t°šƒï%ñ,‡\r¼qË¹$ªéý;¿„ïPCÿ.M\šššÒÿAÑ¼%6üÍ¸’hnÂ¨0Çf·ØQ\Ïª"É¿$Ä’®ÍÉßóîUŽ®³ÊÂZQ½q¤?9Ë&¶p„ºfsh’Úµ¿”´eÔ.ŸÁ ‚X'Xb† UÛHb1Uµ¡“èõÀ…ú€Ž6ü|?û£C‘eawÿÎN'Ü®÷Ã¼ žÁÉë}$Ùˆ´rOñÍL½©¶:˜S×'¸ùŽ€ìƒ„
Eö›÷öÞ»“Øa‡k¨l{æU4Â¤,_EÔ(½tÐTh¦ù á4æ*9~}8Eà¬†í4¢;n>GÙ™´à Ô‰V£ŽáüØ0‘ùÕ´.{§ÕÀ^Œ ù¢¨•¿‚{úí“SgOã¦ØýÃ;H¸€ƒÀÖ ÓFí‹çáõŠaÑ_Ñm“K»„:›ºƒêP–:ÍÂçVçC-+ÔN¤Ç¢¸½Dž-Ú2¡K¹ÐÅ•‹”Ž½u;+y„”™RyúxÜ:!!xaœ¬`hÎÉŠŠê<I@%ên$Ža¤ÒÅHË¢u¬„õ%7€{[[sè÷÷?#é‡—ÀßI-©œôTûÀ×w«=.«<¦‹ÔÑ 
+Áûçï_jbs˜òÙÃº8Ø#>Û-§{ñFñ­—öwGÓ?ø–lÌ£íÿÕê‘§g2ûÿÌSß©¢ùæ¡ýÿŸñA'ž‹¬Ù­1SG‹ž[äÜôw…Ëç¸®«ogr-VŠµøq	Ì^šÌž>CKyÕ‘>¹+—FákáÊRàîÄÎ¿œ£î[ú™Üø­µ1zÿ?5säh~ÿÏ}èÿûç|\×ÕÚ9³lWë*´ÉÊ{Ã½zÀPKl"½UÃÃ†zeÉ~ÉÌáá™"î"ØÈ½>ž\šP†ý+ÚCÛÜIRc¹Ój„‰–™¶Ï°oÜÿ Þ`w'i•5G©r™·45…‡é6”U—ÉR¤µºå	X·‰¸COÂdˆg©ßQ’t{êF%¨ïÈâÕ÷^ª¾%º"žØué´×<ô¯ºÂ`=‰ÂVÜ]Ó€¦«ï  ¶ãŸË=0±šô:hÉjn$	†‚­n6@fq¤ô"?Ûëµç·£æÆ àP¼š4à	REŸ×÷C~)ì¶Úh¤ÄgÆÅU‘@Tµ³ð“_ðm ‹jx/ÇÛ§»\NF@Ó¬ÊÑúë)	½¼ jÀ¼ê €„©Ói5&&ž=µ0_þ4Þìˆ­{õ:eS¨û˜Ùkob²@€Ó1ñÜ«¯¼púÅúÙS‹/Ai]q/ŽÔ’š;±°xjñôsÓ,…¶Ë¸éNœ=ý|ý…Ógæs¯3ÛB?n¹ÏÏ¿pêûgé¢FòØÒ@‰ÅØ°DÿöÏ¶ÞÏ FHl)ÓüñZIÞ˜¨çUûUËmÔÞO÷g0%²Šmé·E“Ÿ)rRpÞR“ÜÖPhX—óÆ S•ò‹3†M€!’¯òmð´¦ÉÖÁ‚Rùl‘.õ´ÑèÚ¸¹‘ò^þ& #)B¯ÎÉókŸ·Š§è[qsà©ÍàÓ‹xÕ16cmÇ)†zÖ&ÔtoÅƒuJtæ¥ƒÄ3Êú¨7{HEæÜÁêÔ3®´`5«+-¬B{¸©
/[õ}‰¼ãœ·«kÐõç^xÏÐ˜ŸxþYE$ˆ¤@‘%=Ëþô¾Û8R*ˆÓzØ R³79r72 ‡
ºP¥ s¾'ÿHçxiBê½óôƒUœÝ7îî~q#a
Š0›Qac3+éàý÷Ð°òùe´'!q¯÷“Þög÷ö]<p<QÇ‰¥˜=›dî•·^îÝY!|€n¢^íiäÂ¼ú„mãïá'ý|8[G!?ÿ+Jb‘G/¨Þ§^œe±Žh‘¼z*Ù¾•Œ«‚¤v×GÊ¿ˆµÿýì¼Aäáˆ×>Ka†Çœæ:2œÁãVE
6ÓT—ƒïÃŠý(-Üìn†Ñ8¬Nº¹†•âlèiøqxúÄÛŠ‚Î:ÌÉWqÍo7#Êù"xÖ‡÷²ýº½¤¶ñ† X8/	·¤ˆ3O(/áç	û²z|"7“£PÄ§Ÿ Pëòš'”(†ÑbN/ÁCtMYßÓ{wGšmÈ$Œ¹SÊ]†œ5'îôáOwo~d$UÑ@\hÚ%Pq×„FY¸¥kË×½l06“´à¥ÈF6×£N¤àxTQÿb¬9Œ ßmèû÷[Ý8ÙøÞ»½{çÝîæ×œC©ërp!Ô¼rŸ3¿o,1&x3“™¿Ì "Z{£;£:š¹
Çï!IÅsÆLd+áâÜ 9}vó¨n[j¹K¸ôã°ã.»&¡u¥°VðÏ¡6è©E©Pù
Í†/hÌã¢ã5@­“%•Íðµ|sr'ÆÏ½Òëbð3ó~ú•!~TÊ‰$´ä’yïoï ¹©€²uo÷ö=§Éi*ŽyS“¼um÷æ-Ð¸$ÌË=Bj–mP½A` Eòz.7*ºf‡…luG£GÈ4ó…ì)a*ÑXúèu<ÉQç«=û–ÁJÉ-ƒ%ØHÌVÈ~@L fs*MWO
¢–I]Ë>ñâÄæÅ‚ê²À
™Âhoü&W$âEÃÅÎ»æ›
P€ŠM96hÍßG€Œ€ŒT7¤)ÏjëûçÎPSÑjsÅyuažsëç;bÁœM…`"âEøÏ{ú¹kø"Ê²‘¬yõ=ëØžãJ}µ‰Âíøö†¢«íÝ$ÛD-
â`Å©ãAŠ[°{zA%-e¥ê¾H\ O‰hc’0s&”uDŽ=µÅ3	ïgÃ?”²Fêjù¹Yà¥®§TûHg‡Å³›£·ee:pfÍé‰7ªàd0~ññ>Æ,[ì„"(;™xYÊž(ÖïqI¼e~ËèÚîO1£Ù
BõAtœY#âU«)»×¯‘U'ç/Cþ{ÿóOvQüù­Ý›WÖƒ_^¶ŽÀŠA	58U1Ôë^µW©K£34EcÞˆ\ßê%çaÎa¶û™JÆ÷,íkYM™ÚîÑjÚ@œéái»PÜ]mÇkë>Œ’KÉŽV1¹Ì¦b¥Ï£ŽÊrFá<”¨IÑlQMü1†(|zÿó?ýýK9f‰¡5w/—5£ICÃ›!.d7cƒ3r)Ó˜œ­>+àvÍÕ^Ò¤¤ÈºÕÏœ=>â‹võ­ð|dÍ8„IÕX@qyXu	<(›bŽàÖÛ½^ÉMÔéuE¿Ñ•9S‚Ù‚©èqš\?Ä¿4šØÌ'^Íæ¨Í<KæKiá’·ÜeJÃ¢ôÓi5èbÖ»SO´8Qñƒ‡
GÃfíéÔzÅ)s³­†Ó•Ÿä­õ¸‘Âo·eÑe4°ik¿P_™k‚˜Øv“D<MQ0‚e£Uæ¿þ¦"Ç>»Vlææ¹ ›[I3è.iƒØ²F49ºv(}­‹Ôš³û”Ížæóf‡½¥ómÖ<Ñ sóÔíáƒÈ­‰eã7Îñ%Â+{3Ù¦h[6	Ú¶âM©:kÕ´í^f­}É^¹0¦|æŒ…Ö›QØNC[¥Ê¨4™D±X?h>Š»Q6¡rà.—C0q»ÃøÀoµÇjNè²Ùq¡_¤Ÿm9S9"N\6ÄÔ@UµªÕ*@~}#&Öa‚ÖD5ì¶
Ð™vçáË¢›' }¥æüNöØsh­(“’|1Íƒƒt£Ñ‰™@„“L½J.™lßà“¾J‰l4	¨­ˆdÈ(YQ?à 
4|Rg›”ÙÑQIxsóg‹\»šÜí-×b°À¥
²–¯nÿ®Ø	þ´‘¶Â´žµT†?åëc`ÑÔÂÛ;`
e=.&"“jN§Û%3üâš+€ÂIA¬Øýñ»oÜVÐþ—ãøy©°×3ÇÌ›c ºT‚Ôròúb)¶«û)ŽfH	>)…†`€¼÷‡Ôç|ÃjK6!uñTÚÐªôÒI>N0IÒÒò0HÙÝŽ°Ò¢ø1Z)ž}“äÊl'Ñ²q¹?a¹œÄJ¯Õåª¥ÝÞ)âú>{?6…ÚÈâÒp3¢‚ŠÁU˜’°ž	µÆœ4 D¢ ŽÏ² ‰D“)rJ¤9Ð¾/ç0¦kä÷iq›êÑY!?4€8T1[*­ ¬}‹#Ù]}ˆ¤ücmz4¤ÿ«qt»_£¿šÝYó:1qöÕ3gæÉíËJ²Ÿ×ª1¨ÏT©‰ÝñÝŒ£-/Š†¶- bçaÿ.g‰ÿ<s‘˜®’ë‰Óa¢Z‘‡*ÆõÉ’Õ¶œ@è&«£ûü°-IŠÆoÊÅKÖi1Áâ÷¸ïú¼c©kÑîœvy‘¬(zXâflâT\¶5!=óIbä×ÄuPG²eKêÇJjàR$ã ®¤Ý¨9Kö\ï/ /gÓWê†&šÕ¬œP¥rØÕK|¦&it`[†»ünÇºÐaïu¼%ìåVêDS¬x˜ŒM¯3Q¦2°>Gªxaß¾61ŠÓ3î=ç™‚Ç”¹˜˜ÔÕ)]ÆT9´š,Ð‘÷#EÄG“™Y çmÍ¶Øò*¶la›æ”
ç²ŒyK9cUùCH/W‡tÚ.RŠ¿çËéM%¥²ß¶t‰·¬H×Õl^ùêØ&sí°Óh…ÎjÍYÙ“/?¯¢E;ÂG‘aØP[$»b€-Õhq—1w¾!°/Ë7ÑÍþôÜC÷@N²Ôn{±,÷éÙ0$,·ª?‰ø|QÙ6kÌ³„6É=|šZ?ç"\ªÍ`¡3©¸ˆ›ÙH4“Ñáó%üDi¸ysŽîåw­^Ržïÿ{Ï<4Àa2êä>§Òy$ÌXXË˜¸ Ÿå)ˆñrmf„85®­[‘dPTÎX#Ñqä0Qù‘c‹%czÒ“Lvšð² Ó¸Â;(…/™$U'x…p›bç²6¹¨ÚE[T‹3R„ZPU3¤AŽ‡§ãàê˜øŠU¬|øhã‡ƒ™³ÄÇÝR¯|¦]ÕüÒZ(`O’Nù›c®ZÜqP–ûÓ’H!YùŒH†¬Ò1„õÊBÑ’¸pYd=	1ÕUæ›ýÚ‡<¼²˜Ttx_ÿÄÎ%ékw¬,ËpI d)Žä6œ
u)¦ºycïÝ»¹d™£Î<\\Ò¼¯–Q§([
÷gÞÂB5†.ç-ó¡?bóíçöe_šÆ#fã‰‹$mº|“ÝÎ¶êPjˆ–Œ—ûû
‹´2»u™ÄThJÖ?·¸Š~+SSµZ&9 }³yÀSRnè'
#7]ðžÈð‡¿ìä©XNU-¥bãöV­uä<Øgv@Ñ>Ù·”³ÔáÛ©=!d5¤”Öˆ?báK}_K‡©Ólñ’ße}·©‘H%ôBz"Û)8F‹‡µô9­ÜÙ.ßÒõê üÑ6©ŸÃ0Ýã:}À¼h‚·ä>±²ìómŽˆ^¦«¼)éky ‰€þÒâËg(DäÎo1÷êœ|¨«f±-‡³Ý¼sÿÿß“t6˜ýèçø úA—[W"FêÞS¾×±ö¬a‘Å}›ÅR}=¿·ÄôÉè>Æd¿1SÍ;žé|_;Ç9T)s»›ß'ÑjŒ×·¨+µäjÍC¦‘Ù„e®(š¶=‘Â;5§¬%=ÐËè¢>]¡jÜX/žÈ¬×Æžá¹]ž7kKûø'H¢~;¤vÓå':©¯þ4è´ƒHe?ò¨Õì†ðŠ3Ã½i„]Ž½ÌL„OoÅ›0ÚÑœÛŠShãBmµm[ûµ™Ùþö1‹ÖºSñ ê¤µf„êï±>HÍqw­ötÛ™yÊ¬7™BU„«<‘Áo„Íók”J´¶&ÞÔTº‘¬Â8¦f+®VW«QË?Öè%­(™jôƒ^§6@Ó^¤l®Ào+¶Z°Ø'ÐÇCo‡œlS#höÚ@“¹^ØÄÞVŸ~¦uÔç>nEä:Z­Ã€Ê)Ä„B”j]è-ø·Ã$9f9>ž8žöÃî	u»ÞñÆ‰CéñéÆ	çñNÜjõÇüMeÌÎâƒ²nR7: ¼T}æ™g`ˆe¹{äH }|ÎhàãQ b¡…‰^"Ôò¿&Si&Íu RÇQÒ\úá‰åIÄ²›a7wŒ@Â9—j UV“ð–æ7ò¢¶laBhŠ¥66gŽþÒþ~pýÞî¯náÑ%›ÂRî¹W¿¿X °?”]í½Ö:ì{ÓÁ¤ò1 .UF+dÇŠ©Ö´Çòê%*/¡ÝÇŒzÈ¡1*¹ü¤ŠŠMzƒ,t•ò˜B²\,<=ÌM¥*æ{íµ6^Ú½µº$Z_Ùjäd˜¬™b<‡ãªJõg‹3Én.ô#,4G\/	ólO†Ú@ÚÓ~¯‹!­uµ‹‰ü£¶Æ)†2»lnG]’É
8vÕ°¹MI¾\2‘ö¦ÒA/‰Il•g“Œ•4J¤®wü€¨˜—s'Áº¹>doÓ|pÏW$ð€úŸ[vÊðZô?2× ?ï¼l$£¶6:ýÔ£òQh&(Bi3ŽçH¸òó›§T.,`ÂÀ5ãÌzŒ[?Ë 	ÛÉÓÍ®ÃÒxFYMÒÐ«f áEAµ„¦ŠârÔ@S<ÉwCjVÁ›á–Ñ?Gi'fø½Û“W	
qƒP¹ 
K€R¿.Äça: Ã6Êg±w1N)IM89-.žPñuÙ8×‰˜ÚHH®¹Ûa[VÜ9ùÞu˜$5Ü®BÓËáSÒ!9'£«r«Á°u ›äFÉó/Ò,Ûð¸ïl‹Î¤%`MêÇ¬˜t*ª£”E¾Ø&ÁAõ†B°÷é"&õ½BÞ•Í¥ê²EÔ9?ÏjSÑ‡œÏß„Ü‘-?-ã9ÿ²-Î$!oÚnú;ç©êl°÷lÒ;uÏÆýH¢aÏu#JO~Ï™p(°Ýq„ Ñ>¼1\û÷ºZª)K”r¬Í¯Z½:,jiL§Ú	´ê¾U£ëÉÀ$oˆ¼§;^·=²gP;pK5bƒN{ÆiÍiÇ»­h›õøDãêÓàÖ %9ûc8Ñí†òûtWÄt‚©ƒÆš9ü<5.š»VQâw1ž¬>i‡ü¤Ö³OÏÈügI©ªýðB›³à—x,Æ™PqòP±#tÇÏ›É2OÄÒåç²L¼1Zwc™´tŸy(z	mÈ8SIÜÌë·FÞ	xY«cÍáEòšb ”XfGÍ¢¾-gœÍìºßh-¾ÊA9×+r<2¥óMR"amy.¦êÀå¦ÃŠ[:Þ!nÚvr‹ä¸MŒñ9àea2åæÿÑm‰.‡ßh¿!Y2Sä§	&þVA2‚¸ÆWžŒp¦™(D1­Xd,úûun24£]ì<aÃ¾­A·!ÓAÓ~;Œ».0ƒKu¦Çjö&3›‘É,ní”7¯Ñ•?Rn+ö¡`‹{R¬ žsãë·èºC6ëùžî"¢hTÞhù ,¡¶ª[X¶HE6`?ìö-.—cp [‘3£ùÇ_‹ž1{ãø§öi³Lýgú±ppGüRÖaØ@ö1]óV×¾&\-çîÅ·t¡¬x(9ó}*Y¤ª_¯ÏxÏ’{-ÁD¦°{ü…ä×%ÂyfS¨‹Àp &1_…3´xv¾3y‹ÌÂ©óyô! 7¼ºI´
^`¥øº—ò=vÀ¶êû˜XÑ±¼ly^U›ãjD‘ÖÃ”NFò‰JX¶…Wëóÿë¹3ß_8ýƒùSÏ?îûóùEdÁ„yÀo½þ@@¯ž©/¼úÜ÷æõ9Í˜ÚŸlB‚ÂÄ'TÇëò¼NªÂŸ÷9æ"ŽjÊªÌa%P ¯©“· ÚŽ ¤¨&ú1ˆÅíx3òúÚùn±Lƒó1HY}>@ÏmÝnØ)XÊX„O_‚ù³óç^6À´àª½dP»uXsÏ8˜-ý¡#\ä›vgfŸ¦3î2./ú¦-ˆÛOÒ*á×ZMG,a™ÌkÈÀ°Ž€á¨æQ^Ï&à)ÈFM­w{r´LºšYž.uk/Îâˆ¨6©L–?5a	ìžÍˆ–mj^ÙÒÁü¨tA¬"g÷tä.jð=2ã$Ðí^èÚ]ÔÔ®aý6Bt@xP]
ûH½$›Up*Y£«Ïâ¯ÄkEœ æsÎÍßYTž,»ÁH°:ìs—@ö\N²åâ¥ç”Ê`x+Uò\#Š?e?€5Š8ãÉKÂäž”â¼ù
X²–’<Í‰¥jªN‹Ù‰(áZ%KÌéÓ•ŒŽ±bDÐJw±ú0q‡¤ª&M#}$6FÅ(yÒÁ®¡“5ÈòY£ði$Âv¸î8®$Ô~píX:Ë,/õ²æé¾Ç1òp€XÙW<Ré·‚nC´[mëbRGÊ‡¹YµÌlTÑTL`O³@½ðÎœ^ aÓ·¦!PiçÌ:¥)kµŽ\>/’íí¸uwÁ	uMƒ!âà½Fèõ]0c_v€c‘”óæœ!¦œÐBðÅ¢«ôš‰kV2›BÆ“lþJŽÛ§É¦>]±úrÀå%ƒe@O» óäš§_!¾©sàØ¿ÿ¶p*{pj&OºÊGƒ
<àíˆŠ&o5thÓ„EøˆÏòŽÌ“Ja©”]/à?žüZ8ýâ"0»Š#q“a-ã½U©)"¡:uLXœ 50R7¢d€Ç¡@æ•¬3”ÉDoKÊP6ý§¤«,> ‹
VÛxizù
³8R^‰áÄ6Í÷¾]hôÂ¤uÃ ’>4´@»{†V¶g/tI½Ùî¥æÁ"Sv‚XLñÕõ:	qõ:2—z]Ô*æ4ó¾ÚŸ`úóçN¿úÊ·ØÆ~ùŸ«³Fþ×£˜ÿµúôÑ‡ù_ÿ)ŸÙêìÑ™êÌÑ©'›Qãé£O?Ü????????ÿ³?ÿüÒl  