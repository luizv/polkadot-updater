#!/usr/bin/env bash
#
# install.sh – idempotent installer / upgrader for polkadot-updater
# -----------------------------------------------------------------
# • Requires /etc/polkadot-updater.conf to exist *and* define every
#   mandatory variable – no internal fall-backs are accepted.
# • Copies the updater script, service unit and timer unit.
# • Creates runtime directories & log file.
# • Enables + starts the timer.
#
# Run:   sudo ./install.sh
#
set -euo pipefail

CONF_FILE=/etc/polkadot-updater.conf
REPO_RAW_URL="https://raw.githubusercontent.com/luizv/polkadot-updater/main"

required_vars=( INSTALL_DIR LOG_FILE TRACKING_DIR ARCHIVE_DIR SERVICE_LIST GPG_KEY )

die() { echo "❌ $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this script as root (with sudo)."

[[ -f $CONF_FILE ]] || die "$CONF_FILE not found. Run set-conf.sh first."

# shellcheck source=/etc/polkadot-updater.conf
source "$CONF_FILE"

# ----- sanity check: every required var must be non-empty ------------------
missing=()
for v in "${required_vars[@]}"; do
  [[ -z "${!v:-}" ]] && missing+=("$v")
done
((${#missing[@]}==0)) \
  || die "These variables are missing or empty in $CONF_FILE: ${missing[*]}"

# ----- helper to fetch raw files from GitHub --------------------------------
fetch_raw() {
  local path="$1" dst="$2"
  curl -fsSL "${REPO_RAW_URL}/${path}" -o "$dst"
}

echo "==> Installing polkadot-updater.sh to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
if [[ -f ./polkadot-updater.sh ]]; then
  cp ./polkadot-updater.sh "$INSTALL_DIR/"
else
  fetch_raw "polkadot-updater.sh" "$INSTALL_DIR/polkadot-updater.sh"
fi
chmod +x "$INSTALL_DIR/polkadot-updater.sh"

echo "==> Creating runtime directories"
mkdir -p "$TRACKING_DIR" "$ARCHIVE_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

SYSTEMD_DIR=/etc/systemd/system
echo "==> Installing systemd units"
if [[ -f ./packaging/polkadot-updater.service ]]; then
  cp ./packaging/polkadot-updater.service "$SYSTEMD_DIR/"
  cp ./packaging/polkadot-updater.timer   "$SYSTEMD_DIR/"
else
  fetch_raw "packaging/polkadot-updater.service" "$SYSTEMD_DIR/polkadot-updater.service"
  fetch_raw "packaging/polkadot-updater.timer"   "$SYSTEMD_DIR/polkadot-updater.timer"
fi

echo "==> Reloading systemd, enabling timer"
systemctl daemon-reload
systemctl enable --now polkadot-updater.timer

echo
echo "✓ Installation complete."
systemctl list-timers --all | grep polkadot-updater || true
echo "First run will occur at the time shown above."
