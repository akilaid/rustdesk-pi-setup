#!/usr/bin/env bash
#
# setup-rustdesk-pi.sh
# One-shot, interactive, idempotent RustDesk bootstrap for a HEADLESS Raspberry Pi
# (Pi 5 / 4 / 3, arm64 or armhf) running ANY Raspberry Pi OS image — Lite OR Desktop,
# Bookworm or newer.
#
# Flow:  flash any Pi OS  ->  sudo ./setup-rustdesk-pi.sh  ->  answer 3 prompts
#        (server IP, key, password)  ->  it installs + configures EVERYTHING  ->  reboot.
#
# What it does (install-if-missing, so it adapts to whatever image you flashed):
#   1. Prompts for server IP / relay / key / password (or reads them from env vars)
#   2. Installs the native Raspberry Pi "PIXEL" desktop if absent, then forces the
#      X11 backend (raspi-config do_wayland W1). Same look as the Wayland desktop, but
#      reliable for RustDesk — Wayland capture is experimental and black-screens headless.
#   3. LightDM auto-login of the primary user into the X11 session on :0
#   4. Disables screen blanking / DPMS so the remote view never blacks out
#   5. Installs the official RustDesk .deb (matched to the CPU) if absent
#   6. Forces a virtual HDMI display on every port (headless KMS) + writes a fake 1080p
#      EDID so the desktop comes up at true 16:9 with no monitor (no "square screen")
#   7. Seeds the self-hosted server config + permanent password for the ROOT service
#   8. Enables the service and offers to reboot
#   (optional) Experimental hardware video decode (VAAPI) — prompted, default skip
#
# RUN AS:  sudo ./setup-rustdesk-pi.sh
# Unattended (no prompts): pass values via env, e.g.
#   sudo RENDEZVOUS_HOST=1.2.3.4 SERVER_KEY=... RUSTDESK_PASSWORD=... AUTO_REBOOT=yes ./setup-rustdesk-pi.sh
# Re-runnable: yes (idempotent). A reboot is required at the end.
#
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Values — prompted if unset, or pass them as environment variables for an
# unattended run. The three you really must provide are RENDEZVOUS_HOST,
# SERVER_KEY and RUSTDESK_PASSWORD (the rest auto-detect sensible defaults).
# ──────────────────────────────────────────────────────────────────────────────
PRIMARY_USER="${PRIMARY_USER:-}"                # existing main user to auto-login
RENDEZVOUS_HOST="${RENDEZVOUS_HOST:-}"          # your hbbs IP or hostname (no port)
RELAY_HOST="${RELAY_HOST:-}"                    # your hbbr IP or hostname (often same)
SERVER_KEY="${SERVER_KEY:-}"                    # server public key (long base64 string)
RUSTDESK_PASSWORD="${RUSTDESK_PASSWORD:-}"      # permanent unattended-access password
API_SERVER="${API_SERVER:-}"                    # optional, e.g. https://host ; leave empty if unused

# Headless virtual display
HDMI_MODE="${HDMI_MODE:-1920x1080@60D}"         # trailing 'D' forces the connector ON with no monitor
HDMI_CONNECTOR="${HDMI_CONNECTOR:-}"            # optional: pin ONE connector; empty = force ALL HDMI ports
FAKE_EDID="${FAKE_EDID:-yes}"                   # write a fake 1080p EDID so a headless Pi boots at true 16:9
EDID_FILE="${EDID_FILE:-rustdesk-1080p.bin}"    # EDID filename under /lib/firmware/edid/ (point at a captured one to override)

# Behaviour toggles
PURGE_SCREENSAVERS="${PURGE_SCREENSAVERS:-yes}" # purge light-locker + xfce4-screensaver if present
ADD_ORDERING_DROPIN="${ADD_ORDERING_DROPIN:-yes}" # start rustdesk.service after the display manager
ENABLE_VAAPI="${ENABLE_VAAPI:-}"                # experimental HW video decode (VAAPI); empty = ask, or set yes/no
AUTO_REBOOT="${AUTO_REBOOT:-ask}"               # yes | no | ask
# ──────────────────────────────────────────────────────────────────────────────

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0"

