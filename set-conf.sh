#!/usr/bin/env bash
#
# set-conf.sh – place a working copy of polkadot-updater.conf, then open it
#
#  • Never overwrites an existing /etc/polkadot-updater.conf
#  • Copies the .example template from the Git repo (or remote)
#  • Opens $EDITOR so the user can fill INSTALL_DIR, SERVICE_LIST, …
set -euo pipefail
CONF=/etc/polkadot-updater.conf
TEMPLATE_URL="https://raw.githubusercontent.com/luizv/polkadot-updater/main/polkadot-updater.conf.example"

if [[ $EUID -ne 0 ]]; then
    echo "Run this script with sudo or as root."
    exit 1
fi

if [[ -f $CONF ]]; then
    echo "Config already exists at $CONF"
    read -r -p "Edit it now? [y/N] " ans
    [[ $ans =~ ^[Yy]$ ]] && ${EDITOR:-nano} "$CONF"
    exit 0
fi

echo "Fetching template → $CONF"
curl -fsSL "$TEMPLATE_URL" -o "$CONF"
chmod 644 "$CONF"
echo
echo "==== EDIT THE CONFIG NOW ===="
${EDITOR:-nano} "$CONF"

echo
echo "✓ $CONF saved."
echo "Next: run  sudo ./install.sh  to finish installation."
