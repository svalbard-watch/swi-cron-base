#!/bin/bash
# shellcheck disable=SC2329  # the helpers below are invoked through check()
# Behaviour tests for run-cron, healthcheck.sh and entrypoint.sh. Run inside the built image:
#   docker run --rm --entrypoint bash -v "$PWD/tests:/tests:ro" <image> /tests/run-tests.sh

RUN=/opt/swi-cron/run-cron
HEALTH=/opt/swi-cron/healthcheck.sh
ENTRY=/opt/swi-cron/entrypoint.sh
FAILED=0
N=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILED=$((FAILED + 1)); }
check() { # check "name" command...
    local name="$1"
    shift
    N=$((N + 1))
    if "$@"; then pass "$name"; else fail "$name"; fi
}

new_state() {
    export SWI_CRON_STATE_DIR
    SWI_CRON_STATE_DIR="$(mktemp -d)"
    unset SWI_CRON_PRE_COMMAND SWI_CRON_KILL_SECONDS DOCKER_CRON
    export SWI_CRON_MAX_SECONDS=0
}
healthy() { "$HEALTH" >/dev/null; }
unhealthy() { ! "$HEALTH" >/dev/null; }
exists() { [ -e "$SWI_CRON_STATE_DIR/$1" ]; }
absent() { [ ! -e "$SWI_CRON_STATE_DIR/$1" ]; }
content_is() { [ "$(cat "$SWI_CRON_STATE_DIR/$1")" = "$2" ]; }
wait_for() { # wait_for <state file> : up to 5 s
    for _ in $(seq 1 50); do [ -e "$SWI_CRON_STATE_DIR/$1" ] && return 0; sleep 0.1; done
    return 1
}

echo "# a successful run"
new_state
export SWI_CRON_COMMAND="echo job-output"
out="$($RUN)"
check "exits 0" test $? -eq 0
check "prints the job output" grep -q job-output <<<"$out"
check "records last_success" exists last_success
check "records exit code 0" content_is last_exit 0
check "clears the run marker" absent run.start
check "is healthy afterwards" healthy

echo "# a failing run"
new_state
export SWI_CRON_COMMAND="exit 3"
$RUN >/dev/null
check "propagates the exit code" test $? -eq 3
check "records exit code 3" content_is last_exit 3
check "records no success" absent last_success
check "clears the run marker" absent run.start

echo "# no command configured"
new_state
unset SWI_CRON_COMMAND
$RUN >/dev/null 2>&1
check "exits 2" test $? -eq 2

echo "# pre-command"
new_state
export SWI_CRON_COMMAND="touch $SWI_CRON_STATE_DIR/job-ran"
export SWI_CRON_PRE_COMMAND="exit 7"
$RUN >/dev/null
check "a failing pre-command aborts the run with its exit code" test $? -eq 7
check "the job is not started" absent job-ran
export SWI_CRON_PRE_COMMAND="touch $SWI_CRON_STATE_DIR/pre-ran"
$RUN >/dev/null
check "a passing pre-command lets the job run" exists job-ran
check "the pre-command ran first" exists pre-ran

echo "# overlap, strict mode (SWI_CRON_MAX_SECONDS=0)"
new_state
export SWI_CRON_COMMAND="sleep 4"
$RUN >/dev/null &
first=$!
wait_for run.start
out="$($RUN)"
check "a second start exits 0" test $? -eq 0
check "a second start is skipped" grep -q skipping <<<"$out"
check "the overlap is recorded" exists overlap
check "the container is unhealthy" unhealthy
wait "$first"
check "the first run still finishes with exit code 0" content_is last_exit 0
check "the overlap is cleared when the run ends" absent overlap
check "the container is healthy again" healthy

echo "# overlap, tolerated (SWI_CRON_MAX_SECONDS=60)"
new_state
export SWI_CRON_MAX_SECONDS=60
export SWI_CRON_COMMAND="sleep 3"
$RUN >/dev/null &
first=$!
wait_for run.start
$RUN >/dev/null
check "the overlap is recorded" exists overlap
check "a run within the limit stays healthy" healthy
wait "$first"
check "the overlap is cleared when the run ends" absent overlap

echo "# a run longer than SWI_CRON_MAX_SECONDS"
new_state
export SWI_CRON_MAX_SECONDS=1
export SWI_CRON_COMMAND="sleep 5"
$RUN >/dev/null &
first=$!
wait_for run.start
check "is healthy at first" healthy
sleep 2.5
check "turns unhealthy once the limit is passed" unhealthy
check "says why" grep -q "longer than" < <("$HEALTH")
wait "$first"
check "is healthy again after the run" healthy

echo "# hard limit (SWI_CRON_KILL_SECONDS)"
new_state
export SWI_CRON_KILL_SECONDS=1
export SWI_CRON_COMMAND="sleep 30"
start=$(date +%s)
$RUN >/dev/null
check "the job is terminated with exit code 124" test $? -eq 124
check "in about the limit, not the job length" test $(($(date +%s) - start)) -lt 10
check "clears the run marker" absent run.start
check "records exit code 124" content_is last_exit 124

echo "# invalid configuration"
new_state
export SWI_CRON_MAX_SECONDS=abc
check "a non-numeric SWI_CRON_MAX_SECONDS is unhealthy" unhealthy

echo "# entrypoint, one-shot (DOCKER_CRON unset)"
new_state
export SWI_CRON_COMMAND="exit 4"
$ENTRY >/dev/null
check "exits with the job's exit code" test $? -eq 4

echo "# entrypoint, DOCKER_CRON set"
new_state
export DOCKER_CRON=1
export SWI_CRON_COMMAND="echo first-run"
$ENTRY >"$SWI_CRON_STATE_DIR/entry.log" &
entry=$!
wait_for last_success
sleep 0.5
check "the container stays alive after the first run" kill -0 "$entry"
check "re-running via run-cron works" $RUN >/dev/null
kill -TERM "$entry"
stopped=0
for _ in $(seq 1 30); do kill -0 "$entry" 2>/dev/null || { stopped=1; break; }; sleep 0.1; done
check "stops promptly on SIGTERM" test "$stopped" -eq 1

echo
if [ "$FAILED" -eq 0 ]; then
    echo "all $N checks passed"
    exit 0
fi
echo "$FAILED of $N checks failed"
exit 1
