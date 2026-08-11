#!/bin/bash

# Checks all configured NXCT_SERVICE_* upstreams at a regular interval and sends
# alerts to Discord and/or MS Teams when an upstream has been unreachable for too long.
# Also reloads Nginx when a backend's DNS answer changes, because Nginx only resolves
# proxy_pass hostnames at start/reload and would keep proxying to a dead or recycled IP.
# Alerts are opt-in via NXCT_ALERT_*, the reload runs either way.

INTERVAL="${NXCT_ALERT_INTERVAL:-30}"
THRESHOLD="${NXCT_ALERT_THRESHOLD:-60}"
COOLDOWN="${NXCT_ALERT_COOLDOWN:-600}"
DISCORD_WEBHOOK="${NXCT_ALERT_DISCORD_WEBHOOK:-}"
MSTEAMS_WEBHOOK="${NXCT_ALERT_MSTEAMS_WEBHOOK:-}"
LOG_TIMESTAMP_FORMAT="${NXCT_ALERT_LOG_TIMESTAMP_FORMAT:-}"
RELOAD_ON_DNS_CHANGE="${NXCT_ALERT_RELOAD_ON_DNS_CHANGE:-true}"
PROBE_DOMAINS="${NXCT_ALERT_PROBE_DOMAINS:-true}"

# Absolute path: the cron watchdog restarts this script with a minimal PATH
NGINX_BIN="/usr/sbin/nginx"

# Matches a single IPv4 address (same approach as entrypoint.sh)
IPV4_RE='([0-9]{1,3}\.){3}[0-9]{1,3}'

log() {
  if [ -n "$LOG_TIMESTAMP_FORMAT" ]; then
    echo "$(date +"$LOG_TIMESTAMP_FORMAT") $1"
  else
    echo "$1"
  fi
}

# "false", "no", "0" and "off" mean false, anything else (including unset) means true
normalize_bool() {
  case "${1,,}" in
    false|no|0|off) echo "false" ;;
    *) echo "true" ;;
  esac
}
RELOAD_ON_DNS_CHANGE=$(normalize_bool "$RELOAD_ON_DNS_CHANGE")
PROBE_DOMAINS=$(normalize_bool "$PROBE_DOMAINS")

# Without a webhook nothing is sent, but the loop still runs for the DNS reload
ALERTS_ENABLED=true
if [ -z "$DISCORD_WEBHOOK" ] && [ -z "$MSTEAMS_WEBHOOK" ]; then
  ALERTS_ENABLED=false
fi

STATE_DIR="/certs/.nxct_monitor"
mkdir -p "$STATE_DIR"

# Fetch host public IP once at startup for alert context
HOST_IP="unknown"
if [ "$ALERTS_ENABLED" = true ]; then
  HOST_IP=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || echo "unknown")
fi

# True only during the first pass of this process, see check_dns_drift
FIRST_ITERATION=true

# HTTP status of the last check_upstream call
LAST_HTTP_CODE=""

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
  local icon payload
  case "$color" in
    EA4300) icon="🔴" ;;
    00B050) icon="🟢" ;;
    FFC000) icon="🟡" ;;
    *)      icon="" ;;
  esac
  payload=$(printf '{"@type":"MessageCard","@context":"https://schema.org/extensions","themeColor":"%s","title":"NginxCrypt Notification Bot","sections":[{"activityTitle":"%s **%s**"},{"text":"%s"}]}' \
    "$color" "$icon" "$title" "$message")
  curl -s -o /dev/null -X POST "$MSTEAMS_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    --max-time 10
}

send_alert() {
  local title="$1"
  local message="$2"
  local color="${3:-EA4300}"
  [ "$ALERTS_ENABLED" = true ] || return 0
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

# Returns lines of "domain|path|upstream". The templates serve BACKEND_TARGET_N on
# "/api", PROXY_N and FRONTEND_TARGET_N on "/".
get_domain_map() {
  local services service domain_var domain prefix var upstream path
  services=$(env | grep 'NXCT_SERVICE_HOST_' | cut -d= -f1 | sed 's/^NXCT_SERVICE_HOST_//')

  declare -A seen

  for service in $services; do
    domain_var="NXCT_SERVICE_HOST_${service}"
    domain="${!domain_var}"
    [ -z "$domain" ] && continue

    for prefix in NXCT_SERVICE_PROXY_ NXCT_SERVICE_FRONTEND_TARGET_ NXCT_SERVICE_BACKEND_TARGET_; do
      var="${prefix}${service}"
      upstream="${!var}"
      [ -z "$upstream" ] && continue

      case "$prefix" in
        NXCT_SERVICE_BACKEND_TARGET_) path="/api" ;;
        *) path="/" ;;
      esac

      [ -n "${seen["${domain}|${path}"]}" ] && continue
      seen["${domain}|${path}"]="$upstream"
      echo "${domain}|${path}|${upstream}"
    done
  done
}

