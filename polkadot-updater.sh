#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# CONFIG_LOAD
# --------------------------------------------------------------------------- #
# If /etc/polkadot-updater.conf exists, source it so the administrator can
# override defaults such as INSTALL_DIR, SERVICE_LIST, AM_URLS_RAW, etc.
# Any variable that is **unset** after sourcing will fall back to the script’s
# built-in defaults later in the file.
###############################################################################
CONFIG_FILE="/etc/polkadot-updater.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/etc/polkadot-updater.conf
  source "$CONFIG_FILE"
fi


###############################################################################
# SERVER_SCOPE
# --------------------------------------------------------------------------- #
# The default Alertmanager scope key used for server-level alerts.
#
# • This variable defines which key in AM_URLS is used for general
# or server-wide alerts.
# • Can be overridden in the config file if a different scope name is needed.
# • Default: "server"
###############################################################################
SERVER_SCOPE=${DEFAULT_ALERT_SCOPE:-"server"}


###############################################################################
# ALERTMANAGER_URLS
# --------------------------------------------------------------------------- #
# Build an associative array called AM_URLS that maps *scope keys* (server,
# polkadot1, etc.) to one or more Alertmanager endpoints.  Admins can override
# the mapping in CONFIG_FILE via:
#
#   AM_URLS_RAW="
#     server=http://am01:9090/api/v2/alerts;http://am02:9090/api/v2/alerts
#     kusama1=http://am-kusama:9090/api/v2/alerts
#   "
#
# Each line:  key=URL[;URL2;URL3]        # semi-colon separates multiple URLs
###############################################################################
declare -A AM_URLS

if [[ -z "${AM_URLS_RAW:-}" ]]; then
  echo "$(date +%T) ❌ AM_URLS_RAW is not set in $CONFIG_FILE"
  echo "    Define at least one mapping, e.g.:"
  echo '    AM_URLS_RAW="server=http://127.0.0.1:9090/api/v2/alerts"'

  error_alert  "$SERVER_SCOPE"  "unknown"  warning \
    "polkadot-updater mis-configuration" \
    "AM_URLS_RAW is missing in $CONFIG_FILE"

exit 1
fi

# Convert the raw text into the associative array.
while IFS='=' read -r key val; do
  key=$(echo "$key" | xargs)   # trim whitespace
  val=$(echo "$val" | xargs)
  [[ -z $key || -z $val ]] && continue
  AM_URLS["$key"]=$val
done <<< "$AM_URLS_RAW"

