# Shared base for the SWI cron job images (swi-metobs-caching, swi-aromearctic-caching,
# swi-avalanche-caching, swi-mapcache-seaice): the unprivileged user, the run lock, the
# overlap/timeout handling and the healthcheck, so the four jobs behave the same way.
# One image per Python version (see PYTHON_VERSION), because a job copies its installed
# packages from a builder stage of the same Python version.
ARG PYTHON_VERSION=3.13
FROM python:${PYTHON_VERSION}-slim

# The project reserves uids above 9000. Every SWI image that shares a volume with a job
# (the other cron jobs, mapproxy, the read-only data services) uses the same uid and gid,
# so files written here are owned by the same user everywhere.
ARG APP_UID=9001
ARG APP_GID=9001

# The jobs never install packages at runtime: remove pip (and its vendored copies of
# urllib3, msgpack, ...) so they are neither exposed nor flagged by image scanners. A job
# image installs its dependencies in a separate builder stage and copies them in.
RUN python -m pip uninstall -y pip setuptools wheel 2>/dev/null || true

# Unprivileged user with a home directory (some jobs write there, e.g. git).
RUN groupadd --gid "${APP_GID}" swi \
    && useradd --uid "${APP_UID}" --gid "${APP_GID}" --create-home --shell /usr/sbin/nologin swi \
    && mkdir -p /swi \
    && chown swi:swi /swi

COPY scripts/ /opt/swi-cron/
# `run-cron` on the PATH, and /swi/run-cron.sh for the existing Dokploy Schedules, which call
# the script by that path.
RUN chmod 0755 /opt/swi-cron/run-cron /opt/swi-cron/healthcheck.sh /opt/swi-cron/entrypoint.sh \
    && ln -s /opt/swi-cron/run-cron /usr/local/bin/run-cron \
    && ln -s /opt/swi-cron/run-cron /swi/run-cron.sh

WORKDIR /swi

# Job images set SWI_CRON_COMMAND (and optionally SWI_CRON_PRE_COMMAND). SWI_CRON_MAX_SECONDS
# is set per service in the stack; 0 means strict: any overlapping start is unhealthy.
ENV SWI_CRON_MAX_SECONDS=0 \
    SWI_CRON_STATE_DIR=/tmp/swi-cron

# Job images that need root (apt-get) must switch back with `USER swi` afterwards.
USER swi

HEALTHCHECK --interval=30s --timeout=5s --retries=1 --start-period=10s \
    CMD ["/opt/swi-cron/healthcheck.sh"]

ENTRYPOINT ["/opt/swi-cron/entrypoint.sh"]
