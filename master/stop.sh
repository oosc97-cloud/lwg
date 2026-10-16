#!/bin/bash
# fs-master 중지 — 이 폴더에서 실행 중인 fs-master만 멈춘다.
DIR="$(cd "$(dirname "$0")" && pwd -P)"
. "$DIR/master-pids.sh"
PIDS=$(master_pids)
if [ -z "$PIDS" ]; then echo "실행 중인 fs-master가 없습니다."; else echo "fs-master 중지: PID $(echo $PIDS)"; stop_pids $PIDS; fi
rm -f "$DIR/fs-master.pid"
