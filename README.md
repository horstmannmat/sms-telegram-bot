# SMS → Telegram (Gammu)

Python helper that **gammu-smsd** runs when a new SMS arrives. It reads the spool file, forwards the text to Telegram, then removes the file only after a successful send.

## Requirements

- Linux with [Gammu](https://docs.gammu.org/quick/index.html#installing-gammu) and `gammu-smsd`
- Python 3.10+
- A USB modem (or compatible radio) recognized as a serial device (often `/dev/ttyUSB0`)

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

Uninstall stops and removes the **sms-telegram-bot** systemd unit and deletes `.venv`, generated `gammurc` / sysconfig / service files, and `gammu-smsd.pid`. It does **not** remove `python3`, `gammu`, or `gammu-smsd` (apt packages). **`config.pkl`**, **`sms/`**, and **`log/`** are kept.

The installer:

1. Checks Python >= 3.10 and `gammu-smsd` (system mode installs missing packages via `apt` when possible).
2. Recreates `.venv` and runs `pip install .`.
3. Generates local configs with **absolute paths** (see templates below).
4. Creates `sms/inbox`, `sms/outbox`, `sms/sent`, `sms/error` under the repo.
5. Prompts to create `config.pkl` at the repo root interactively (or prints the manual command).
6. Enables and starts the `gammu-smsd` systemd unit.

### Templates vs generated files

| In repo (tracked) | After `install.sh` (gitignored) |
|-------------------|----------------------------------|
| `gammurc.example` | `gammurc` |
| `gammu-smsd.sysconfig.example` | `gammu-smsd.sysconfig` |
| `gammu-smsd.service.example` | `gammu-smsd.service` |
| — | `config.pkl` (repo root) |

### Telegram config (`config.pkl`)

If the installer skips interactive setup, run once:

```bash
.venv/bin/python src/models/configuration.py "$(pwd)/config.pkl"
```

Use the recommended inbox path printed by the installer (typically `<repo>/sms/inbox/`).

Re-running `./install.sh` (with or without `--user`) runs `daemon-reload` and **restarts** `gammu-smsd` if it is already running, so unit and config changes take effect. A new start only happens when the service was not running and `config.pkl` exists.

If you skipped `config.pkl` during install, the unit is **enabled** but **not started**. After creating `config.pkl` and fixing `device` in `gammurc`:

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

Discover the modem serial device:

```bash
sudo gammu-detect
```

## Gammu configuration

After `install.sh`, configs live in the repo (not `/etc/gammurc` by default):

- **`gammurc`** — device, spool paths, `runonreceive`
- **`gammu-smsd.sysconfig`** — `GAMMU_CONFIG_FILE`, `GAMMU_USER`, `GAMMU_GROUP`
- **`gammu-smsd.service`** — systemd unit referencing the sysconfig file

Edit **`device`** in `gammurc` after `gammu-detect` (default `/dev/ttyUSB0`).

`runonreceive` points at `.venv/bin/python`, `src/sms.py`, and `config.pkl` (repo root). When a message arrives, **gammu-smsd appends the new SMS file path** after those arguments.

### systemd

**User mode** (`./install.sh --user`):

- Unit: `~/.config/systemd/user/gammu-smsd.service` (`WantedBy=default.target`, `Type=simple`, no `--daemon`)
- PID file: `<repo>/gammu-smsd.pid` (passed to `--pid`; no `PIDFile=` in the unit)
- Logs (under `<repo>/log/`, gitignored): `gammu-smsd.log`, `gammu-smsd-error.log` (daemon stderr), `sms.log` (`sms.py --log` on `runonreceive`)
- Status: `systemctl --user status gammu-smsd`
- USB access: your user must be in `dialout` (or use udev rules for `/dev/ttyUSB*`).

**System mode** (`./install.sh`):

- Unit: `/etc/systemd/system/gammu-smsd.service` (copied from generated file)
- Status: `sudo systemctl status gammu-smsd`

To change the template for future installs, edit **`gammu-smsd.service.example`** and re-run `install.sh`. For a one-off fix, edit the generated **`gammu-smsd.service`** or adjust `ExecStart` if `gammu-smsd` is not at `/usr/bin/gammu-smsd`.

### Troubleshooting `gammu-smsd` failed

If `journalctl` mentions **`Can't open PID file '/run/gammu-smsd.pid'`**, the user unit is outdated. Re-run `./install.sh --user` or set `Type=simple`, remove `PIDFile=`, and use:

```ini
ExecStart=/usr/bin/gammu-smsd -l -c ${GAMMU_CONFIG_FILE} --pid=/home/you/sms-telegram-bot/gammu-smsd.pid
```

(no `--daemon`, no `--user`/`--group` in a user service)

Test the modem in the foreground (should stay running until Ctrl+C):

```bash
systemctl --user stop gammu-smsd
/usr/bin/gammu-smsd -l -c ~/sms-telegram-bot/gammurc -p ~/sms-telegram-bot/gammu-smsd.pid
```

If the SIM needs a PIN, set `pin = …` under `[gammu]` in `gammurc`. Ensure `groups` includes `dialout` and `device` matches `gammu-detect`.

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
