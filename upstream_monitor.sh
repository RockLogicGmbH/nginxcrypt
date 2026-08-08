#!/bin/bash

# Checks all configured NXCT_SERVICE_* upstreams at a regular interval and sends
# alerts to Discord and/or MS Teams when an upstream has been unreachable for too long.
# Controlled entirely via NXCT_ALERT_* env vars - does nothing if none are set.

INTERVAL="${NXCT_ALERT_INTERVAL:-30}"
THRESHOLD="${NXCT_ALERT_THRESHOLD:-60}"
COOLDOWN="${NXCT_ALERT_COOLDOWN:-600}"
DISCORD_WEBHOOK="${NXCT_ALERT_DISCORD_WEBHOOK:-}"
MSTEAMS_WEBHOOK="${NXCT_ALERT_MSTEAMS_WEBHOOK:-}"
LOG_TIMESTAMP_FORMAT="${NXCT_ALERT_LOG_TIMESTAMP_FORMAT:-}"

log() {
  if [ -n "$LOG_TIMESTAMP_FORMAT" ]; then
    echo "$(date +"$LOG_TIMESTAMP_FORMAT") $1"
  else
    echo "$1"
  fi
}

if [ -z "$DISCORD_WEBHOOK" ] && [ -z "$MSTEAMS_WEBHOOK" ]; then
  exit 0
fi

STATE_DIR="/certs/.nxct_monitor"
mkdir -p "$STATE_DIR"

# Fetch host public IP once at startup for alert context
HOST_IP=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || echo "unknown")

sanitize() {
  echo "$1" | tr -cs 'a-zA-Z0-9._-' '_'
}

send_discord() {
  local title="$1"
  local message="$2"
  local payload
  payload=$(printf '{"content":"**%s**\\n%s"}' "$title" "$message")
  curl -s -o /dev/null -X POST "$DISCORD_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    --max-time 10
}

send_msteams() {
  local title="$1"
  local message="$2"
  local color="$3"
  local payload
  payload=$(printf '{"@type":"MessageCard","@context":"https://schema.org/extensions","themeColor":"%s","title":"%s","text":"%s"}' \
    "$color" "$title" "$message")
  curl -s -o /dev/null -X POST "$MSTEAMS_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    --max-time 10
}

send_alert() {
  local title="$1"
  local message="$2"
  local color="${3:-EA4300}"
  [ -n "$DISCORD_WEBHOOK" ] && send_discord "$title" "$message"
  [ -n "$MSTEAMS_WEBHOOK" ] && send_msteams "$title" "$message" "$color"
}

# Returns lines of "upstream|domain1,domain2,..." for all configured services
get_upstream_map() {
  local services
  services=$(env | grep 'NXCT_SERVICE_HOST_' | cut -d= -f1 | sed 's/^NXCT_SERVICE_HOST_//')

  declare -A up_domains

  for service in $services; do
    domain_var="NXCT_SERVICE_HOST_${service}"
    domain="${!domain_var}"
    [ -z "$domain" ] && continue

    for prefix in NXCT_SERVICE_PROXY_ NXCT_SERVICE_FRONTEND_TARGET_ NXCT_SERVICE_BACKEND_TARGET_; do
      var="${prefix}${service}"
      upstream="${!var}"
      [ -z "$upstream" ] && continue

      if [ -z "${up_domains[$upstream]}" ]; then
        up_domains[$upstream]="$domain"
      else
        case ",${up_domains[$upstream]}," in
          *",$domain,"*) ;;
          *) up_domains[$upstream]="${up_domains[$upstream]}, $domain" ;;
        esac
      fi
    done
  done

  for upstream in "${!up_domains[@]}"; do
    echo "${upstream}|${up_domains[$upstream]}"
  done
}

check_upstream() {
  local upstream="$1"
  [[ "$upstream" != http://* ]] && [[ "$upstream" != https://* ]] && upstream="http://$upstream"
  curl -s -o /dev/null --max-time 5 --connect-timeout 5 "$upstream"
}

while true; do
  upstream_map=$(get_upstream_map)

  while IFS='|' read -r upstream domains; do
    [ -z "$upstream" ] && continue

    key=$(sanitize "$upstream")
    down_file="$STATE_DIR/down_${key}"
    last_alert_file="$STATE_DIR/last_alert_${key}"

    if check_upstream "$upstream"; then
      if [ -f "$down_file" ]; then
        if [ -f "$last_alert_file" ]; then
          log "[upstream-monitor] RECOVERED: $upstream (serving: $domains)"
          send_alert "Upstream recovered" \
            "Upstream $upstream serving $domains on host $HOST_IP is back online." \
            "00B050"
        fi
        rm -f "$down_file" "$last_alert_file"
      fi
    else
      now=$(date +%s)
      [ ! -f "$down_file" ] && echo "$now" > "$down_file"

      down_since=$(cat "$down_file")
      down_for=$(( now - down_since ))

      if [ "$down_for" -ge "$THRESHOLD" ]; then
        should_alert=true
        if [ -f "$last_alert_file" ]; then
          last_alert=$(cat "$last_alert_file")
          [ $(( now - last_alert )) -lt "$COOLDOWN" ] && should_alert=false
        fi
        if [ "$should_alert" = true ]; then
          log "[upstream-monitor] UNREACHABLE: $upstream (serving: $domains) - down for ${down_for}s"
          send_alert "Upstream unavailable" \
            "Upstream $upstream serving $domains on host $HOST_IP has been unreachable for ${down_for}s." \
            "EA4300"
          echo "$now" > "$last_alert_file"
        fi
      fi
    fi
  done <<< "$upstream_map"

  sleep "$INTERVAL"
done
