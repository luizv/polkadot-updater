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

## Quick install (all defaults)

```bash
curl -fsS https://raw.githubusercontent.com/luizv/polkadot-updater/main/install.sh | sudo bash
