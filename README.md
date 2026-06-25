# Headless RustDesk for Raspberry Pi

One-shot, interactive setup that makes a **headless Raspberry Pi** (no monitor)
permanently reachable through a **self-hosted RustDesk** server. Flash any
Raspberry Pi OS image, run one script, answer three prompts — done.

- **`setup-rustdesk-pi.sh`** — installs and configures everything (idempotent).
- **`verify-rustdesk-pi.sh`** — post-reboot health check.

Works on **any Raspberry Pi OS image** — Lite or Desktop, Bookworm or newer,
on Pi 5 / 4 / 3 (arm64 or armhf). The script installs whatever is missing, so
the same command suits a bare Lite image or a full Desktop image.

---

## Quick start

First, flash any Raspberry Pi OS image and boot the Pi (enable SSH if it's
headless). Then use **one** of the methods below.

### Option A — one-line install (recommended)

On the Pi, or over SSH:

```bash
curl -fsSL https://raw.githubusercontent.com/akilaid/rustdesk-pi-setup/main/setup-rustdesk-pi.sh | sudo bash
```

It prompts you right in the terminal (the prompts are read from `/dev/tty`, so
piping through `bash` works fine). Optionally grab the health-check script too:

```bash
curl -fsSLO https://raw.githubusercontent.com/akilaid/rustdesk-pi-setup/main/verify-rustdesk-pi.sh && chmod +x verify-rustdesk-pi.sh
```

### Option B — clone the repo (gets both scripts)

```bash
git clone https://github.com/akilaid/rustdesk-pi-setup.git
cd rustdesk-pi-setup
sudo ./setup-rustdesk-pi.sh
```

### Option C — copy from your own machine

```bash
scp setup-rustdesk-pi.sh verify-rustdesk-pi.sh <user>@<pi-ip>:~/
ssh <user>@<pi-ip>
chmod +x setup-rustdesk-pi.sh verify-rustdesk-pi.sh
sudo ./setup-rustdesk-pi.sh
```

Then: answer the prompts, let it finish, and reboot when it offers. After reboot,
connect from your RustDesk client using the **ID** and **password** the script
printed (your client must point at the same self-hosted server + key).