# Strips scheme, path and port: http://frontend:3000/foo -> frontend
upstream_host() {
  local host="$1"
  host="${host#http://}"
  host="${host#https://}"
  host="${host%%/*}"
  case "$host" in
    \[*\]*) host="${host#\[}"; host="${host%%\]*}" ;; # [::1]:80 -> ::1
    *) host="${host%%:*}" ;;
  esac
  echo "$host"
}

# Resolves an upstream to a comma separated list of IPv4 addresses, empty if it cannot
# be resolved. Sorted because Docker's DNS returns multiple records in any order.
resolve_upstream() {
  local host ips
  host=$(upstream_host "$1")
  [ -z "$host" ] && return 0

  # A literal IP cannot drift
  if echo "$host" | grep -qE "^${IPV4_RE}$"; then
    echo "$host"
    return 0
  fi

  ips=$(dig +short "$host" 2>/dev/null | grep -Eo "^${IPV4_RE}$" | sort -u | tr '\n' ',')
  echo "${ips%,}"
}

# Shared threshold/cooldown bookkeeping. "__DOWNFOR__" is replaced with the seconds
# spent failing. $1 = state key, $2 = log message, $3 = alert title, $4 = alert message
mark_down() {
  local key="$1" logmsg="$2" title="$3" message="$4"
  local down_file="$STATE_DIR/down_${key}"
  local last_alert_file="$STATE_DIR/last_alert_${key}"
  local now down_since down_for should_alert last_alert

  now=$(date +%s)
  [ ! -f "$down_file" ] && echo "$now" > "$down_file"

  down_since=$(cat "$down_file" 2>/dev/null)
  [ -z "$down_since" ] && down_since="$now"
  down_for=$(( now - down_since ))
  [ "$down_for" -lt "$THRESHOLD" ] && return 0

  should_alert=true
  if [ -f "$last_alert_file" ]; then
    last_alert=$(cat "$last_alert_file" 2>/dev/null)
    [ -n "$last_alert" ] && [ $(( now - last_alert )) -lt "$COOLDOWN" ] && should_alert=false
  fi
  [ "$should_alert" = true ] || return 0

  log "${logmsg//__DOWNFOR__/$down_for}"
  send_alert "$title" "${message//__DOWNFOR__/$down_for}" "EA4300"
  echo "$now" > "$last_alert_file"
}

# Clears the down state and reports recovery, but only if we alerted before
mark_up() {
  local key="$1" logmsg="$2" title="$3" message="$4"
  local down_file="$STATE_DIR/down_${key}"
  local last_alert_file="$STATE_DIR/last_alert_${key}"

  [ -f "$down_file" ] || return 0
  if [ -f "$last_alert_file" ]; then
    log "$logmsg"
    send_alert "$title" "$message" "00B050"
  fi
  rm -f "$down_file" "$last_alert_file"
}

# Reloads Nginx when an upstream resolves to a different IP than on the last pass
check_dns_drift() {
  local upstream="$1" domains="$2" key ipfile pending_file current previous
  key=$(sanitize "$upstream")
  ipfile="$STATE_DIR/ip_${key}"
  pending_file="$STATE_DIR/reload_pending_${key}"

  current=$(resolve_upstream "$upstream")

  # Unresolvable right now - let check_upstream report it
  [ -z "$current" ] && return 0

  previous=$(cat "$ipfile" 2>/dev/null)
  echo "$current" > "$ipfile"

  # Nginx resolved every upstream at startup, so only re-baseline on our first pass.
  # A pending marker is kept: the cron watchdog can restart us while Nginx keeps running.
  [ "$FIRST_ITERATION" = true ] && return 0

  if [ -n "$previous" ] && [ "$current" != "$previous" ]; then
    log "[upstream-monitor] DNS CHANGE: $upstream (serving: $domains) $previous -> $current"
    send_alert "Upstream IP changed" \
      "Upstream $upstream serving $domains on host $HOST_IP changed IP from $previous to $current, reloading Nginx to re-resolve it." \
      "FFC000"

    if [ "$RELOAD_ON_DNS_CHANGE" != true ]; then
      log "[upstream-monitor] reload disabled - $upstream stays pinned to $previous"
      return 0
    fi

    # The new IPs are already stored, so a skipped reload needs this marker to be retried
    touch "$pending_file"
  fi

  [ "$RELOAD_ON_DNS_CHANGE" = true ] || return 0
  [ -f "$pending_file" ] || return 0

  # Never reload a config that does not parse, keep the marker and retry next pass
  if ! "$NGINX_BIN" -t >/dev/null 2>&1; then
    log "[upstream-monitor] SKIPPED reload: \"$NGINX_BIN -t\" failed - $upstream stays pinned to its old IP, retrying in ${INTERVAL}s"
    return 0
  fi

  if "$NGINX_BIN" -s reload >/dev/null 2>&1; then
    rm -f "$pending_file"
    log "[upstream-monitor] Nginx reloaded (upstreams re-resolved)"
  else
    log "[upstream-monitor] FAILED to reload Nginx after DNS change of $upstream - will retry"
  fi
}

