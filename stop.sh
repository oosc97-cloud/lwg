#!/bin/bash
# fs-agent 중지 — 이 폴더에서 실행 중인 fs-agent만 멈춘다.
DIR="$(cd "$(dirname "$0")" && pwd -P)"
. "$DIR/agent-pids.sh"
PIDS=$(agent_pids)
if [ -z "$PIDS" ]; then echo "실행 중인 fs-agent가 없습니다."; else echo "fs-agent 중지: PID $(echo $PIDS)"; stop_pids $PIDS; fi
rm -f "$DIR/fs-agent.pid"
