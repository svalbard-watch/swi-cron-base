# swi-cron-base

Shared base image for the SWI cron job containers (`swi-metobs-caching`,
`swi-aromearctic-caching`, `swi-avalanche-caching`, `swi-mapcache-seaice`). It puts the
run-once-at-a-time logic in one place, so a job that hangs or overlaps makes its container
**unhealthy** and Docker Swarm replaces it.

## How a job runs

The container starts with `DOCKER_CRON=1`, runs the job once, and stays alive. A Dokploy
Schedule re-runs it with `docker exec <container> /swi/run-cron.sh` (`run-cron` is also on the
`PATH`). Without `DOCKER_CRON` the container runs the job once and exits with its exit code.

`run-cron` takes a `flock` so only one run is active. A start while a run is still active does
**not** start a second job: it records an overlap and exits 75 in strict mode (so the
scheduler's log shows the skipped start) or 0 when `SWI_CRON_MAX_SECONDS > 0`. The image `HEALTHCHECK`
(`healthcheck.sh`) then decides:

| `SWI_CRON_MAX_SECONDS` | Unhealthy when |
|---|---|
| `> 0` | the current run has been active longer than that |
| `0` or unset (strict, default) | a start was attempted while a run was active |

The overlap and run markers are cleared when the run ends, so the container recovers by itself
if the job was merely slow. A job that is really stuck stays unhealthy, and Swarm kills and
replaces the task, which ends the job. The new container runs the job once on start.

## Configuration (environment)

| Variable | Meaning |
|---|---|
| `SWI_CRON_COMMAND` | The job, run with `bash -c`. Required (the job image sets it). |
| `SWI_CRON_PRE_COMMAND` | Optional step before the job. A failure aborts the run with its exit code. |
| `SWI_CRON_MAX_SECONDS` | Longest acceptable run, see above. Set per service in the stack. |
| `SWI_CRON_KILL_SECONDS` | Optional hard limit: the job is terminated after this long (exit 124). At or below `SWI_CRON_MAX_SECONDS` a hung job is killed before the container can turn unhealthy, so leave it unset to keep the unhealthy signal. |
| `SWI_CRON_STATE_DIR` | Run state directory, default `/tmp/swi-cron`. |
| `DOCKER_CRON` | Set to keep the container alive after the first run. |

## Using it in a job image

```dockerfile
# Dependencies are installed in a builder stage (the base has no pip), then copied in.
FROM python:3.13-slim AS builder
...
FROM ghcr.io/svalbard-watch/swi-cron-base:1.0.0-py3.13
USER root
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*          # only if the job needs system packages
COPY --from=builder /usr/local/lib/python3.13/site-packages /usr/local/lib/python3.13/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin
COPY . /swi
RUN mkdir -p /swi/data && chown swi:swi /swi/data   # mount points for shared volumes
ENV SWI_CRON_COMMAND="python /swi/main.py"
USER swi
```

The base provides the `swi` user (uid/gid 9001), `/swi`, the entrypoint and the healthcheck, so
the job image needs no `entrypoint.sh` or `run-cron.sh` of its own. It must end with `USER swi`.

## Tags

One image per Python version, because a job copies the packages it installed for that version:
`<version>-py<python>` (for example `1.0.0-py3.13`), plus `<major>.<minor>-py<python>`,
`<major>-py<python>` and `py<python>`. Dependabot (docker ecosystem) in each job repo bumps the
`FROM` line when a new base version is released.

## Development

```bash
docker build --build-arg PYTHON_VERSION=3.13 -t swi-cron-base:dev .
docker run --rm --entrypoint bash -v "$PWD/tests:/tests:ro" swi-cron-base:dev /tests/run-tests.sh
```

The tests cover the lock, overlap handling in strict and tolerant mode, the maximum duration,
the hard limit, the pre-command, and the entrypoint modes. CI also runs ShellCheck. Releases are
made by release-please from conventional commits.
