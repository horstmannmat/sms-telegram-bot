# SMS → Telegram (Gammu)

Python helper that **gammu-smsd** runs when a new SMS arrives. It reads the spool file, forwards the text to Telegram, then removes the file only after a successful send.

## Requirements

- Linux with [Gammu](https://docs.gammu.org/quick/index.html#installing-gammu) and `gammu-smsd`
- Python 3.9+
- A USB modem (or compatible radio) recognized as a serial device (often `/dev/ttyUSB0`)

## Install Gammu

```bash
sudo apt install gammu gammu-smsd
```

Discover the modem serial device:

```bash
sudo gammu-detect
```

## Install this project

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install .
```

After `pip install .`, the entry point `sms-telegram-bot` runs the same code as `python src/sms.py` (adjust paths if you run from the repo without installing):

```bash
sms-telegram-bot --help
```

First-time setup must be run **interactively** (terminal) so `config.pkl` can be created with your Telegram token, chat ID, and Gammu inbox folder:

```bash
python src/sms.py
# or: sms-telegram-bot
```

## Gammu configuration

### Quick reference

- Copy the template (once): e.g. `cp gammurc.example /etc/gammurc`, then edit device, paths, and `runonreceive`.
- Pass it to `gammu-smsd`: `-c /etc/gammurc` (or your chosen path).
- With the provided unit: set `GAMMU_CONFIG_FILE=/etc/gammurc` in `/etc/sysconfig/gammu-smsd` (from `gammu-smsd.sysconfig.example`) or in a **systemd drop-in** (typical on Debian/Ubuntu, where `/etc/sysconfig` may not exist). The detailed steps below cover both.

**What “automatic” means:** one installed config file plus `GAMMU_CONFIG_FILE` (or `-c`) always pointing at it—not renaming `gammurc.example` on the server without copying it to that path.

1. Copy the example and **edit every placeholder** (device path and all `/path/to/...` entries):

   ```bash
   cp gammurc.example /etc/gammurc
   sudo chmod 600 /etc/gammurc
   ```

2. Gammu does **not** read `gammurc.example` by name. It uses the path you pass to `gammu-smsd -c` (or the default `/etc/gammurc` on many systems). The `.example` file in this repo is only a template.

3. Point **`runonreceive`** in that file at your venv Python and this script, with `config.pkl` as the first script argument, for example:

   ```ini
   runonreceive = /home/you/sms-telegram-bot/.venv/bin/python /home/you/sms-telegram-bot/src/sms.py /home/you/sms-telegram-bot/src/config.pkl
   ```

   When a message arrives, **gammu-smsd appends the path of the new SMS file** after those arguments. The script uses that path when present; otherwise it scans `inboxpath` for `*.txt`.

### Making `systemd` use your config file

The shipped unit `gammu-smsd.service` expects environment variables from `/etc/sysconfig/gammu-smsd` (common on RHEL/Fedora). On Debian/Ubuntu, use a **drop-in** instead of that path.

1. Copy the variable template and adjust:

   ```bash
   sudo cp gammu-smsd.sysconfig.example /etc/sysconfig/gammu-smsd
   ```

   Set at least `GAMMU_CONFIG_FILE=/etc/gammurc` (or wherever you installed the config). This is what makes the daemon use the file you created from `gammurc.example`.

2. **Debian/Ubuntu:** create `/etc/systemd/system/gammu-smsd.service.d/override.conf`:

   ```ini
   [Service]
   Environment=GAMMU_CONFIG_FILE=/etc/gammurc
   Environment=GAMMU_USER=root
   Environment=GAMMU_GROUP=root
   ```

   Adjust user/group to match how you run `gammu-smsd`; then `sudo systemctl daemon-reload && sudo systemctl restart gammu-smsd`.

3. Edit **`gammu-smsd.service`** if your `gammu-smsd` binary is not at `/usr/bin/gammu-smsd` (set the correct path in `ExecStart`).

## eSIM usage

You can use an EUICC SIM (e.g. from [AliExpress](https://aliexpress.com/item/1005008298268854.html)) and a USB reader ([example](https://aliexpress.com/item/4000618742328.html)), then create profiles with [MiniLPA](https://github.com/EsimMoe/MiniLPA) so the modem uses your eSIM like a normal SIM.
