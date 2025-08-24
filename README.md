# Polkadot Updater 🚀

A self-contained Bash utility that **safely upgrades Polkadot validators**
on bare-metal or VM hosts running systemd.

* **Atomic swap** – stops services, archives old binaries, installs the
  new release, restarts and health-checks.
* **Rollback on failure** – any error after the stop phase triggers an
  automatic restore of the archived binaries and service restart.
* **GPG signature verification** – downloads Parity’s release key and
  validates every binary.
* **Alertmanager integration** (optional) – fires “detected / success /
  error” alerts per validator scope.
* **Systemd timer-friendly** – ships as a one-shot service; runs daily (or
  any schedule you prefer) via a systemd timer.
* **No root FS clutter** – archives go to `/opt/polkadot/archive`,
  metadata lives in `/var/lib/polkadot-updater`, logs in
  `/var/log/polkadot-updater.log`.

---

## Requirements

* Linux with **systemd** (RHEL/CentOS 8+, Fedora, Debian 11+, Ubuntu 20.04+)
* `curl`, `jq`, `gpg`, `awk`, `grep` – all available from base repos
* Polkadot validator services already installed as systemd units

---

## Manual Install

### 1. Copy & edit the config
Create a `polkadot-updater.conf` on `/etc/`. Use our `polkadot-updater.conf.example` as template.
Setup `polkadot-updater.conf` setting all paths and required variables.
```bash
sudo install -m 644 polkadot-updater.conf.example /etc/polkadot-updater.conf
sudo ${EDITOR:-nano} /etc/polkadot-updater.conf
```

### 2. Create the directories
Make sure you create all the directories and files specified on `polkadot-updater.conf`.
```bash
# create runtime directories (ARCHIVE_DIR & TRACKING_DIR) with 755 perms
sudo bash -c 'source /etc/polkadot-updater.conf &&
              install -d -m 755 "$ARCHIVE_DIR" "$TRACKING_DIR"'

# create / initialise the log file defined in LOG_FILE
sudo bash -c 'source /etc/polkadot-updater.conf &&
              touch "$LOG_FILE" &&
              chmod 644 "$LOG_FILE"'
```

### 3. Install the script
Install `polkadot-updater.sh` on the designed path on `.conf`.
```bash
sudo bash -c 'source /etc/polkadot-updater.conf &&
              install -m 755 polkadot-updater.sh "$INSTALL_DIR/"'
```

### 4. Systemd Service & Timer
Copy `polkadot-updater.timer` and `polkadot-updater.service` unit files into systemd, then enable them.
```bash
sudo install -m 644 polkadot-updater.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now polkadot-updater.timer
```

#### 4.1 Verify
Couple of commands to check things out.
```bash
# confirm timer schedule
systemctl list-timers --all | grep polkadot-updater

# dry-run once right now
sudo systemctl start polkadot-updater.service
sudo journalctl -u polkadot-updater.service -n 30 --no-pager

# watch the updater’s own log
sudo cat /var/log/polkadot-updater.log
```

---

## Quick install (WIP)
1. Run `set-conf.sh` to set `.conf` file to the `/etc/` directory and edit it.
```bash
curl -fsS https://raw.githubusercontent.com/luizv/polkadot-updater/main/set-conf.sh | sudo bash
```

2. Run `install.sh` to copy the updarter script and systemd units, and enable it.
```bash
curl -fsS https://raw.githubusercontent.com/luizv/polkadot-updater/main/install.sh | sudo bash
```
