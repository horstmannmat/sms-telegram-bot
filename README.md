# SMS → Telegram (Gammu)

Python helper that **gammu-smsd** runs when a new SMS arrives. It reads the spool file, forwards the text to Telegram, then removes the file only after a successful send.

## Requirements

- Linux with [Gammu](https://docs.gammu.org/quick/index.html#installing-gammu) and `gammu-smsd`
- Python 3.10+
- A USB modem (or compatible radio) recognized as a serial device (prefer persistent `/dev/serial/by-id/...` symlinks over `/dev/ttyUSB*`; on Huawei sticks, `if02` is typically the PCUI/AT port while `if01` is diagnostic)

## Install (automated)

From the repository root:

```bash
chmod +x install.sh
./install.sh          # system service (requires sudo)
./install.sh --user   # user service (no sudo for install)
./install.sh --uninstall          # remove system unit + project artifacts (sudo)
./install.sh --uninstall --user   # remove user unit + project artifacts (no sudo)
```

| Mode | Install | Uninstall | Privilege |
|------|---------|-----------|-----------|
| System | `./install.sh` | `./install.sh --uninstall` | `sudo` |
| User | `./install.sh --user` | `./install.sh --uninstall --user` | no `sudo` |

System install runs the service as `gammu` / `gammu` (from sysconfig). User install runs as your login user.

Uninstall stops and removes the **sms-telegram-bot** systemd units (`gammu-smsd.service`, `gammu-smsd-watchdog.service`, `gammu-smsd-watchdog.timer`), removes `/etc/udev/rules.d/99-gammu-smsd-modem.rules` (when permitted), and deletes `.venv`, generated config/unit/rule files, and `gammu-smsd.pid`. It does **not** remove `python3`, `gammu`, or `gammu-smsd` (apt packages). **`config.pkl`**, **`sms/`**, and **`log/`** are kept.

The installer:

1. Checks Python >= 3.10 and `gammu-smsd` (system mode installs missing packages via `apt` when possible).
2. Recreates `.venv` and runs `pip install .`.
3. Generates local configs with **absolute paths** and sets `device` in `gammurc` preferring a persistent **`/dev/serial/by-id/...`** symlink (with Huawei `if02` PCUI port handling) over volatile `/dev/ttyUSB*` paths, falling back to `gammu-detect` or `/dev/ttyUSB*` / `/dev/ttyACM*`.
4. Creates `sms/inbox`, `sms/read`, `sms/outbox`, `sms/sent`, `sms/error` under the repo.
5. Prompts to create `config.pkl` at the repo root interactively (or prints the manual command).
6. Disables any conflicting opposite-mode systemd unit (system vs `--user`, preventing SysV shared-memory `Permission denied` conflicts), enables/starts `gammu-smsd.service` (with `Restart=always` / `RestartSec=10`) and `gammu-smsd-watchdog.timer`, and generates/installs `99-gammu-smsd-modem.rules` to auto-recover from USB disconnects and `DEVICEWRITEERROR[11]`.

### Templates vs generated files

| In repo (tracked) | After `install.sh` (gitignored) |
|-------------------|----------------------------------|
| `gammurc.example` | `gammurc` |
| `gammu-smsd.sysconfig.example` | `gammu-smsd.sysconfig` |
| `gammu-smsd.service.example` | `gammu-smsd.service` |
| `gammu-smsd-watchdog.service.example` | `gammu-smsd-watchdog.service` |
| `gammu-smsd-watchdog.timer.example` | `gammu-smsd-watchdog.timer` |
| `99-gammu-smsd-modem.rules.example` | `99-gammu-smsd-modem.rules` |
| — | `config.pkl` (repo root) |

### Telegram config (`config.pkl`)

If the installer skips interactive setup, run once:

```bash
.venv/bin/python src/models/configuration.py "$(pwd)/config.pkl"
```

Use the recommended inbox path printed by the installer (typically `<repo>/sms/inbox/`).

Re-running `./install.sh` (with or without `--user`) runs `daemon-reload` and **restarts** `gammu-smsd` if it is already running, so unit and config changes take effect. A new start only happens when the service was not running and `config.pkl` exists.

If you skipped `config.pkl` during install, the unit is **enabled** but **not started**. After creating `config.pkl` (re-run `install.sh` with the modem plugged in if `device` in `gammurc` is wrong):

```bash
systemctl --user start gammu-smsd   # --user install
# or: sudo systemctl start gammu-smsd
```

### User install: enable linger

After `./install.sh --user`, run:

```bash
sudo loginctl enable-linger "$USER"
```

Without linger, user-level `gammu-smsd` stops when you log out.

### Manual install (without `install.sh`)

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install .
```

On Windows (Git Bash), if `python` points at an older version:

```bash
py -3.14 -m venv .venv
source .venv/Scripts/activate
pip install .
```

## Install Gammu (manual)

If not using `./install.sh` (system mode installs these automatically):

```bash
sudo apt install gammu gammu-smsd
```

Discover the modem serial device (prefer the persistent `by-id` symlink):

```bash
ls -la /dev/serial/by-id/
sudo gammu-detect
```

## Gammu configuration

After `install.sh`, generated configs live in the repo (not `/etc/gammurc` by default):

- **`gammurc`** — device, spool paths, `runonreceive`
- **`gammu-smsd.sysconfig`** — `GAMMU_CONFIG_FILE`, `GAMMU_USER`, `GAMMU_GROUP`
- **`gammu-smsd.service`** — systemd unit (`Restart=always`, `RestartSec=10`) referencing the sysconfig file
- **`gammu-smsd-watchdog.service`** / **`gammu-smsd-watchdog.timer`** — runs `gammu-smsd-watchdog.sh` every 2 minutes to restart `gammu-smsd` if it gets stuck in a device-error loop (`DEVICEWRITEERROR[11]`, `DEVICENOTEXIST[4]`, `TIMEOUT[14]`)
- **`99-gammu-smsd-modem.rules`** — udev rule that disables USB autosuspend for the modem and restarts `gammu-smsd` whenever the modem serial interface re-enumerates (installed to `/etc/udev/rules.d/99-gammu-smsd-modem.rules`)

**`device`** in `gammurc` is chosen during `install.sh` in this order: `GAMMU_DEVICE` env var (if set), Huawei `if02` under `/dev/serial/by-id/`, `gammu-detect` mapped to its `/dev/serial/by-id/` (or `/dev/serial/by-path/`) symlink, then fallback serial ports. Re-run install with the modem plugged in (or run `GAMMU_DEVICE=/dev/serial/by-id/... ./install.sh --user`) to change it.

`runonreceive` points at `.venv/bin/python`, `src/sms.py`, and `config.pkl` (repo root). When a message arrives, **gammu-smsd appends the new SMS filename** (basename under `inboxpath`); `sms.py` resolves it using `inbox_folder` from `config.pkl`.

### systemd, watchdog, and udev

> **Do not run both system and `--user` modes at once.** `install.sh` automatically detects and removes the opposite-mode `gammu-smsd` unit(s) so they cannot fight over the same SysV shared-memory segment.

**User mode** (`./install.sh --user`):

- Units: `~/.config/systemd/user/gammu-smsd.service` (`WantedBy=default.target`, `Type=simple`, `Restart=always`, `RestartSec=10`), plus `gammu-smsd-watchdog.service` and `gammu-smsd-watchdog.timer`
- PID file: `<repo>/gammu-smsd.pid` (passed to `--pid`; no `PIDFile=` in the unit)
- Logs (under `<repo>/log/`, gitignored): `gammu-smsd.log`, `gammu-smsd-error.log` (daemon stderr), `sms.log` and `sms-error.log` (`sms.py --log` on `runonreceive`)
- Status: `systemctl --user status gammu-smsd gammu-smsd-watchdog.timer`
- USB access: your user must be in `dialout` (or use udev rules for `/dev/ttyUSB*`).
- Udev rule: `install.sh --user` prompts to install `/etc/udev/rules.d/99-gammu-smsd-modem.rules` via `sudo` (or prints the exact command if skipped).

**System mode** (`./install.sh`):

- Units: `/etc/systemd/system/gammu-smsd.service`, `gammu-smsd-watchdog.service`, `gammu-smsd-watchdog.timer`
- Logs: `logfile = syslog` in `gammurc` (view with `journalctl -t gammu-smsd`)
- Udev rule: automatically installed to `/etc/udev/rules.d/99-gammu-smsd-modem.rules`
- Status: `sudo systemctl status gammu-smsd gammu-smsd-watchdog.timer`

To change the templates for future installs, edit **`gammu-smsd.service.example`**, **`gammu-smsd-watchdog.*.example`**, or **`99-gammu-smsd-modem.rules.example`** and re-run `install.sh`.

### Troubleshooting `gammu-smsd` failed

- **`Failed to allocate shared memory segment!, Error 13: Permission denied`**: both the system and `--user` `gammu-smsd` services were enabled against the same `gammurc`. Re-run `./install.sh --user` (or `./install.sh`) to automatically disable and remove the conflicting unit, or disable the system unit manually:

  ```bash
  sudo systemctl disable --now gammu-smsd.service
  sudo rm -f /etc/systemd/system/gammu-smsd.service
  sudo systemctl daemon-reload
  ```

- **`DEVICEWRITEERROR[11]` / `DEVICENOTEXIST[4]` after a USB modem reset**: ensure `device` in `gammurc` uses `/dev/serial/by-id/...` (not `/dev/ttyUSB*`), `/etc/udev/rules.d/99-gammu-smsd-modem.rules` is installed, and `gammu-smsd-watchdog.timer` is active. Check watchdog activity with:

  ```bash
  journalctl --user -u gammu-smsd-watchdog.service -n 20
  ```

- **`Can't open PID file '/run/gammu-smsd.pid'`**: the user unit is outdated. Re-run `./install.sh --user` or set `Type=simple`, remove `PIDFile=`, and use:

  ```ini
  ExecStart=/usr/bin/gammu-smsd -l -c ${GAMMU_CONFIG_FILE} --pid=/home/you/sms-telegram-bot/gammu-smsd.pid
  ```

  (no `--daemon`, no `--user`/`--group` in a user service)

Test the modem in the foreground (should stay running until Ctrl+C):

```bash
systemctl --user stop gammu-smsd
/usr/bin/gammu-smsd -l -c ~/sms-telegram-bot/gammurc -p ~/sms-telegram-bot/gammu-smsd.pid
```

If the SIM needs a PIN, set `pin = …` under `[smsd]` in `gammurc`. Ensure `groups` includes `dialout` and `device` points to the modem's AT/PCUI port (`/dev/serial/by-id/...`).

### Advanced: system-wide `/etc` paths

Optional legacy layout: copy `gammurc.example` to `/etc/gammurc`, `gammu-smsd.sysconfig.example` to `/etc/sysconfig/gammu-smsd`, and use a systemd drop-in on Debian/Ubuntu:

```ini
[Service]
Environment=GAMMU_CONFIG_FILE=/etc/gammurc
Environment=GAMMU_USER=root
Environment=GAMMU_GROUP=root
```

## eSIM usage

You can use an EUICC SIM (e.g. from [AliExpress](https://aliexpress.com/item/1005008298268854.html)) and a USB reader ([example](https://aliexpress.com/item/4000618742328.html)), then create profiles with [MiniLPA](https://github.com/EsimMoe/MiniLPA) so the modem uses your eSIM like a normal SIM.

## Contribution / Development

Install dev dependencies and register Git hooks from the **repository root** (where `pyproject.toml` lives—not `src/`), with your venv active:

```bash
cd /path/to/sms-telegram-bot
pip install -e ".[dev]"
pre-commit install
```

On each `git commit`, [pre-commit](https://pre-commit.com/) runs the hooks defined in `.pre-commit-config.yaml` on Python files under `src/`:

| Hook | Tool | Config |
|------|------|--------|
| `isort` | Import sorting | `--profile black` |
| `black` | Formatter | `pyproject.toml` |
| `flake8` | Style/lint | `setup.cfg` |
| `pylint` | Deeper lint | `pyproject.toml` |

If a hook fails, fix the reported issues (black and isort may auto-fix), stage the changes, and commit again.

Run checks manually:

```bash
pre-commit run              # staged files only
pre-commit run --all-files  # entire repo (under src/)
pre-commit run black --all-files   # single hook
```

To skip hooks when necessary (use sparingly):

```bash
git commit --no-verify
SKIP=pylint git commit -m "your message"
```