### The prompts
```
Primary desktop user to auto-login [pi]:           ⏎   (auto-detected; press Enter)
Self-hosted RustDesk server IP/host (rendezvous):  203.0.113.10
Relay server IP/host [203.0.113.10]:              ⏎   (defaults to the rendezvous host)
Server public key (long base64 string):            EXAMPLEpublicKeyBase64==
Permanent access password (blank = auto-generate): ••••••••
Confirm password:                                  ••••••••
```
You really only need the **server IP**, the **key**, and a **password** (leave the
password blank to auto-generate a strong one — it's printed at the end).

---

## What it does

| Step | Action |
|------|--------|
| 1 | Installs the native **Raspberry Pi "PIXEL" desktop** if missing, then forces the **X11 backend** (`raspi-config nonint do_wayland W1`). Same look as the default Wayland desktop, but reliable for RustDesk. |
| 2 | **LightDM auto-login** of your user into the X11 session on `:0`. |
| 3 | Disables **screen blanking / DPMS** so the remote view never blacks out. |
| 4 | Installs the official **RustDesk `.deb`** matched to the CPU (`arm64`→aarch64, `armhf`→armv7) if missing. |
| 5 | Forces a **virtual HDMI display** on every port via `cmdline.txt` (headless KMS needs this — without a monitor there's otherwise no framebuffer to capture). |
| 6 | Writes the **self-hosted server** config (rendezvous / relay / key) for the root service. |
| 7 | Sets the **permanent unattended password** and enables the service on boot. |
| 8 | Offers to **reboot** (required to apply the display, auto-login, and X11 switch). |

### Why X11 and not Wayland
The Raspberry Pi desktop looks identical on X11 or Wayland — it's the same PIXEL
theme either way. RustDesk's Wayland capture is **experimental**: no full
unattended access, it can't capture the login screen, and headless connects
often show a black screen. Running the same desktop on **X11** removes all of
that while keeping the familiar look.

### Behaviour by image
| Fresh image | Desktop install | Wayland→X11 switch | RustDesk install |
|-------------|-----------------|--------------------|------------------|
| **Lite** | installs PIXEL desktop | applied | if missing |
| **Full Desktop** | skipped (already present) | applied | if missing |
| **Already configured** | skipped | already X11 | skipped |

---

## Unattended (no prompts)

Pass values as environment variables to skip every prompt — handy for imaging or
config-management:

```bash
sudo RENDEZVOUS_HOST=203.0.113.10 \
     SERVER_KEY='EXAMPLEpublicKeyBase64==' \
     RUSTDESK_PASSWORD='your-strong-password' \
     AUTO_REBOOT=yes \
     ./setup-rustdesk-pi.sh
```

### All tunable variables
| Variable | Default | Meaning |
|----------|---------|---------|
| `PRIMARY_USER` | auto-detected (`$SUDO_USER`, else first real user) | User to auto-login |
| `RENDEZVOUS_HOST` | *(prompted, required)* | hbbs IP/host (no port) |
| `RELAY_HOST` | = `RENDEZVOUS_HOST` | hbbr IP/host |
| `SERVER_KEY` | *(prompted, required)* | Server public key |
| `RUSTDESK_PASSWORD` | *(prompted; blank = auto-generate)* | Permanent access password |
| `API_SERVER` | *(empty)* | Optional, e.g. `https://host` (web console / address book only) |
| `HDMI_MODE` | `1920x1080@60D` | Forced virtual mode (trailing `D` = force connector on) |
| `HDMI_CONNECTOR` | *(empty = all HDMI ports)* | Pin a single connector, e.g. `HDMI-A-1` |
| `PURGE_SCREENSAVERS` | `yes` | Remove `light-locker` / `xfce4-screensaver` if present |
| `ADD_ORDERING_DROPIN` | `yes` | Start the service after the display manager |
| `AUTO_REBOOT` | `ask` | `yes` / `no` / `ask` |

It's **idempotent** — safe to re-run. A second run installs nothing and just
re-asserts the configuration.

---

## Verify after reboot

```bash
sudo ./verify-rustdesk-pi.sh
```
Expect all `[PASS]`: active **x11** session on `seat0`, a real framebuffer mode,
`rustdesk.service` active, no "Can't open display", bound to your self-hosted
server, and it prints the RustDesk ID.

Useful one-liners:
```bash
sudo rustdesk --get-id                 # show this Pi's RustDesk ID
sudo rustdesk --password 'new-pass'    # change the permanent password
```

---

## Requirements & notes

- Run as **root** (`sudo`). The RustDesk background service is a root system
  service by design (needed to capture the screen and inject input).
- **Internet access** on first run (to `apt` the desktop and download the
  RustDesk `.deb`). On a Lite image the desktop is a sizeable one-time download.
- A **reboot** is required at the end (the script offers it) to apply the
  `cmdline.txt` display change, auto-login, and the X11 backend switch.

## Troubleshooting

- **Black screen on connect** → confirm you're on X11: `loginctl show-session <id> -p Type`
  should say `x11`. If it says `wayland`, re-run the script (it runs
  `raspi-config nonint do_wayland W1`) and reboot.
- **"Can't open display"** in the logs → no active desktop session; check
  `loginctl` shows your user `Active=yes` on `seat0`, and that LightDM auto-login
  took effect (`/etc/lightdm/lightdm.conf.d/50-autologin.conf`).
- **Client can't see the Pi** → make sure your RustDesk client's network settings
  point at the **same** rendezvous/relay host and **key**.

## Rollback

Every change is additive and file-scoped:
- `raspi-config` → switch the backend back to Wayland, or undo desktop auto-login.
- Delete `/etc/lightdm/lightdm.conf.d/50-autologin.conf`,
  `~/.config/autostart/disable-blank.desktop`, and
  `/etc/systemd/system/rustdesk.service.d/10-after-dm.conf`.
- Remove the `video=…` token from `/boot/firmware/cmdline.txt`
  (a backup `*.bak.rustdesk` is saved on first edit).
- `sudo apt purge raspberrypi-ui-mods` to remove the desktop, if desired.
- `sudo systemctl disable --now rustdesk` to stop RustDesk.
