#!/bin/bash
# fs-master 재기동 — 이 폴더에서 실행 중인 fs-master만 멈추고 다시 띄운다 (pkill -f 사용 안 함).
# 포트는 config.json의 "port" (기본 15900). 다른 프로세스가 그 포트를 쓰고 있으면 시작하지 않는다.
DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$DIR" || exit 1
. "$DIR/master-pids.sh"

PIDS=$(master_pids)
if [ -n "$PIDS" ]; then
  echo "fs-master 중지: PID $(echo $PIDS)"
  stop_pids $PIDS
fi
rm -f "$DIR/fs-master.pid"

setsid nohup python3 -u server.py --host 0.0.0.0 "$@" > fs-master.log 2>&1 < /dev/null &
sleep 2
tail -3 fs-master.log
[ -f "$DIR/fs-master.pid" ] || { echo "fs-master가 시작되지 않았습니다. 위 메시지를 확인하세요."; exit 1; }
