#!/bin/bash
# Manual e2e test for upstream_monitor.sh: outage/recovery, then DNS drift.
# Brings up a clean stack itself and tears it down again on exit - normal
# completion, error, or Ctrl+C. Requires at least one NXCT_ALERT_*_WEBHOOK
# configured in .env. Watch your alerting channel while this runs.

# Repo-root-relative paths below need this regardless of the caller's cwd
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

CONTAINER="frontend"

OTHER_PIDS=$(pgrep -f "e2e_alerting.sh" | grep -v "^$$\$")
if [ -n "$OTHER_PIDS" ]; then
  echo "Another instance of this test is already running (PID(s): $OTHER_PIDS), aborting."
  exit 1
fi

cleanup() {
  # Capture the exit code pending BEFORE this trap ran - otherwise the exit
  # status of the last command below (docker compose down) would silently
  # override the real pass/fail result of the script.
  local exit_code=$?
  echo ""
  echo "=== Cleaning up: stopping the stack ==="
  docker compose down
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

wait_for_log() {
  local pattern="$1"
  local since="$2"
  echo "Waiting for: $pattern"
  until docker logs --since "$since" proxy 2>&1 | grep -q "$pattern"; do
    sleep 3
  done
  docker logs --since "$since" proxy 2>&1 | grep "$pattern" | tail -3
}

# Lists every domain whose "/" location proxies to $1, read from the
# generated Nginx configs (/conf/*.conf) rather than NXCT_SERVICE_* env vars -
# when nothing is configured, entrypoint.sh's own defaults (e.g. "localhost"
# and "127.0.0.1") only ever get exported inside entrypoint.sh's process and
# don't show up via "docker exec ... env" or even /proc/1/environ (Docker's
# default seccomp profile blocks reading another process's environ, even
# root's own PID 1). The rendered config is the actual source of truth either
# way. With multiple domains configured, a single wildcard grep on the log
# only guarantees ONE of them fired, not all - so callers must wait for each.
get_domains_for_container() {
  local target="$1"
  docker exec proxy sh -c "
    for f in /conf/*.conf; do
      grep -q 'proxy_pass http://${target};' \"\$f\" 2>/dev/null || continue
      grep -E '^[[:space:]]*server_name[[:space:]]' \"\$f\" | awk '{print \$2}' | tr -d ';'
    done
  " | sort -u
}

echo "=== Step 0: ensure a clean stack ==="
docker compose down
rm -rf ./.volumes/proxy/certs/.nxct_monitor

echo "Building proxy image..."
docker compose build proxy

# Start frontend/backend first so Docker's DNS has them registered before Nginx
# starts - otherwise proxy_pass can fail to resolve them at config-load time
# ("host not found in upstream"), which is a hard startup failure, not a
# retryable outage.
docker compose up -d frontend backend
sleep 3

echo "Starting proxy..."
docker compose up -d proxy

# entrypoint.sh starts Nginx twice: once in daemon mode early on (to allow LE
# checks), then stops it, sleeps 5s, starts the monitor, and finally execs
# Nginx in the foreground - that exec is the literal last line of the script.
# A plain curl/log-line check can match the FIRST start and let the outage
# test begin before the final restart even happens, which then fails with the
# same "host not found" error if frontend is down by then (self-inflicted).
# So wait specifically for the line right before that final exec, then for a
# "start worker process" AFTER it - that only happens once entrypoint.sh has
# fully finished.
echo "Waiting for entrypoint.sh's final Nginx restart..."
POLL_SINCE=$(date +%s)
FINAL_RESTART_SEEN=false
NGINX_READY=false
for i in $(seq 1 60); do
  if ! docker ps --filter "name=^proxy$" --filter "status=running" --format '{{.Names}}' | grep -q proxy; then
    echo "proxy is not running, (re)starting it..."
    docker compose up -d proxy
    sleep 2
    continue
  fi

  if [ "$FINAL_RESTART_SEEN" != true ]; then
    if docker logs --since "$POLL_SINCE" proxy 2>&1 | grep -q "if no errors appear below, it is ready"; then
      FINAL_RESTART_SEEN=true
    fi
  else
    if docker logs --since "$POLL_SINCE" proxy 2>&1 | grep -q "start worker process"; then
      NGINX_READY=true
      break
    fi
  fi
  sleep 2
done

if [ "$NGINX_READY" != true ]; then
  echo "Nginx never completed its startup sequence, aborting."
  docker logs proxy 2>&1 | tail -30
  exit 1
fi
echo "Nginx is ready."

# Domain probing is a separate, independently-thresholded check on top of the
# plain upstream check. NXCT_ALERT_PROBE_DOMAINS is multi-shape (see
# upstream_monitor.sh) - mirror its exact parsing here so the test only waits
# for domains that are actually being probed under the current setting,
# instead of hanging forever on one that's been excluded/not allow-listed.
PROBE_DOMAINS_RAW=$(docker exec proxy sh -c 'echo "${NXCT_ALERT_PROBE_DOMAINS:-true}"')
PROBE_MODE="all"
PROBE_LIST=()
case "${PROBE_DOMAINS_RAW,,}" in
  ""|true|yes|1|on) PROBE_MODE="all" ;;
  false|no|0|off)   PROBE_MODE="none" ;;
  !*)
    PROBE_MODE="deny"
    IFS=',' read -ra PROBE_LIST <<< "${PROBE_DOMAINS_RAW#!}"
    ;;
  *)
    PROBE_MODE="allow"
    IFS=',' read -ra PROBE_LIST <<< "$PROBE_DOMAINS_RAW"
    ;;
esac
for i in "${!PROBE_LIST[@]}"; do
  PROBE_LIST[$i]=$(echo "${PROBE_LIST[$i]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
done

if [ "$PROBE_MODE" != "none" ]; then
  ALL_DOMAINS=$(get_domains_for_container "${CONTAINER}:80")
  DOMAINS=""
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    case "$PROBE_MODE" in
      allow)
        in_list=false
        for x in "${PROBE_LIST[@]}"; do [ "$x" = "$d" ] && in_list=true && break; done
        [ "$in_list" = true ] && DOMAINS+="$d"$'\n'
        ;;
      deny)
        in_list=false
        for x in "${PROBE_LIST[@]}"; do [ "$x" = "$d" ] && in_list=true && break; done
        [ "$in_list" = false ] && DOMAINS+="$d"$'\n'
        ;;
      *)
        DOMAINS+="$d"$'\n'
        ;;
    esac
  done <<< "$ALL_DOMAINS"
  DOMAINS="${DOMAINS%$'\n'}"

  if [ -z "$DOMAINS" ]; then
    echo "No domains map to ${CONTAINER}:80 on \"/\" under the current NXCT_ALERT_PROBE_DOMAINS setting - skipping domain-level checks"
  else
    echo "Domains serving ${CONTAINER}:80 on \"/\" being probed: $(echo "$DOMAINS" | tr '\n' ' ')"
  fi
fi

echo "=== Step 1: simulate an outage ==="
SINCE=$(date +%s)
docker compose stop "$CONTAINER"
wait_for_log "UNREACHABLE: ${CONTAINER}:80" "$SINCE"
if [ -n "$DOMAINS" ]; then
  while IFS= read -r domain; do
    wait_for_log "DOMAIN UNREACHABLE: https://${domain}/ -> ${CONTAINER}:80" "$SINCE"
  done <<< "$DOMAINS"
fi

echo "=== Step 2: recover from the outage ==="
SINCE=$(date +%s)
docker compose start "$CONTAINER"
wait_for_log "RECOVERED: ${CONTAINER}:80" "$SINCE"
if [ -n "$DOMAINS" ]; then
  while IFS= read -r domain; do
    wait_for_log "DOMAIN RECOVERED: https://${domain}/ -> ${CONTAINER}:80" "$SINCE"
  done <<< "$DOMAINS"
fi

echo "=== Step 3: simulate a DNS drift ==="
# Derived from the container itself rather than assumed - Compose's default
# network name ("<project>_default") depends on the directory name / project
# name and isn't guaranteed to stay "nginxcrypt_default".
NETWORK=$(docker inspect "$CONTAINER" --format '{{range $net,$conf := .NetworkSettings.Networks}}{{$net}}{{end}}')
CURRENT_IP=$(docker inspect "$CONTAINER" --format '{{range $net,$conf := .NetworkSettings.Networks}}{{$conf.IPAddress}}{{end}}')
PREFIX=$(echo "$CURRENT_IP" | cut -d. -f1-3)
USED_IPS=$(docker network inspect "$NETWORK" --format '{{range .Containers}}{{.IPv4Address}}{{"\n"}}{{end}}' | cut -d/ -f1)

NEW_IP=""
for i in $(seq 2 254); do
  CANDIDATE="$PREFIX.$i"
  if [ "$CANDIDATE" != "$CURRENT_IP" ] && ! echo "$USED_IPS" | grep -qx "$CANDIDATE"; then
    NEW_IP="$CANDIDATE"
    break
  fi
done

if [ -z "$NEW_IP" ]; then
  echo "No free IP found in ${PREFIX}.0/24, aborting drift test"
  exit 1
fi

echo "Moving $CONTAINER from $CURRENT_IP to $NEW_IP"
SINCE=$(date +%s)
docker network disconnect "$NETWORK" "$CONTAINER"
docker network connect --ip "$NEW_IP" "$NETWORK" "$CONTAINER"
wait_for_log "DNS CHANGE: ${CONTAINER}:80.*${CURRENT_IP} -> ${NEW_IP}" "$SINCE"

# The notification always fires on drift, but the reload itself is gated by
# NXCT_ALERT_RELOAD_ON_DNS_CHANGE - wait for whichever outcome is actually
# configured instead of assuming a reload always happens.
RELOAD_ENABLED=$(docker exec proxy sh -c 'echo "${NXCT_ALERT_RELOAD_ON_DNS_CHANGE:-true}"' | tr '[:upper:]' '[:lower:]')
case "$RELOAD_ENABLED" in
  false|no|0|off)
    wait_for_log "reload disabled - ${CONTAINER}:80" "$SINCE"
    RELOAD_EXPECTED=false
    ;;
  *)
    wait_for_log "Nginx reloaded" "$SINCE"
    RELOAD_EXPECTED=true
    ;;
esac

echo "=== Step 4: verify the site behaves as expected ==="

# The test only checks upstream_monitor.sh's own logs - it can't see whether a
# notification actually landed in Discord/Teams. Flag it clearly if no
# webhook is even configured, since then nothing was ever sent at all.
DISCORD_SET=$(docker exec proxy sh -c 'echo "${NXCT_ALERT_DISCORD_WEBHOOK}"')
MSTEAMS_SET=$(docker exec proxy sh -c 'echo "${NXCT_ALERT_MSTEAMS_WEBHOOK}"')
if [ -z "$DISCORD_SET" ] && [ -z "$MSTEAMS_SET" ]; then
  WEBHOOK_CONFIGURED=false
else
  WEBHOOK_CONFIGURED=true
fi

if [ "$RELOAD_EXPECTED" = true ]; then
  # nginx -s reload briefly overlaps old/new worker processes while rotating,
  # so the very first probe right after the log line can still occasionally
  # hit an old worker still holding the stale IP - allow a short grace period.
  CODE=""
  for i in $(seq 1 5); do
    CODE=$(curl -sk -o /dev/null -w '%{http_code}' https://localhost/ --resolve localhost:443:127.0.0.1)
    [ "$CODE" = "200" ] && break
    sleep 1
  done
  echo "https://localhost/ -> HTTP $CODE"
  if [ "$CODE" = "200" ]; then
    echo "E2E alerting test PASSED"
    if [ "$WEBHOOK_CONFIGURED" = false ]; then
      echo "NOTE: no NXCT_ALERT_DISCORD_WEBHOOK/NXCT_ALERT_MSTEAMS_WEBHOOK configured - detection was verified via logs only, no notification was actually sent"
    fi
  else
    echo "E2E alerting test FAILED (expected 200 after reload, got $CODE)"
    exit 1
  fi
else
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' https://localhost/ --resolve localhost:443:127.0.0.1)
  echo "https://localhost/ -> HTTP $CODE"
  # Reload is disabled on purpose, so Nginx should still be pinned to the
  # stale IP and the site should NOT be healthy - that's the whole point.
  if [ "$CODE" != "200" ]; then
    echo "E2E alerting test PASSED (reload disabled - site correctly stayed pinned to the stale IP, HTTP $CODE)"
    if [ "$WEBHOOK_CONFIGURED" = false ]; then
      echo "NOTE: no NXCT_ALERT_DISCORD_WEBHOOK/NXCT_ALERT_MSTEAMS_WEBHOOK configured - detection was verified via logs only, no notification was actually sent"
    fi
  else
    echo "E2E alerting test FAILED (reload is disabled but site still returned 200 - expected it to stay broken)"
    exit 1
  fi
fi
