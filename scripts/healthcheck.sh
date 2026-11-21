#!/bin/bash
# Container healthcheck for a cron job container (the image HEALTHCHECK).
#
# Unhealthy when:
#   - SWI_CRON_MAX_SECONDS > 0 and the current run has been active for longer than that, or
#   - SWI_CRON_MAX_SECONDS is 0 or unset (strict mode) and a start was attempted while a run
#     was still active (an overlap).
#
# Docker Swarm replaces an unhealthy task, which also ends the stuck job. The state files are
# written by run-cron; the reason is printed so it shows in `docker inspect` health logs.

STATE_DIR="${SWI_CRON_STATE_DIR:-/tmp/swi-cron}"
MAX="${SWI_CRON_MAX_SECONDS:-0}"
now="$(date +%s)"

case "$MAX" in
    '' | *[!0-9]*)
        echo "invalid SWI_CRON_MAX_SECONDS='$MAX'"
        exit 1
        ;;
esac

if [ "$MAX" -gt 0 ]; then
    started="$(cat "$STATE_DIR/run.start" 2>/dev/null || true)"
    if [ -n "$started" ] && [ $((now - started)) -gt "$MAX" ]; then
        echo "run active for $((now - started))s, longer than SWI_CRON_MAX_SECONDS=$MAX"
        exit 1
    fi
elif [ -f "$STATE_DIR/overlap" ]; then
    echo "a start was attempted while a run was still active (strict mode, SWI_CRON_MAX_SECONDS=0)"
    exit 1
fi

exit 0
