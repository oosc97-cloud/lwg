# restart.sh / stop.sh 공용: 이 폴더($DIR)에서 실행된 fs-master 프로세스만 찾는다.
# 기준: 작업 폴더(cwd)가 $DIR 이고 명령줄이 "python... server.py" 인 프로세스.
master_pids() {
  local d p
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    [ "$p" = "$$" ] && continue
    [ "$(readlink "$d/cwd" 2>/dev/null)" = "$DIR" ] || continue
    tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -Eq "^[^ ]*python[0-9.]* (-u )?server\.py( |$)" && echo "$p"
  done
}

stop_pids() {
  local i p alive
  kill "$@" 2>/dev/null
  for i in $(seq 1 20); do
    alive=""
    for p in "$@"; do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
    [ -z "$alive" ] && return 0
    sleep 0.5
  done
  kill -9 $alive 2>/dev/null
}
