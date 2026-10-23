#!/usr/bin/env bash
# Start PAIR's broker on a headless box and leave it running.
#
# WHY THE BROKER AND NOT `nvpair-tui`: the terminal interface is keyboard-driven
# and stops when its connection drops, so nothing scripted can drive it. The
# broker is the same service tree with a JSON-RPC API, which is what the bridge's
# live test talks to.
#
#   scripts/run-pair-broker.sh            # start (idempotent)
#   scripts/run-pair-broker.sh status     # is it up?
#   scripts/run-pair-broker.sh stop
#
# The socket and the log live under the user's home, so nothing needs root.
set -euo pipefail

PAIR_HOME=${PAIR_HOME:-$HOME/pair}
BIN=${PAIR_BIN:-$PAIR_HOME/Personal-AI-Router/services/build/bin}
SOCKET=${NVPAIR_IPC:-${XDG_RUNTIME_DIR:-/tmp}/nvpair-broker.sock}
LOG=${NVPAIR_LOG:-$PAIR_HOME/broker.log}

running() {
    [ -S "$SOCKET" ] && pgrep -f nvpair-ui-broker >/dev/null 2>&1
}

case ${1:-start} in
    status)
        if running; then echo "broker up, socket $SOCKET"; else echo "broker down"; exit 1; fi
        ;;
    stop)
        pkill -f nvpair-ui-broker 2>/dev/null || true
        rm -f "$SOCKET"
        echo "stopped"
        ;;
    start)
        if running; then echo "already up, socket $SOCKET"; exit 0; fi
        [ -x "$BIN/nvpair-ui-broker" ] || { echo "no broker at $BIN; run scripts/install-pair.sh" >&2; exit 1; }
        # The broker resolves its workers beside itself, so it runs from BIN.
        ( cd "$BIN" && nohup ./nvpair-ui-broker -ipc "$SOCKET" >> "$LOG" 2>&1 & )
        for _ in $(seq 1 30); do
            [ -S "$SOCKET" ] && { echo "broker up, socket $SOCKET, log $LOG"; exit 0; }
            sleep 1
        done
        echo "broker did not open $SOCKET; last log lines:" >&2
        tail -20 "$LOG" >&2
        exit 1
        ;;
    *)
        echo "usage: $0 [start|status|stop]" >&2
        exit 2
        ;;
esac
