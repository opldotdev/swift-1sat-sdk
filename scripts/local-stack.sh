#!/usr/bin/env bash
# Starts or stops the local stack (Tools/local-stack): real 1Sat wallet storage on localhost with a
# stub chain, for `ONESAT_LIVE=local swift test --filter OneSatLiveTests`.
#
#   scripts/local-stack.sh start    # prints the URL to export as ONESAT_LOCAL_URL
#   scripts/local-stack.sh stop
#   scripts/local-stack.sh status
#   scripts/local-stack.sh logs
#
# Environment: LOCAL_STACK_PORT (18199), LOCAL_STACK_STORAGE_PORT (18198), LOCAL_STACK_CHAIN
# (test | main, default test), LOCAL_STACK_STATE (where the pid, log and sqlite live; default
# .build/local-stack, wiped on each start), NO_BATCH=1 (storage without action batches).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="$ROOT/Tools/local-stack"
STATE="${LOCAL_STACK_STATE:-$ROOT/.build/local-stack}"
PORT="${LOCAL_STACK_PORT:-18199}"
PIDFILE="$STATE/server.pid"
LOG="$STATE/server.log"
URL="http://127.0.0.1:$PORT"

running() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

case "${1:-}" in
start)
	if running; then
		echo "local stack already running (pid $(cat "$PIDFILE")) at $URL"
		exit 0
	fi
	command -v bun >/dev/null || { echo "bun is required: https://bun.sh" >&2; exit 1; }
	(cd "$STACK" && bun install --frozen-lockfile)
	rm -rf "$STATE"
	mkdir -p "$STATE/data"
	LOCAL_STACK_PORT="$PORT" LOCAL_STACK_DIR="$STATE/data" \
		nohup bun run "$STACK/server.ts" >"$LOG" 2>&1 &
	echo $! >"$PIDFILE"
	for _ in $(seq 1 60); do
		if curl -fsS "$URL/__stack/health" >/dev/null 2>&1; then
			echo "local stack running (pid $(cat "$PIDFILE")) at $URL"
			echo "export ONESAT_LOCAL_URL=$URL"
			exit 0
		fi
		if ! running; then
			echo "local stack exited during startup; log follows ($LOG):" >&2
			cat "$LOG" >&2
			exit 1
		fi
		sleep 0.5
	done
	echo "local stack did not answer $URL/__stack/health within 30 s; log follows ($LOG):" >&2
	cat "$LOG" >&2
	exit 1
	;;
stop)
	if running; then
		kill "$(cat "$PIDFILE")"
		echo "local stack stopped"
	else
		echo "local stack not running"
	fi
	rm -f "$PIDFILE"
	;;
status)
	if running; then echo "running (pid $(cat "$PIDFILE")) at $URL"; else echo "not running"; exit 1; fi
	;;
logs)
	cat "$LOG"
	;;
*)
	echo "usage: $0 start|stop|status|logs" >&2
	exit 2
	;;
esac