# Where to read interactive answers from (works even when piped via curl|bash).
TTY=/dev/tty; [[ -e "$TTY" ]] || TTY=/dev/stdin

ask() {  # $1=varname  $2=prompt  $3=default(optional)
  local var=$1 msg=$2 def=${3:-} cur=${!1:-} input
  [[ -n "$cur" && "$cur" != "CHANGE_ME" ]] && return         # already supplied via env
  if [[ -n "$def" ]]; then
    read -r -p "$msg [$def]: " input <"$TTY"; printf -v "$var" '%s' "${input:-$def}"
  else
    read -r -p "$msg: " input <"$TTY"; printf -v "$var" '%s' "$input"
  fi
}

# ── Gather configuration ──────────────────────────────────────────────────────
DEF_USER="${SUDO_USER:-}"
[[ -z "$DEF_USER" || "$DEF_USER" == "root" ]] && \
  DEF_USER="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd || true)"

# If something required is missing and we have no terminal, fail with guidance.
if [[ ( -z "$RENDEZVOUS_HOST" || -z "$SERVER_KEY" || -z "$RUSTDESK_PASSWORD" ) && ! -e /dev/tty && ! -t 0 ]]; then
  die "No terminal for prompts. Pass values via env: RENDEZVOUS_HOST, SERVER_KEY, RUSTDESK_PASSWORD (and optionally PRIMARY_USER, RELAY_HOST)."
fi

ask PRIMARY_USER    "Primary desktop user to auto-login" "$DEF_USER"
ask RENDEZVOUS_HOST "Self-hosted RustDesk server IP/host (rendezvous, hbbs)"
ask RELAY_HOST      "Relay server IP/host (hbbr)" "$RENDEZVOUS_HOST"
ask SERVER_KEY      "Server public key (long base64 string)"

if [[ -z "$RUSTDESK_PASSWORD" || "$RUSTDESK_PASSWORD" == "CHANGE_ME" ]]; then
  while :; do
    read -rs -p "Permanent access password (blank = auto-generate): " p1 <"$TTY"; echo
    if [[ -z "$p1" ]]; then
      RUSTDESK_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16 || true)"
      printf '  -> generated password: %s\n' "$RUSTDESK_PASSWORD"
      break
    fi
    read -rs -p "Confirm password: " p2 <"$TTY"; echo
    if [[ "$p1" == "$p2" ]]; then RUSTDESK_PASSWORD="$p1"; break; else echo "  passwords do not match — try again"; fi
  done
fi

# Optional, EXPERIMENTAL hardware video decode (VAAPI) — default skip.
if [[ -z "$ENABLE_VAAPI" ]]; then
  if [[ -e /dev/tty ]]; then
    read -r -p "Enable EXPERIMENTAL hardware video decode (VAAPI)? Big win on Pi 4; limited on Pi 5 (HEVC-only) [y/N]: " va <"$TTY" || va=""
    [[ "$va" =~ ^[Yy]$ ]] && ENABLE_VAAPI=yes || ENABLE_VAAPI=no
  else
    ENABLE_VAAPI=no
  fi
fi
[[ "$ENABLE_VAAPI" =~ ^([Yy]([Ee][Ss])?|1|[Tt][Rr][Uu][Ee])$ ]] && ENABLE_VAAPI=yes || ENABLE_VAAPI=no

# ── Validate ──────────────────────────────────────────────────────────────────
[[ -n "$RENDEZVOUS_HOST" ]] || die "Rendezvous server is required."
[[ -n "$SERVER_KEY"      ]] || die "Server public key is required."
[[ -n "$RUSTDESK_PASSWORD" ]] || die "Password is required."
[[ -n "$RELAY_HOST"      ]] || RELAY_HOST="$RENDEZVOUS_HOST"
id "$PRIMARY_USER" &>/dev/null || die "User '$PRIMARY_USER' does not exist. Set PRIMARY_USER correctly."
USER_HOME="$(getent passwd "$PRIMARY_USER" | cut -d: -f6)"
[[ -d "$USER_HOME" ]] || die "Home directory for '$PRIMARY_USER' not found ($USER_HOME)."

