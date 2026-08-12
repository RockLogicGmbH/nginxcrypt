# e2e_alerting.sh

End-to-end test for `upstream_monitor.sh`'s alerting and DNS-drift self-healing. Brings up a clean copy of the compose stack itself, runs through an outage/recovery cycle and a simulated DNS drift, then tears the stack down again - on normal completion, on error, or on Ctrl+C.

### Prerequisites

- Docker and Docker Compose installed
- At least one of `NXCT_ALERT_DISCORD_WEBHOOK` / `NXCT_ALERT_MSTEAMS_WEBHOOK` set in `.env` at the repo root, so you can visually confirm the notifications in your channel while the test runs
- Can be run from any directory - it `cd`s to the repo root itself before touching `docker-compose.yaml` or `.env`

### Usage

```bash
bash tests/e2e_alerting.sh
```

### What it does

1. **Clean slate** - tears down any existing stack, clears the monitor's persistent state (`.volumes/proxy/certs/.nxct_monitor/`) so leftover cooldowns from previous runs can't suppress this run's alerts, rebuilds the `proxy` image so the test always runs against your latest `upstream_monitor.sh`/`entrypoint.sh` changes rather than a stale cached image, then starts frontend/backend first and proxy after (avoids a startup race where Nginx's `proxy_pass` fails to resolve a backend that isn't registered in Docker's DNS yet). Waits specifically for `entrypoint.sh`'s _final_ foreground Nginx restart to complete - not just any Nginx start, since `entrypoint.sh` starts Nginx twice (once early in daemon mode, once in foreground at the very end).
2. **Outage** - stops `frontend`, waits for the `UNREACHABLE` alert.
3. **Recovery** - starts `frontend` back up, waits for the `RECOVERED` alert.
4. **DNS drift** - moves `frontend` to a genuinely different, unused IP on its Docker network (via `docker network disconnect`/`connect --ip`, picked dynamically - never assumes a fixed network name or IP), waits for the `DNS CHANGE` alert, then waits for whichever outcome is actually configured: a reload (`NXCT_ALERT_RELOAD_ON_DNS_CHANGE=true`, the default) or the "reload disabled" log line (`=false`).
5. **Final check** - curls `https://localhost/` and asserts the result matches what should have happened: `200` if the reload ran, or a broken response if reload was deliberately disabled (Nginx should stay pinned to the stale IP in that case).

### Notes

- Timing depends on your `.env`'s `NXCT_ALERT_THRESHOLD`/`NXCT_ALERT_INTERVAL` - lower values make the test run faster.
- If interrupted (Ctrl+C) or on any failure, the stack is still torn down via a cleanup trap - you shouldn't need to manually `docker compose down` afterward.
- Running a second copy while one is already active is blocked automatically (checked via `pgrep -f`) - they'd otherwise fight over the same compose project and containers.
- The test only checks `upstream_monitor.sh`'s own logs, not whether a notification actually landed in Discord/Teams - if no webhook is configured at all, the final result says so explicitly rather than passing silently.
