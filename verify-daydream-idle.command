#!/bin/zsh

set -euo pipefail

readonly APP_NAME="daydream"
readonly SAMPLE_COUNT="${DAYDREAM_IDLE_SAMPLE_COUNT:-6}"
readonly SAMPLE_INTERVAL="${DAYDREAM_IDLE_SAMPLE_INTERVAL:-1}"
readonly CPU_LIMIT="${DAYDREAM_IDLE_CPU_LIMIT:-2.5}"

for _ in {1..20}; do
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        break
    fi
    sleep 0.25
done

PID="$(pgrep -x "$APP_NAME" | head -n 1 || true)"
if [[ -z "$PID" ]]; then
    print -u2 -- "Error: $APP_NAME is not running."
    exit 1
fi

print -- "Waiting for $APP_NAME to become idle..."
sleep 4

CPU_TOTAL="0"
for _ in $(seq 1 "$SAMPLE_COUNT"); do
    CPU_VALUE="$(ps -p "$PID" -o %cpu= | tr -d '[:space:]' || true)"
    if [[ -z "$CPU_VALUE" ]]; then
        print -u2 -- "Error: $APP_NAME exited during idle CPU verification."
        exit 1
    fi
    CPU_TOTAL="$(awk -v total="$CPU_TOTAL" -v value="$CPU_VALUE" 'BEGIN { printf "%.3f", total + value }')"
    sleep "$SAMPLE_INTERVAL"
done

CPU_AVERAGE="$(awk -v total="$CPU_TOTAL" -v count="$SAMPLE_COUNT" 'BEGIN { printf "%.2f", total / count }')"
print -- "Idle CPU average: ${CPU_AVERAGE}% (${SAMPLE_COUNT} samples)"

if ! awk -v average="$CPU_AVERAGE" -v limit="$CPU_LIMIT" 'BEGIN { exit(average <= limit ? 0 : 1) }'; then
    print -u2 -- "Error: Idle CPU average exceeded the ${CPU_LIMIT}% regression limit."
    exit 1
fi

print -- "Idle CPU verification passed."