log "Configuration:"
printf '    user=%s   rendezvous=%s   relay=%s   api=%s\n' \
  "$PRIMARY_USER" "$RENDEZVOUS_HOST" "$RELAY_HOST" "${API_SERVER:-<none>}"

# ── Step 1: install the native Raspberry Pi desktop (PIXEL) if missing, X11 ────
log "Ensuring the Raspberry Pi desktop is installed and on the X11 backend…"
need=()
for p in xserver-xorg xinit lightdm raspberrypi-ui-mods; do
  dpkg -s "$p" &>/dev/null || need+=("$p")
done
if ((${#need[@]})); then
  log "Installing desktop stack: ${need[*]}  (this is the big download on a Lite image)"
  echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}"
else
  log "Desktop stack already present — skipping install."
fi
# Force the X11 backend (identical PIXEL look, but RustDesk-reliable) + desktop autologin.
if command -v raspi-config &>/dev/null; then
  raspi-config nonint do_wayland W1        2>/dev/null || warn "raspi-config do_wayland W1 unavailable — assuming X11 already in effect."
  raspi-config nonint do_boot_behaviour B4 2>/dev/null || warn "raspi-config do_boot_behaviour B4 unavailable — relying on the LightDM drop-in below."
fi
[[ -e /etc/X11/default-display-manager ]] && echo /usr/sbin/lightdm > /etc/X11/default-display-manager
systemctl enable lightdm        >/dev/null 2>&1 || true
systemctl set-default graphical.target >/dev/null 2>&1 || true

# ── Step 2: LightDM auto-login of the primary user (system-default X11 session) ─
install -d -m 0755 /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf <<EOF
[Seat:*]
autologin-user=${PRIMARY_USER}
autologin-user-timeout=0
EOF
log "Wrote LightDM auto-login drop-in (user=${PRIMARY_USER}, system-default X11 session)"
getent group autologin >/dev/null || groupadd -r autologin
gpasswd -a "$PRIMARY_USER" autologin     >/dev/null 2>&1 || true
gpasswd -a "$PRIMARY_USER" nopasswdlogin >/dev/null 2>&1 || true

# ── Step 3: disable blanking / DPMS / lock for unattended capture ─────────────
if [[ "$PURGE_SCREENSAVERS" == "yes" ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get purge -y light-locker xfce4-screensaver 2>/dev/null || \
    warn "Could not purge lockers (not installed or apt busy) — continuing"
fi
command -v raspi-config &>/dev/null && { raspi-config nonint do_blanking 1 2>/dev/null || true; }
install -d -m 0755 -o "$PRIMARY_USER" -g "$PRIMARY_USER" "$USER_HOME/.config/autostart"
cat > "$USER_HOME/.config/autostart/disable-blank.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Disable screen blanking (RustDesk unattended)
Exec=/bin/sh -c "xset s off -dpms s noblank"
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
chown "$PRIMARY_USER":"$PRIMARY_USER" "$USER_HOME/.config/autostart/disable-blank.desktop"
log "Disabled screen blanking/DPMS (raspi-config do_blanking + autostart xset)"

# ── Step 3b (optional): EXPERIMENTAL hardware video decode (VAAPI) ─────────────
if [[ "$ENABLE_VAAPI" == "yes" ]]; then
  log "Enabling EXPERIMENTAL hardware video decode (VAAPI)…"
  va_need=()
  for p in libva2 libva-drm2 vainfo mesa-va-drivers; do
    dpkg -s "$p" &>/dev/null || va_need+=("$p")
  done
  if ((${#va_need[@]})); then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${va_need[@]}" || warn "Some VAAPI packages failed to install — continuing"
  fi
  # device access for the decode hardware (/dev/dri, /dev/video*)
  gpasswd -a "$PRIMARY_USER" video  >/dev/null 2>&1 || true
  gpasswd -a "$PRIMARY_USER" render >/dev/null 2>&1 || true
  # Raspberry Pi OS's chromium-browser sources /etc/chromium.d/* for extra flags.
  install -d -m 0755 /etc/chromium.d
  cat > /etc/chromium.d/20-rustdesk-vaapi <<'EOF'
# Added by setup-rustdesk-pi.sh — experimental VAAPI video decode for Chromium.
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --enable-features=VaapiVideoDecoder --ignore-gpu-blocklist"
EOF
  log "Wrote Chromium VAAPI flags drop-in (/etc/chromium.d/20-rustdesk-vaapi)"
  if command -v vainfo >/dev/null; then
    echo "    --- vainfo: decode profiles THIS board actually exposes ---"
    vainfo 2>&1 | sed 's/^/    /' | head -n 20 || true
  fi
  cat <<'EOF'
    NOTE (experimental) — Pi hardware video decode is uneven:
      • Pi 4: real H.264 hardware decode  → genuine win for browser/media video.
      • Pi 5: HEVC-only via V4L2 (great in VLC/mpv); H.264 decodes on the CPU
        (fine at 1080p), and stock Chromium usually stays "Video Decode: software".
      Over RustDesk the video ENCODE is often the bottleneck anyway.
EOF
else
  log "Skipping hardware video decode (VAAPI) — re-run with ENABLE_VAAPI=yes to enable."
fi

# ── Step 4: install / verify RustDesk (official .deb, matched to the CPU) ──────
if ! command -v rustdesk &>/dev/null; then
  case "$(dpkg --print-architecture)" in
    arm64) asset=aarch64 ;;
    armhf) asset=armv7   ;;
    *)     die "Unsupported architecture '$(dpkg --print-architecture)' for RustDesk auto-install." ;;
  esac
  command -v curl &>/dev/null || { apt-get update -y; DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates; }
  log "Resolving latest RustDesk release for ${asset}…"
  url="$(curl -fsSL https://api.github.com/repos/rustdesk/rustdesk/releases/latest 2>/dev/null \
        | grep -oE "https://[^\"]*-${asset}\.deb" | head -n1 || true)"
  [[ -n "$url" ]] || url="https://github.com/rustdesk/rustdesk/releases/download/1.4.8/rustdesk-1.4.8-${asset}.deb"
  deb="/tmp/rustdesk-${asset}.deb"
  log "Downloading $url"
  curl -fL "$url" -o "$deb"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb"
fi
log "rustdesk binary: $(command -v rustdesk)  ($(rustdesk --version 2>/dev/null || echo 'version unknown'))"
systemctl list-unit-files | grep -q '^rustdesk\.service' || \
  warn "rustdesk.service unit not found — if you installed via Flatpak/AppImage, switch to the .deb."

# Pre-validated generic 1080p EDID (128-byte EDID 1.3; preferred DTD = 1920x1080@60,
# 148.5 MHz; checksum OK). Decoded to /lib/firmware/edid/ so a headless Pi advertises a
# real 1080p monitor and the desktop never falls back to a "square" 4:3 mode.
EDID_B64='AP///////wAx2AAAAAAAAAAhAQOANR54Cu6Ro1RMmSYPUFQAAAABAQEBAQEBAQEBAQEBAQEBAjqAGHE4LUBYLEUAEyohAAAeAAAA/QAySx5TDwAKICAgICAgAAAA/ABSdXN0RGVzawogICAgAAAAEAAgICAgICAgICAgICAgAOE='

# ── Step 5: force a virtual display for headless KMS (every HDMI port) ─────────
CMDLINE="/boot/firmware/cmdline.txt"
[[ -f "$CMDLINE" ]] || CMDLINE="/boot/cmdline.txt"
conns=()
if [[ -f "$CMDLINE" ]]; then
  if [[ -n "$HDMI_CONNECTOR" ]]; then
    conns=("$HDMI_CONNECTOR")
  else
    for s in /sys/class/drm/card*-HDMI-A-*/status; do
      [[ -e "$s" ]] || continue
      c="$(basename "$(dirname "$s")")"; c="${c#card*-}"
      conns+=("$c")
    done
  fi
  ((${#conns[@]})) || conns=("HDMI-A-1")
  made_backup=0
  for c in "${conns[@]}"; do
    if grep -q "video=${c}:" "$CMDLINE"; then
      log "cmdline.txt already forces ${c} — leaving as-is"
    else
      if [[ "$made_backup" -eq 0 ]]; then cp -a "$CMDLINE" "${CMDLINE}.bak.rustdesk" 2>/dev/null || true; made_backup=1; fi
      sed -i "s/[[:space:]]*$/ video=${c}:${HDMI_MODE}/" "$CMDLINE"
      log "Appended 'video=${c}:${HDMI_MODE}' to $CMDLINE"
    fi
  done
  # Fake 1080p EDID: make a headless Pi report a real monitor so the desktop is true 16:9.
  if [[ "$FAKE_EDID" == "yes" ]]; then
    install -d -m 0755 /lib/firmware/edid
    printf '%s' "$EDID_B64" | base64 -d > "/lib/firmware/edid/${EDID_FILE}" || die "Failed to write fake EDID"
    chmod 0644 "/lib/firmware/edid/${EDID_FILE}"
    if grep -q "drm.edid_firmware=" "$CMDLINE"; then
      log "cmdline.txt already sets drm.edid_firmware — leaving as-is"
    else
      edid_arg="drm.edid_firmware="; sep=""
      for c in "${conns[@]}"; do edid_arg+="${sep}${c}:edid/${EDID_FILE}"; sep=","; done
      if [[ "$made_backup" -eq 0 ]]; then cp -a "$CMDLINE" "${CMDLINE}.bak.rustdesk" 2>/dev/null || true; made_backup=1; fi
      sed -i "s|[[:space:]]*\$| ${edid_arg}|" "$CMDLINE"
      log "Appended '${edid_arg}' to $CMDLINE (fake 1080p EDID)"
    fi
  fi
else
  warn "Could not find cmdline.txt — skipping headless display forcing. Set 'video=' manually."
  conns=("HDMI-A-1")
fi

# ── Step 6 & 7: seed server config, then (later, with the service UP) set password ──
# CRITICAL: never invoke a `rustdesk` CLI command while the service is STOPPED.
# With no running service, `rustdesk --password`/`--get-id` re-initialise a DEFAULT
# config (a random public rs-*.rustdesk.com rendezvous) and overwrite RustDesk2.toml,
# wiping the custom server we seed here — that's the "No such file or directory
# (os error 2)" you'd see. So: stop service → write file → start service → only then
# touch the CLI.
ROOT_CFG_DIR="/root/.config/rustdesk"
write_server_config() {
  install -d -m 0700 "$ROOT_CFG_DIR"
  {
    echo "rendezvous_server = '${RENDEZVOUS_HOST}:21116'"
    echo "nat_type = 1"
    echo "serial = 0"
    echo ""
    echo "[options]"
    echo "custom-rendezvous-server = '${RENDEZVOUS_HOST}'"
    echo "relay-server = '${RELAY_HOST}'"
    echo "key = '${SERVER_KEY}'"
    [[ -n "$API_SERVER" ]] && echo "api-server = '${API_SERVER}'"
  } > "$ROOT_CFG_DIR/RustDesk2.toml"
  chmod 0600 "$ROOT_CFG_DIR/RustDesk2.toml"
}

systemctl stop rustdesk 2>/dev/null || true   # stop the .deb-autostarted instance so it can't clobber our write
write_server_config
log "Wrote self-hosted server config to $ROOT_CFG_DIR/RustDesk2.toml"
# NOTE: the permanent password is set further down, AFTER the service is running.

# ── Step 8: optional ordering drop-in + enable the service ────────────────────
if [[ "$ADD_ORDERING_DROPIN" == "yes" ]]; then
  install -d -m 0755 /etc/systemd/system/rustdesk.service.d
  cat > /etc/systemd/system/rustdesk.service.d/10-after-dm.conf <<'EOF'
[Unit]
After=display-manager.service
Wants=display-manager.service
[Service]
Restart=always
RestartSec=2
EOF
  log "Installed systemd ordering drop-in (After=display-manager.service)"
fi
systemctl daemon-reload
systemctl enable --now rustdesk || warn "Could not enable/start rustdesk.service — check the install."

# Wait for the service to be up (IPC socket open) BEFORE any rustdesk CLI call, so the
# password actually lands and we never re-init a default/public config.
for _ in $(seq 1 20); do
  systemctl is-active --quiet rustdesk && break
  sleep 1
done
sleep 2   # give the service a moment to open its IPC socket

# Set the permanent password against the RUNNING service, retrying until it sticks.
pw_set=no
for _ in $(seq 1 10); do
  timeout 15 rustdesk --password "$RUSTDESK_PASSWORD" >/dev/null 2>&1 || true
  if grep -q "^password = '.\+'" "$ROOT_CFG_DIR/RustDesk.toml" 2>/dev/null; then
    pw_set=yes; break
  fi
  sleep 1
done
if [[ "$pw_set" == "yes" ]]; then
  log "Permanent password set."
else
  warn "Could not confirm the permanent password was stored. After reboot, set it with: sudo rustdesk --password '<your-password>'"
fi

RD_ID="$(timeout 20 rustdesk --get-id 2>/dev/null || true)"

# Safety net: confirm the service kept our custom server. It should — only a CLI call
# while the service is STOPPED resets it, which we now avoid — but if anything wiped it,
# re-seed and restart so the box never silently registers to the public server.
if ! grep -q "custom-rendezvous-server" "$ROOT_CFG_DIR/RustDesk2.toml" 2>/dev/null; then
  warn "Custom server missing from RustDesk2.toml after start — re-seeding and restarting."
  systemctl stop rustdesk 2>/dev/null || true
  write_server_config
  systemctl start rustdesk 2>/dev/null || true
fi

cat <<EOF

────────────────────────────────────────────────────────────────────
 RustDesk setup complete.
   RustDesk ID ........ ${RD_ID:-<run: sudo rustdesk --get-id>}
   Password ........... ${RUSTDESK_PASSWORD}
   Server ............. ${RENDEZVOUS_HOST} (relay: ${RELAY_HOST})
   Auto-login user .... ${PRIMARY_USER}  (Raspberry Pi desktop, X11)
   Headless display ... ${HDMI_MODE} on: ${conns[*]}
   Fake 1080p EDID .... ${FAKE_EDID}  (/lib/firmware/edid/${EDID_FILE})
   HW video decode .... ${ENABLE_VAAPI} (experimental — VAAPI)
────────────────────────────────────────────────────────────────────
 A REBOOT is required to apply the display, auto-login and X11 switch.
EOF

do_reboot=no
case "$AUTO_REBOOT" in
  yes) do_reboot=yes ;;
  no)  do_reboot=no  ;;
  *)   if [[ -e /dev/tty ]]; then
         read -r -p " Reboot now to apply? [y/N]: " a <"$TTY" || a=""
         [[ "$a" =~ ^[Yy]$ ]] && do_reboot=yes
       fi ;;
esac
if [[ "$do_reboot" == "yes" ]]; then
  log "Rebooting…"
  reboot
else
  echo " When ready:  sudo reboot"
  echo " After reboot, verify with:  sudo ./verify-rustdesk-pi.sh"
  echo " Then connect from your RustDesk client by the ID above + the password."
fi
