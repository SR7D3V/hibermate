#!/bin/sh
# A visible end-to-end test of Hibermate with the lid closed.
#
# The Mac itself writes the time every 5 seconds. Gaps in that record show
# exactly when it was asleep. (Cloud apps like ChatGPT can't show this: their
# work happens on a server, which keeps going while the Mac sleeps.)
#
#   scripts/lid-test.sh run --no-hold [minutes]   Control: Hibermate isn't told about the work.
#                                                 Expect a gap while the lid is closed.
#   scripts/lid-test.sh run --hold [minutes]      Hibermate holds via its generic integration.
#                                                 Expect no gap, then sleep about 1 min after the work ends.
#   scripts/lid-test.sh report                    Run after reopening the lid: gaps, macOS sleep/wake
#                                                 events, and Hibermate's log for the last run.
#
# Start a run, close the lid within a few seconds, and reopen it a couple of
# minutes after the run should have finished. Default length: 3 minutes.
set -u

LOG="$HOME/hibermate-lid-test.log"
HOOK="$HOME/Library/Application Support/Hibermate/hooks/hibermate-hook"
[ -x "$HOOK" ] || HOOK="/Applications/Hibermate.app/Contents/MacOS/hibermate-hook"

run() {
    MODE="$1"
    MINUTES="${2:-3}"
    case "$MODE" in --hold|--no-hold) ;; *) echo "usage: $0 run --hold|--no-hold [minutes]"; exit 2 ;; esac
    if [ "$MODE" = "--hold" ]; then
        [ -x "$HOOK" ] || { echo "Hibermate's hook isn't installed; open Hibermate first."; exit 1; }
        pgrep -xq Hibermate || { echo "Hibermate isn't running; open it first."; exit 1; }
    fi
    ID="lid-test-$$"
    START=$(date +%s)
    END=$((START + MINUTES * 60))
    {
        echo "# mode=$MODE start=$START end=$END"
    } > "$LOG"

    if [ "$MODE" = "--hold" ]; then
        trap '"$HOOK" generic end "$ID"; exit 130' INT TERM
        "$HOOK" generic start "$ID"
        echo "Hibermate told that work started (session $ID). The menu bar bear should open one eye."
    fi
    echo "Writing the time every 5 s for $MINUTES min. Close the lid now."
    echo "Reopen it about $((MINUTES + 2)) min from now, then run: $0 report"

    LAST_BEAT=$START
    while [ "$(date +%s)" -lt "$END" ]; do
        date +%s >> "$LOG"
        NOW=$(date +%s)
        if [ "$MODE" = "--hold" ] && [ $((NOW - LAST_BEAT)) -ge 60 ]; then
            "$HOOK" generic heartbeat "$ID"
            LAST_BEAT=$NOW
        fi
        sleep 5
    done
    echo "# finished=$(date +%s)" >> "$LOG"
    if [ "$MODE" = "--hold" ]; then
        # Work done: Hibermate starts its grace period, then lets the Mac sleep.
        "$HOOK" generic end "$ID"
    fi
    echo "Run finished at $(date +%T)."
}

report() {
    [ -f "$LOG" ] || { echo "No test log found. Start one with: $0 run --hold"; exit 1; }
    HEADER=$(head -1 "$LOG")
    MODE=$(echo "$HEADER" | sed -n 's/.*mode=\([^ ]*\).*/\1/p')
    START=$(echo "$HEADER" | sed -n 's/.*start=\([0-9]*\).*/\1/p')
    END=$(echo "$HEADER" | sed -n 's/.*end=\([0-9]*\).*/\1/p')
    FINISHED=$(sed -n 's/^# finished=//p' "$LOG")
    fmt() { date -r "$1" +%T; }

    echo "== Run: $MODE, planned $(fmt "$START") → $(fmt "$END")"
    [ -n "$FINISHED" ] && echo "   finished at $(fmt "$FINISHED")" || echo "   (not finished; still running or interrupted)"

    echo
    echo "== Gaps in the Mac's own timestamps (over 15 s = the Mac was asleep)"
    GAPS=$(grep -v '^#' "$LOG" | awk 'NR > 1 && $1 - prev > 15 { printf "%s %s %d\n", prev, $1, $1 - prev } { prev = $1 }')
    if [ -z "$GAPS" ]; then
        echo "   none: the Mac stayed awake for the whole run"
    else
        echo "$GAPS" | while read -r a b secs; do
            echo "   asleep from $(fmt "$a") to $(fmt "$b") ($((secs / 60)) min $((secs % 60)) s)"
        done
    fi

    echo
    echo "== macOS sleep/wake events since the run started"
    SINCE=$(date -r "$START" '+%Y-%m-%d %H:%M:%S')
    pmset -g log | grep -E "^[0-9-]+ [0-9:]+ [+-][0-9]{4} (Sleep|Wake|DarkWake) " \
        | awk -v since="$SINCE" '($1" "$2) >= since' | cut -c12-19,26-140 | sed 's/^/   /'

    echo
    echo "== Hibermate's log since the run started"
    /usr/bin/log show --start "$SINCE" --predicate 'subsystem BEGINSWITH "com.sr7d3v.hibermate"' --style compact 2>/dev/null \
        | grep -v '^Timestamp' | cut -c12-19,24-200 | sed 's/^/   /'

    echo
    echo "== Verdict"
    if [ "$MODE" = "--no-hold" ]; then
        [ -n "$GAPS" ] && echo "   As expected: without Hibermate, the Mac slept while the lid was closed (see the gap)." \
                       || echo "   No gap: was the lid closed? On AC with an external display, a Mac doesn't sleep anyway."
    else
        [ -z "$GAPS" ] && echo "   PASS: Hibermate kept the Mac awake for the whole run." \
                       || echo "   The Mac slept during the run. Check Hibermate's log above for the reason (e.g. a safety release)."
        if [ -n "$FINISHED" ] && pmset -g log | grep -E " Sleep " | awk -v since="$(date -r "$FINISHED" '+%Y-%m-%d %H:%M:%S')" '($1" "$2) >= since' | grep -q .; then
            echo "   PASS: the Mac went to sleep after the work finished."
        else
            echo "   No sleep after the run yet: was the lid opened before the grace period (60 s) ended?"
        fi
    fi
}

case "${1:-}" in
    run) shift; run "$@" ;;
    report) report ;;
    *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
