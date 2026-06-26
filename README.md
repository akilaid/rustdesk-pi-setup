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
How many displays to force? [1/all] (default 1):   ⏎   (one display; HDMI-A-2 stays free)
Resolution [1-4] (default 1):                      ⏎   (1=1080p, 2=720p, 3=2K, 4=4K)
```
You really only need the **server IP**, the **key**, and a **password** (leave the
password blank to auto-generate a strong one — it's printed at the end).

**Re-running is friendly.** If the Pi is already configured, the script detects it and
asks `Reuse it and skip the prompts? [Y/n]` — press Enter to keep the existing server,
key, **and** password (no re-typing). Your **RustDesk ID never changes** across re-runs.

---

## What it does

| Step | Action |
|------|--------|
| 1 | Installs the native **Raspberry Pi "PIXEL" desktop** if missing, then forces the **X11 backend** (`raspi-config nonint do_wayland W1`). Same look as the default Wayland desktop, but reliable for RustDesk. |
| 2 | **LightDM auto-login** of your user into the X11 session on `:0`. |
| 3 | Disables **screen blanking / DPMS** so the remote view never blacks out. |
| 4 | Installs the official **RustDesk `.deb`** matched to the CPU (`arm64`→aarch64, `armhf`→armv7) if missing. |
| 5 | Forces a **virtual HDMI display** via `cmdline.txt`, **plus a fake EDID** in `/lib/firmware/edid/` matched to your chosen **resolution** (`1080p` / `720p` / `2K` / `4K`), so the desktop comes up at true 16:9 with no monitor — no "square screen," no plug-a-monitor-in-then-unplug trick. **Defaults to one display (HDMI-A-1)**, leaving HDMI-A-2 free for a real monitor at its native resolution; choose `all` (or `FORCE_ALL_HDMI=yes`) to force every port. |
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
| `RESOLUTION` | *(empty = ask; default `1080p`)* | Virtual display resolution: `1080p` / `720p` / `1440p` (=`2k`) / `2160p` (=`4k`). Sets the mode **and** the matching fake EDID |
| `HDMI_MODE` | *(from `RESOLUTION`)* | **Advanced** override of the forced mode, e.g. `1920x1080@60D` (trailing `D` = force connector on) |
| `HDMI_CONNECTOR` | *(empty)* | Pin ONE specific connector, e.g. `HDMI-A-1` (overrides the display prompt) |
| `FORCE_ALL_HDMI` | *(empty = ask; default 1 display)* | `yes` = force every HDMI port (multiple displays); `no` = single (first port) |
| `FAKE_EDID` | `yes` | Write a fake EDID (matched to `RESOLUTION`) so a headless Pi boots at that mode (fixes the "square screen") |
| `EDID_FILE` | *(from `RESOLUTION`)* | **Advanced** override of the EDID filename under `/lib/firmware/edid/`; point at a captured EDID |
| `PURGE_SCREENSAVERS` | `yes` | Remove `light-locker` / `xfce4-screensaver` if present |
| `ADD_ORDERING_DROPIN` | `yes` | Start the service after the display manager |
| `AUTO_REBOOT` | `ask` | `yes` / `no` / `ask` |
| `ENABLE_VAAPI` | *(empty = ask)* | Experimental hardware video decode (VAAPI); `yes` / `no` to skip the prompt |

It's **idempotent** — safe to re-run. A second run installs nothing and just
re-asserts the configuration. On a re-run it also **detects the existing config and
offers to reuse it** (server / relay / key / password) so you don't retype anything,
and the **RustDesk ID stays the same**. Re-running can also switch the display count
between one and all ports — the `cmdline.txt` display tokens are reconciled, not just
appended.

### Experimental: hardware video decode (VAAPI)

The setup prompts (default **no**) to enable VAAPI hardware video decode so video
in the remote session is offloaded from the CPU. It's **experimental** because Pi
support is uneven:

- **Pi 4** has a real **H.264** hardware decoder → a genuine win for browser/media video.
- **Pi 5** dropped H.264 hardware decode; it does **HEVC-only** (via V4L2, great in
  VLC/mpv). H.264 decodes on the CPU — fine at 1080p — and stock Chromium usually still
  reports "Video Decode: software".

Over RustDesk the video **encode** is often the real bottleneck anyway, so treat this as
a nice-to-have. It installs the VAAPI runtime + `vainfo`, adds you to the `video`/`render`
groups, and writes a Chromium flags drop-in. Skip it with `ENABLE_VAAPI=no` (or just press
Enter at the prompt); enable non-interactively with `ENABLE_VAAPI=yes`.

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
- **Pi shows online on the *public* server / unattended password missing** → the
  permanent password and custom server are seeded **after** the service is running
  (never via a `rustdesk` CLI call while it's stopped — that resets the config to a
  public `rs-*.rustdesk.com` rendezvous). Just **re-run** the script (it's idempotent,
  no reflash) and reboot; `verify-rustdesk-pi.sh` will FAIL loudly if the config ever
  reverts to a public host or the password is empty.

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