# Extra sanity: make sure at least one entry survived parsing
if ((${#AM_URLS[@]} == 0)); then
  echo "$(date +%T) ❌ AM_URLS_RAW contained no valid key=url pairs"

  error_alert  "$SERVER_SCOPE"  "unknown"  warning \
    "polkadot-updater mis-configuration" \
    "AM_URLS_RAW had no usable entries after parsing"

  exit 1
fi


###############################################################################
# ALERT_SWITCH
# --------------------------------------------------------------------------- #
# Decide whether the script should actually POST alerts to Alertmanager.
#
#   • ENABLE_ALERTS can be set in CONFIG_FILE.
#   • Accepted truth-y values (case-insensitive):  yes | true | 1
#   • Anything else (or unset) disables alerting.  The script will keep
#     running; _post_alert_payload simply prints a log line and returns 0.
###############################################################################
ENABLE_ALERTS=${ENABLE_ALERTS:-false}

case "${ENABLE_ALERTS,,}" in
  yes|true|1) ENABLE_ALERTS=true  ;;
  *)          ENABLE_ALERTS=false ;;
esac

###############################################################################
# POST_HELPER
# --------------------------------------------------------------------------- #
# _post_alert_payload <scope> <json>
#
# • Looks up the semicolon-separated URL list for the given <scope>.
# • Skips the whole operation if ENABLE_ALERTS=false.
# • Gracefully ignores missing / malformed URLs instead of aborting.
###############################################################################
_post_alert_payload() {
  local target="$1"; shift
  local payload="$1"; shift

  if [[ $ENABLE_ALERTS != true ]]; then
    echo "$(date +%T) ℹ️ Alert skipped (ENABLE_ALERTS=false): $target"
    return 0
  fi

  # look-up URL list
  local urlstr="${AM_URLS[$target]}"
  if [[ -z "$urlstr" ]]; then
    echo "$(date +%T) ⚠️ No Alertmanager URL configured for target '$target'"
    return 0
  fi

  IFS=';' read -ra URL_LIST <<< "$urlstr"

  local url code
  for url in "${URL_LIST[@]}"; do
    url="${url//[[:space:]]/}"   # trim
    [[ -z $url ]] && continue
    [[ ! $url =~ ^https?:// ]] && {
      echo "$(date +%T) ⚠️ Skipping malformed Alertmanager URL: $url"
      continue
    }

    code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$url" \
            -H 'Content-Type: application/json' --data-raw "$payload" \
            --connect-timeout 5 --max-time 10 --retry 3 --retry-all-errors)

    [[ $code == 200 ]] || \
      echo "$(date +%T) ⚠️ Alert POST to $url returned HTTP $code"
  done
}


###############################################################################
# ALERT_BUILDERS
# --------------------------------------------------------------------------- #
# Low-level:  _emit_update_alert
#   _emit_update_alert <scope> <version> <severity> <outcome> \
#                      <summary> <description> <resolved?>
#
#   • <scope>     : “server”, “polkadot1”, … (must exist in AM_URLS)
#   • <version>   : tag without the “polkadot-” prefix (e.g. stable2507)
#   • <severity>  : info | warning | critical
#   • <outcome>   : detected | success | error
#   • <resolved?> : “true”  → add endsAt to resolve immediately
#                   “false” → leave alert firing
#
#   Higher-level wrappers below call this with the right outcome/resolved flag.
###############################################################################
_emit_update_alert() {
  local target="$1"       # server | polkadot1 | kusama1
  local version="$2"      # e.g. stable2506
  local severity="$3"     # info | warning | critical  (must match between open/resolve)
  local outcome="$4"      # detected | success | error
  local summary="$5"
  local description="$6"
  local resolved="$7"     # "true" => add endsAt (resolve immediately)

  local now;  now=$(date -Iseconds)
  local host; host=$(hostname -s)

  local ends=""
  [[ "$resolved" == "true" ]] && ends=",\"endsAt\":\"$now\""

  local payload
  payload=$(cat <<EOF
[
  {
    "labels": {
      "alertname": "PolkadotUpdate",
      "version": "${version}",
      "instance": "${host}",
      "scope": "${target}",
      "source": "polkadot-updater",
      "severity": "${severity}"
    },
    "annotations": {
      "summary": "${summary}",
      "description": "${description}",
      "outcome": "${outcome}"
    },
    "startsAt": "${now}"${ends}
  }
]
EOF
)
  _post_alert_payload "$target" "$payload"
}

# -------- Convenience lifecycle wrappers -----------------------------------
# open / resolve helpers (severity is passed so you choose)
open_update_alert() {           # target version severity summary description
  _emit_update_alert "$1" "$2" "$3" "detected" "$4" "$5" "false"
}

resolve_update_alert() {      # target version severity summary description
  _emit_update_alert "$1" "$2" "$3" "success"  "$4" "$5" "true"
}

# one-shot error ping – does NOT resolve the Detect alert
error_alert() {                  # target version severity summary description
  _emit_update_alert "$1" "$2" "$3" "error"    "$4" "$5" "true"
}

# one-shot event (auto-resolved immediately), same schema
# shellcheck disable=SC2329
event_ping() {
  # args: target version severity outcome summary description
  _emit_update_alert "$1" "$2" "$3" "$4" "$5" "$6" "true"
}

###############################################################################
# PATH_DEFAULTS
# --------------------------------------------------------------------------- #
# Location variables *may* be overridden in CONFIG_FILE.
# The “:-” construct keeps whatever came from the .conf file, or falls back to
# a sane default when it was absent.
###############################################################################
INSTALL_DIR=${INSTALL_DIR:-/usr/local/bin} # where new binaries land
ARCHIVE_DIR=${ARCHIVE_DIR:-/opt/polkadot/archive} # where old ones are saved
TRACKING_DIR=${TRACKING_DIR:-/var/lib/polkadot-updater}
LOG_FILE=${LOG_FILE:-/var/log/polkadot-updater.log}
GPG_KEY=${GPG_KEY:-90BD75EBBB8E95CB3DA6078F94A4029AB4B35DAE}

#############
# ROLLBACK VARIABLES & FLAGS
# -----------
#
################
ARCHIVE_DONE=false
SERVICES_STOPPED=false
DO_EXIT_TRAP_SET=false
ROLLBACK_DIR=""


###############################################################################
# SERVICE_LIST
# --------------------------------------------------------------------------- #
# The updater must know which systemd units to stop/start.  This list is **not**
# optional; if it’s missing or empty we abort early with a clear error.
#
# Users specify it in CONFIG_FILE, e.g.:
#     SERVICE_LIST=(polkadot-validator@polkadot1 polkadot-validator@kusama1)
###############################################################################
if declare -p SERVICE_LIST 2>/dev/null | grep -q 'declare -a'; then
  # It’s an array; make sure it’s not empty
  if ((${#SERVICE_LIST[@]} == 0)); then
    echo "$(date +%T) ❌ SERVICE_LIST is empty in $CONFIG_FILE"

    error_alert  "$SERVER_SCOPE"  "unknown"  warning \
      "polkadot-updater mis-configuration" \
      "SERVICE_LIST array is declared but empty"

    exit 1
  fi
  SERVICES=("${SERVICE_LIST[@]}")
else
  echo "$(date +%T) ❌ SERVICE_LIST array is missing in $CONFIG_FILE"
  echo "    Add something like:"
  echo "    SERVICE_LIST=(validator@kusama polkadot-validator)"

  error_alert  "$SERVER_SCOPE"  "unknown"  warning \
    "polkadot-updater mis-configuration" \
    "SERVICE_LIST array is missing in $CONFIG_FILE"

  exit 1
fi

###############################################################################
# derive_scope
# --------------------------------------------------------------------------- #
# Convert a systemd unit name to an “alert scope” string.
#
# • If it’s a template unit (polkadot-validator@kusama1.service) return
#   the part after ‘@’ and strip any trailing “.service”.
# • Otherwise return the bare unit name with “.service” dropped.
#
# Examples
#   polkadot-validator@kusama1.service   ->  kusama1
#   kusama-validator.service             ->  kusama-validator
#   my-custom-unit                       ->  my-custom-unit
###############################################################################
derive_scope() {
  local unit="$1"
  local base=${unit##*@}           # strip everything including '@' if present
  [[ "$base" == "$unit" ]] && base=${unit##*/}      # no @ → use full name
  base=${base%.service}            # drop .service suffix if present
  echo "$base"
}

###############################################################################
# SERVICE HELPERS
# --------------------------------------------------------------------------- #
#  stop_services        – Stops every unit in ${SERVICES[@]}  (no hard-fail)
#  start_services       – Starts each unit, health-checks, and aborts script
#                         with error_alert on the first failure.
###############################################################################

stop_services() {
  for svc in "${SERVICES[@]}"; do
    echo "$(date +%T) ⏹️  Stopping $svc …"
    if systemctl is-active --quiet "$svc"; then
      systemctl stop "$svc"
      echo "$(date +%T) ✅ $svc stopped."
    else
      echo "$(date +%T) ℹ️  $svc already inactive."
    fi
  done
}

start_services() {
  local tag="$1"          # tag for alerting context (e.g. $STRIPPED_TAG)
  for svc in "${SERVICES[@]}"; do
    echo "$(date +%T) ▶️  Starting $svc …"
    systemctl start "$svc"

    echo "$(date +%T) 🔍 Checking status for $svc …"
    if systemctl is-active --quiet "$svc"; then
      echo "$(date +%T) ✅ $svc is running."
    else
      echo "$(date +%T) ❌ $svc failed to start. Recent logs:"
      journalctl -u "$svc" --since -5m | tail -n 20
      local scope
      scope=$(derive_scope "$svc")
      error_alert "$scope" "$tag" critical \
        "Polkadot update failed" "$svc failed to start after update."
      exit 1
    fi
  done
}



###############################################################################
# restore_context_if_needed
# --------------------------------------------------------------------------- #
# Updates the SELinux context of the installed binary if needed.
#
# • Uses the restorecon command if available in PATH.
# • Otherwise, tries common locations (/sbin, /usr/sbin).
# • If not found, just logs that the context fix was skipped.
#
# Parameters:
#   $1 – binary name (e.g., polkadot)
###############################################################################
restore_context_if_needed() {
  local bin="$1"
	if command -v restorecon &>/dev/null; then
	  restorecon "$INSTALL_DIR/$bin"
	# Fallback: explicit common locations
	elif [[ -x /sbin/restorecon ]]; then
	  /sbin/restorecon "$INSTALL_DIR/$bin"
	elif [[ -x /usr/sbin/restorecon ]]; then
	  /usr/sbin/restorecon "$INSTALL_DIR/$bin"
	else
	  echo "$(date +%T) ℹ️  SELinux restorecon not available; skipping context fix"
	fi
}


###############################################################################
# rollback
# --------------------------------------------------------------------------- #
# Performs rollback of binaries if an error occurs during the update.
#
# • Stops the services (validators) before restoring.
# • Restores binaries from the backup directory, if available.
# • Restarts the services after rollback.
# • Emits an error alert informing that the rollback was performed.
#
# Does nothing if no backup is available.
# shellcheck disable=SC2329
###############################################################################
rollback() {
  echo "$(date +%T) ⏹️ Stopping validators before rollback"
	stop_services

  echo "$(date +%T) 🔄 Rolling back due to error"
  if [[ $ARCHIVE_DONE == true && -d $ROLLBACK_DIR ]]; then
    echo "$(date +%T) ↩️  Restoring binaries from $ROLLBACK_DIR"
    for bin in "${BINARIES[@]}"; do
      if [[ -e "$ROLLBACK_DIR/$bin" ]]; then
        install -m 755 "$ROLLBACK_DIR/$bin" "$INSTALL_DIR/$bin"
        restore_context_if_needed "$bin"
        echo "$(date +%T) ✅ Restored $bin"
      fi
    done
  else
    echo "$(date +%T) ℹ️  No archive created yet – nothing to roll back."
  fi

  echo "$(date +%T) ▶️ Restarting validators after rollback"
  start_services "$LAST_TAG"

  # Alert the humans (only if alerting is enabled)
  error_alert "$SERVER_SCOPE" "$LAST_TAG" critical \
    "Rollback performed" \
    "Reverted to $LAST_TAG after update failure."
}


###############################################################################
# LOGGING_SETUP
# --------------------------------------------------------------------------- #
# • Ensures the parent directory for LOG_FILE exists.
# • Appends all subsequent stdout/stderr to the log.
# • Prints a banner with an ISO-timestamp to delimit runs.
###############################################################################
LOG_DIR=$(dirname "$LOG_FILE")
mkdir -p "$LOG_DIR"
exec >>"$LOG_FILE" 2>&1
echo -e "
===== Run at $(date -Is) ====="


###############################################################################
# TRACKING_FILE
# --------------------------------------------------------------------------- #
# • JSON persisted across runs:  tag / version / updated_at / published_at
# • Created on first run, then read on every subsequent invocation.
# • Must live inside $TRACKING_DIR (configurable).
###############################################################################
# Ensure directory exists
mkdir -p "$TRACKING_DIR"
TRACKING_FILE="$TRACKING_DIR/last-update.json"

# Initialize tracking file if not present
if [ ! -f "$TRACKING_FILE" ]; then
  echo "$(date +%T) ⚠️ Tracking file not found. Detecting installed version..."

  if command -v polkadot &>/dev/null; then
    CURRENT_VERSION=$(polkadot --version | awk '{print $2}' | cut -d'-' -f1)
    CURRENT_TAG="installed-manually"
    echo "$(date +%T) 📌 Detected installed version: $CURRENT_VERSION"
  else
    CURRENT_VERSION=""
    CURRENT_TAG=""
    echo "$(date +%T) ❌ No polkadot binary found. Starting from blank."
  fi

  echo "{
  \"tag\": \"$CURRENT_TAG\",
  \"version\": \"$CURRENT_VERSION\",
  \"updated_at\": \"$(date -Iseconds)\",
  \"published_at\": \"\"
}" > "$TRACKING_FILE"
fi

# Load last known version info
LAST_TAG=$(jq -r .tag "$TRACKING_FILE")

###############################################################################
# RELEASE_CHECK
# --------------------------------------------------------------------------- #
# • Fetch “latest” release JSON from GitHub.
# • Verify it matches the desired channel (default: tags that start with
#   “stable”, or an override via CHANNEL_REGEX).
# • Compare against our last installed tag with tag_is_newer; abort if older.
# • Emit a “detected” alert (if alerting is enabled).
###############################################################################
GITHUB_API="https://api.github.com/repos/paritytech/polkadot-sdk/releases/latest"
LATEST_JSON=$(curl -s "$GITHUB_API")

LATEST_TAG=$(echo "$LATEST_JSON" | jq -r .tag_name)
LATEST_PUBLISHED=$(echo "$LATEST_JSON" | jq -r .published_at)

# Skip if the tag is not a stable release
STRIPPED_TAG=${LATEST_TAG#polkadot-}
if [[ "$STRIPPED_TAG" != stable* ]]; then
  echo "$(date +%T) ✅ Latest release ($LATEST_TAG) is not a stable release. Skipping update."
  exit 0
fi

# Is it newer than what we have?
if [[ "$STRIPPED_TAG" == "$LAST_TAG" ]]; then
  echo "$(date +%T) ✅ Already up to date (latest: $LAST_TAG). No update needed."
  exit 0
fi

echo "$(date +%T) ⚠️ New stable version available: $LATEST_TAG (published at $LATEST_PUBLISHED)"
open_update_alert "$SERVER_SCOPE" "$STRIPPED_TAG" info "New Polkadot version available" "Found $LATEST_TAG (published $LATEST_PUBLISHED). Last known: $LAST_TAG."

###############################################################################
# DOWNLOAD_INSTALL
# --------------------------------------------------------------------------- #
# 1) Build the list of binaries to fetch
# 2) Fetch each binary + .asc signature into /tmp
# 3) GPG-verify every download
# 4) Stop validators
# 5) Archive old binaries
# 6) Install new ones
###############################################################################

# ---------- 1.  Binary list --------------------------------------------------
BINARIES=(
  "polkadot"
  "polkadot-execute-worker"
  "polkadot-prepare-worker"
)

# ---------- 2.  Download -----------------------------------------------------
TMP_DIR="/tmp/polkadot-update-$STRIPPED_TAG"
echo "$(date +%T) 📁 Creating temporary directory at $TMP_DIR"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

BASE_URL="https://github.com/paritytech/polkadot-sdk/releases/download/$LATEST_TAG"

for BIN in "${BINARIES[@]}"; do
  echo "$(date +%T) ⬇️ Downloading $BIN and $BIN.asc..."
  curl -fsSL "$BASE_URL/$BIN" -o "$TMP_DIR/$BIN"
  curl -fsSL "$BASE_URL/$BIN.asc" -o "$TMP_DIR/$BIN.asc"
  chmod +x "$TMP_DIR/$BIN"
done

# ---------- 3.  Verify -------------------------------------------------------

echo "$(date +%T) 🔑 Importing Parity GPG key if not already present..."

if [[ -n "$GPG_KEY" ]]; then
  gpg --list-keys "$GPG_KEY" &>/dev/null || \
    gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "$GPG_KEY"
fi

for bin in "${BINARIES[@]}"; do
  echo "$(date +%T) 🔑 Verifying signature for $bin..."
  if gpg --verify "$TMP_DIR/$bin.asc" "$TMP_DIR/$bin" 2>&1 | grep -q "Good signature"; then
    echo "$(date +%T) ✅ Signature valid for $bin"
  else
    echo "$(date +%T) ❌ Invalid GPG signature for $bin. Aborting."
    error_alert "$SERVER_SCOPE" "$STRIPPED_TAG" critical "Polkadot update failed" "Invalid GPG signature for $bin."
    exit 1
  fi
  echo

done

# ---------- 4.  Stop validators ----------------------------------------------
stop_services
SERVICES_STOPPED=true

# Set trap after stopping services
if [[ $DO_EXIT_TRAP_SET == false ]]; then
  # shellcheck disable=SC2154    # st is assigned inside the trap, false positive
  trap 'st=$?; [[ $st -ne 0 && $SERVICES_STOPPED == true ]] && rollback' EXIT
  DO_EXIT_TRAP_SET=true
fi

# ---------- 5.  Archive old binaries -----------------------------------------
TODAY=$(date +%Y%m%d)
ARCHIVE_DATED_DIR="$ARCHIVE_DIR/${TODAY}_$STRIPPED_TAG"

mkdir -p "$ARCHIVE_DATED_DIR"
echo "$(date +%T) 📦 Archiving current binaries to $ARCHIVE_DATED_DIR..."

for bin in "${BINARIES[@]}"; do
  if [ -x "$INSTALL_DIR/$bin" ]; then
    install -b "$INSTALL_DIR/$bin" "$ARCHIVE_DATED_DIR/$bin"
    echo "$(date +%T) ✅ Archived $bin"
  else
    echo "$(date +%T) ⚠️ Skipping $bin — not found or not executable."
  fi
done

ARCHIVE_DONE=true
ROLLBACK_DIR="$ARCHIVE_DATED_DIR"

# ---------- 6.  Install latest binaries --------------------------------------
echo "$(date +%T) 💾 Installing new binaries to $INSTALL_DIR..."

for bin in "${BINARIES[@]}"; do
  echo "$(date +%T) 📥 Installing $bin..."
  install -m 755 "$TMP_DIR/$bin" "$INSTALL_DIR/$bin"
	restore_context_if_needed "$bin"
  echo "$(date +%T) ✅ $bin installed."
done

###############################################################################
# RESTART & WRAP-UP
# --------------------------------------------------------------------------- #
# • Start validators and verify they stay healthy.
# • Resolve the “detected” alert (success) or emit error alerts on failure.
# • Update tracking JSON, prune old archives, exit 0.
###############################################################################

# ---------- 1.  Start services and ensure they are active --------------------
start_services "$STRIPPED_TAG"

# ---------- 2.  Early-log sanity check ---------------------------------------
echo "$(date +%T) ⏳ Waiting 30s to collect early logs..."
sleep 30
echo "$(date +%T) 🔍 Checking early logs for critical errors..."
for svc in "${SERVICES[@]}"; do
  recent_logs=$(journalctl -u "$svc" --since -1m)
  if echo "$recent_logs" | grep -qE "panic|segfault|bind: address already in use"; then
    echo "$(date +%T) ❌ Critical error detected in $svc logs:"
    echo "$recent_logs" | grep -E "panic|segfault|bind: address already in use"
    scope=$(derive_scope "$svc")
    error_alert "$scope" "$STRIPPED_TAG" critical "Polkadot update failed" "Critical logs detected for $svc (panic/segfault/bind)."
    exit 1
  fi
done

# ---------- 3.  Check for Telemetry ❌ markers -------------------------------
echo "$(date +%T) ⏳ Waiting another 30s to verify telemetry logs..."
sleep 30
echo "$(date +%T) 📡 Checking for telemetry logs..."

# Check logs for each service
for svc in "${SERVICES[@]}"; do
  echo "$(date +%T) 🧠 Analyzing recent logs for $svc..."
  RECENT_LOGS=$(journalctl -u "$svc" --since -1m)

  if echo "$RECENT_LOGS" | grep -q "❌"; then
    echo "$(date +%T) ⚠️ Detected error markers in logs for $svc:"
    echo "$RECENT_LOGS" | grep "❌"

    echo "$(date +%T) 🔁 Attempting one restart of $svc to resolve possible telemetry error..."
    systemctl restart "$svc"
    sleep 60

    echo "$(date +%T) 🔄 Re-checking logs after restart..."
    RETRY_LOGS=$(journalctl -u "$svc" --since -1m)

    if echo "$RETRY_LOGS" | grep -q "❌"; then
      echo "$(date +%T) ❌ Still seeing error markers after restart:"
      echo "$RETRY_LOGS" | grep "❌"
      scope=$(derive_scope "$svc")
      error_alert "$scope" "$STRIPPED_TAG" critical "Polkadot update failed" "Telemetry error markers persist for $svc after restart."
      exit 1
    else
      echo "$(date +%T) ✅ Restart appears to have resolved the issue."
    fi
  fi
done

# ---------- 4.  Update tracking file -----------------------------------------
NEW_VERSION=$("$TMP_DIR/polkadot" --version | awk '{print $2}' | cut -d'-' -f1)
UPDATED_AT=$(date -Iseconds)

cat > "$TRACKING_FILE" <<EOF
{
  "tag": "$STRIPPED_TAG",
  "version": "$NEW_VERSION",
  "updated_at": "$UPDATED_AT",
  "published_at": "$LATEST_PUBLISHED"
}
EOF

# ---------- 5.  Resolve alert ------------------------------------------------
echo "$(date +%T) ✅ Tracking file updated with version $NEW_VERSION ($STRIPPED_TAG)"
resolve_update_alert "$SERVER_SCOPE" "$STRIPPED_TAG" info "Polkadot update completed" "Updated to $NEW_VERSION ($STRIPPED_TAG) successfully."

# ---------- 6.  Prune old archives (keep newest +1) --------------------------
echo "$(date +%T) 🧹 Cleaning up old archives (keeping latest + one previous)..."
cd "$ARCHIVE_DIR"

mapfile -t ARCHIVES < <(
  find "$ARCHIVE_DIR" -maxdepth 1 -type d -name '*_stable*' -printf '%P\n' \
    | sort
)

if [ "${#ARCHIVES[@]}" -le 2 ]; then
  echo "$(date +%T) ℹ️ Nothing to clean. Only ${#ARCHIVES[@]} archive(s) found."
else
  for old in "${ARCHIVES[@]:0:${#ARCHIVES[@]}-2}"; do
    echo "$(date +%T) 🗑️ Removing old archive: $old"
    rm -rf -- "${ARCHIVE_DIR:?}/$old"   # see next item
  done
fi

exit 0
