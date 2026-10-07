#!/bin/bash
# Usage: stall-dump.sh <log-file> <out-dir> [stall-seconds]
#
# Watches <log-file>; each time it stops growing for <stall-seconds>, dumps every test host into
# <out-dir>: a thread sample (a blocked thread) and the Swift concurrency runtime's task tree with
# async backtraces (a suspended task, which no thread sample can show). Up to three dumps, then exits.
log=$1; out=$2; stall=${3:-300}
last=-1; quiet=0; dumps=0
while sleep 10; do
    size=$(stat -f%z "$log" 2>/dev/null || echo 0)
    if [ "$size" != "$last" ]; then last=$size; quiet=0; continue; fi
    quiet=$((quiet + 10))
    [ "$quiet" -lt "$stall" ] && continue
    quiet=0; dumps=$((dumps + 1)); mkdir -p "$out"
    pids=$(pgrep -x xctest); [ -z "$pids" ] && pids=$(pgrep -x xcodebuild)
    for pid in $pids; do
        ps -o pid=,ppid=,etime=,command= -p "$pid" >> "$out/$dumps-processes.txt"
        sample "$pid" 5 -file "$out/$dumps-sample-$pid.txt" >/dev/null 2>&1
        swift-inspect dump-concurrency "$pid" > "$out/$dumps-tasks-$pid.txt" 2>&1
    done
    [ "$dumps" -ge 3 ] && exit 0
done
