#!/bin/bash
# fs-agent 재기동 — 이 폴더에서 실행 중인 fs-agent만 멈추고 다시 띄운다.
# 다른 프로그램의 server.py나 포트는 건드리지 않는다 (pkill -f 사용 안 함).
# 포트는 config.json의 "port" (기본 15891). 다른 프로세스가 그 포트를 쓰고 있으면 시작하지 않는다.
DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$DIR" || exit 1
. "$DIR/agent-pids.sh"

PIDS=$(agent_pids)
if [ -n "$PIDS" ]; then
  echo "fs-agent 중지: PID $(echo $PIDS)"
  stop_pids $PIDS
fi
rm -f "$DIR/fs-agent.pid"

setsid nohup python3 -u server.py --host 0.0.0.0 "$@" > fs-agent.log 2>&1 < /dev/null &
sleep 2
tail -3 fs-agent.log
[ -f "$DIR/fs-agent.pid" ] || { echo "fs-agent가 시작되지 않았습니다. 위 메시지를 확인하세요."; exit 1; }
