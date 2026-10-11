#!/usr/bin/env bash
# Fastweb Power Control -> Home Assistant realtime power sensor.
#
# Prints ONE bare integer (watts) to stdout on success.
# Everything else goes to stderr. Non-zero exit = sensor unavailable.
#
# Session strategy: cookies persist in FW_JAR between runs, so normal polls
# perform no login at all. Re-login only happens when the session is dead.
set -uo pipefail

UA="Mozilla/5.0 (X11; Linux x86_64; rv:157.0) Gecko/20100101 Firefox/157.0"
BASE="https://fastweb.it/myfastweb"
LOGIN_PAGE="$BASE/accesso/login/"
LOGIN_AJAX="$BASE/accesso/login/ajax/"
CONSUMI_PAGE="$BASE/abbonamento/consumi-power-control/"
CONSUMI_AJAX="$BASE/abbonamento/consumi-power-control/ajax/"

# --- config --------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW_ENV="${FW_ENV:-$SCRIPT_DIR/.env}"
FW_JAR="${FW_JAR:-$SCRIPT_DIR/fastweb_jar.txt}"

log() { printf '%s\n' "$*" >&2; }
die() { log "fastweb_power: $*"; exit 1; }

# json_get <json> <python-expression over `d`>
# Prints the value, or nothing if absent/unparseable. Uses python3, which is
# guaranteed present in the Home Assistant container (unlike jq).
json_get() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
try:
    v = eval(sys.argv[1], {"d": d})
except Exception:
    sys.exit(0)
if v is None or v == "":
    sys.exit(0)
print(v)
' "$2" 2>/dev/null
}

# Strict KEY=VALUE reader: avoids `source`, so values containing spaces,
# quotes, '#' or ';' are handled safely.
load_env() {
  [ -r "$FW_ENV" ] || die "cannot read credentials file: $FW_ENV"
  FW_USER=""; FW_PASS=""
  while IFS='=' read -r k v || [ -n "${k:-}" ]; do
    k="${k%$'\r'}"; v="${v%$'\r'}"
    case "$k" in
      FW_USER|FW_PASS) printf -v "$k" '%s' "${v:-}";;
    esac
  done < "$FW_ENV"
  [ -n "$FW_USER" ] || die "FW_USER missing from $FW_ENV"
  [ -n "$FW_PASS" ] || die "FW_PASS missing from $FW_ENV"
}

extract_token() { # $1 = HTML
  printf '%s' "$1" \
    | grep -oE 'securityToken[[:space:]]*=[[:space:]]*["'"'"'][a-f0-9]{64}["'"'"']' \
    | grep -oE '[a-f0-9]{64}' | head -n1
}

# Login + the profile hop that actually establishes the session.
# Returns 0 on success.
do_login() {
  local jar html token resp code
  jar=$(mktemp) || return 1

  html=$(curl -sS --max-time 30 -c "$jar" -b "$jar" -A "$UA" \
    -H "Accept: text/html,application/xhtml+xml" "$LOGIN_PAGE") || { rm -f "$jar"; return 1; }

  token=$(extract_token "$html")
  [ -n "$token" ] || { log "login: securityToken not found in page"; rm -f "$jar"; return 1; }

  resp=$(curl -sS --max-time 30 -c "$jar" -b "$jar" -A "$UA" "$LOGIN_AJAX" \
    -H "Accept: application/json, text/javascript, */*; q=0.01" \
    -H "X-Requested-With: XMLHttpRequest" \
    -H "Referer: $LOGIN_PAGE" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    --data-urlencode "securityToken=$token" \
    --data-urlencode "request_id=" \
    --data-urlencode "PersistentLogin=true" \
    --data-urlencode "OAM_REQ=" \
    --data-urlencode "accountLinking=" \
    --data-urlencode "redirect_uri=" \
    --data-urlencode "state=" \
    --data-urlencode "username=$FW_USER" \
    --data-urlencode "password=$FW_PASS" \
    --data-urlencode "g-recaptcha-response=" \
    --data-urlencode "g-recaptcha-response=" \
    --data-urlencode "g-recaptcha-response-unified=") || { rm -f "$jar"; return 1; }

  code=$(json_get "$resp" 'd.get("errorCode")')
  if [ "$code" != "0" ]; then
    log "login failed: errorCode=${code:-null} $(json_get "$resp" 'd.get("errorMessage")')"
    rm -f "$jar"; return 1
  fi

  # Critical: without this hop the AJAX endpoint answers "Account non valido".
  if ! curl -sS -L --max-time 30 -c "$jar" -b "$jar" -A "$UA" -o /dev/null \
       "$BASE/accesso/profile/?DirectLink=%2Fmyfastweb%2Fabbonamento%2Fconsumi-power-control%2F"; then
    log "login: profile hop failed"; rm -f "$jar"; return 1
  fi

  chmod 600 "$jar" 2>/dev/null
  mv -f "$jar" "$FW_JAR"
  return 0
}

# Fetch realtime watts. Echoes the bare value; 0 = ok, 2 = session dead.
fetch_power() {
  local jar html token resp code watts
  # No persisted session yet: caller must log in first. Without this the
  # consumption page redirects to the login screen, which also contains a
  # securityToken, so the check below would wrongly look "alive".
  [ -s "$FW_JAR" ] || { log "no saved session"; return 2; }

  jar=$(mktemp) || return 1
  cat "$FW_JAR" > "$jar"

  html=$(curl -sS -L --max-time 30 -c "$jar" -b "$jar" -A "$UA" "$CONSUMI_PAGE") || { rm -f "$jar"; return 1; }

  # No token on the page means we were bounced to the login screen.
  if ! grep -q 'securityToken' <<<"$html"; then
    log "session expired or not established"
    rm -f "$jar"; return 2
  fi

  # Page loaded but no token: also a dead session (bounced to reserved/login).
  token=$(extract_token "$html")
  [ -n "$token" ] || { log "no securityToken on consumption page"; rm -f "$jar"; return 2; }

  resp=$(curl -sS --max-time 30 -c "$jar" -b "$jar" -A "$UA" \
    -H "X-Requested-With: XMLHttpRequest" \
    -H "Referer: $CONSUMI_PAGE" \
    -F "securityToken=$token" \
    -F "action=consumptionRealtime" \
    "$CONSUMI_AJAX") || { rm -f "$jar"; return 1; }

  code=$(json_get "$resp" 'd.get("errorCode")')
  case "$code" in
    0) : ;;
    -3|-4) rm -f "$jar"; return 2 ;;   # bad account / bad token -> re-login
    *) log "unexpected errorCode=${code:-null}"; rm -f "$jar"; return 1 ;;
  esac

  watts=$(json_get "$resp" 'd.get("data", {}).get("realtime")')
  [ -n "$watts" ] || { log "no .data.realtime in response"; rm -f "$jar"; return 1; }

  # Persist refreshed cookies for next run, then emit the bare value.
  chmod 600 "$jar" 2>/dev/null
  mv -f "$jar" "$FW_JAR"
  printf '%s\n' "$watts"
  return 0
}

main() {
  command -v curl >/dev/null || die "curl not found"
  command -v python3 >/dev/null || die "python3 not found"
  load_env

  local out rc attempt
  for attempt in 1 2; do
    if out=$(fetch_power); then
      printf '%s\n' "$out"
      return 0
    else
      rc=$?
      if [ "$rc" -eq 2 ] && [ "$attempt" -eq 1 ]; then
        log "session unusable, re-logging in and retrying"
        do_login || die "login failed"
        continue
      fi
      die "could not obtain reading (rc=$rc)"
    fi
  done
  die "exhausted retries"
}

main "$@"