# Liveness probe. A bare backend legitimately answers 404 on "/", so only a missing
# response (000) or a 5xx counts as down.
check_upstream() {
  local upstream="$1" code
  [[ "$upstream" != http://* ]] && [[ "$upstream" != https://* ]] && upstream="http://$upstream"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --connect-timeout 5 "$upstream" 2>/dev/null)
  case "$code" in
    ''|*[!0-9]*) code="000" ;;
  esac
  LAST_HTTP_CODE="$code"
  case "$code" in
    000|5??) return 1 ;;
  esac
  return 0
}

# Probes a domain through THIS Nginx instance: --resolve keeps SNI/Host intact while
# bypassing public DNS, -k allows the self-signed fallback certs.
probe_domain() {
  local domain="$1" path="$2" code
  code=$(curl -sk -o /dev/null -w '%{http_code}' \
    --resolve "${domain}:443:127.0.0.1" \
    --max-time 10 --connect-timeout 5 \
    "https://${domain}${path}" 2>/dev/null)
  case "$code" in
    ''|*[!0-9]*) code="000" ;;
  esac
  echo "$code"
}

# Catches what check_dns_drift cannot: container alive but app, cert or config broken
check_domain() {
  local domain="$1" path="$2" upstream="$3"
  local target key base_file code baseline
  target="https://${domain}${path}"
  key="probe_$(sanitize "${domain}${path}")"
  base_file="$STATE_DIR/probe_base_$(sanitize "${domain}${path}")"

  code=$(probe_domain "$domain" "$path")

  case "$code" in
    000|5??)
      mark_down "$key" \
        "[upstream-monitor] DOMAIN UNREACHABLE: $target -> $upstream returned HTTP $code - failing for __DOWNFOR__s" \
        "Domain unavailable" \
        "$target (upstream $upstream) on host $HOST_IP has been returning HTTP $code for __DOWNFOR__s."
      return 0
      ;;
    403|406)
      # NginxCrypt's own guards, not an upstream problem
      mark_down "$key" \
        "[upstream-monitor] DOMAIN REJECTED BY PROXY: $target returned HTTP $code - misconfigured NXCT_SERVICE_HOST_*, NOT an outage of $upstream - for __DOWNFOR__s" \
        "Domain rejected by proxy" \
        "$target on host $HOST_IP returned HTTP $code, which is NginxCrypt's own restriction (403 = undefined domain, 406 = Host/server_name mismatch). Check NXCT_SERVICE_HOST_*, the upstream $upstream is not necessarily down. Ongoing for __DOWNFOR__s."
      return 0
      ;;
    404)
      # Ambiguous - many apps always 404 here, so only alert when it changed
      baseline=$(cat "$base_file" 2>/dev/null)
      if [ -z "$baseline" ]; then
        echo "$code" > "$base_file"
      elif [ "$baseline" != "404" ]; then
        mark_down "$key" \
          "[upstream-monitor] DOMAIN STATUS CHANGED: $target -> $upstream now returns HTTP 404 but used to return HTTP $baseline - for __DOWNFOR__s" \
          "Domain returns 404" \
          "$target (upstream $upstream) on host $HOST_IP now returns HTTP 404 but used to return HTTP $baseline. Ongoing for __DOWNFOR__s."
        return 0
      fi
      ;;
    *)
      echo "$code" > "$base_file"
      ;;
  esac

  mark_up "$key" \
    "[upstream-monitor] DOMAIN RECOVERED: $target -> $upstream is reachable again (HTTP $code)" \
    "Domain recovered" \
    "$target (upstream $upstream) on host $HOST_IP is reachable again (HTTP $code)."
}

while true; do
  upstream_map=$(get_upstream_map)

  while IFS='|' read -r upstream domains; do
    [ -z "$upstream" ] && continue

    # Drift first, so a stale IP is healed before we judge the upstream
    check_dns_drift "$upstream" "$domains"

    key=$(sanitize "$upstream")

    if check_upstream "$upstream"; then
      mark_up "$key" \
        "[upstream-monitor] RECOVERED: $upstream (serving: $domains)" \
        "Upstream recovered" \
        "Upstream $upstream serving $domains on host $HOST_IP is back online."
    else
      mark_down "$key" \
        "[upstream-monitor] UNREACHABLE: $upstream (serving: $domains) returned HTTP $LAST_HTTP_CODE - down for __DOWNFOR__s" \
        "Upstream unavailable" \
        "Upstream $upstream serving $domains on host $HOST_IP has been unreachable for __DOWNFOR__s (last HTTP status: $LAST_HTTP_CODE)."
    fi
  done <<< "$upstream_map"

  if [ "$PROBE_DOMAINS" = true ]; then
    domain_map=$(get_domain_map)

    while IFS='|' read -r domain path upstream; do
      [ -z "$domain" ] && continue
      check_domain "$domain" "$path" "$upstream"
    done <<< "$domain_map"
  fi

  FIRST_ITERATION=false

  sleep "$INTERVAL"
done
