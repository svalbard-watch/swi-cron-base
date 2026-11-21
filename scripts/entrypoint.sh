#!/bin/bash
# Image entrypoint for cron job containers.
#
#   DOCKER_CRON unset: run the job once and exit with its exit code (a plain one-shot container).
#   DOCKER_CRON set:   run the job once, then keep the container alive so an external scheduler
#                      can re-run it with `docker exec <container> run-cron`. SIGTERM stops
#                      the container promptly (PID 1 has no default signal handlers).

if [ -z "${DOCKER_CRON:-}" ]; then
    exec /opt/swi-cron/run-cron
fi

/opt/swi-cron/run-cron

echo "[swi-cron] container is now waiting for commands; re-run the job with 'run-cron'"
sleep infinity &
sleeper=$!
trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM INT
wait "$sleeper"
