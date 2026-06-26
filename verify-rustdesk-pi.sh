#!/usr/bin/env bash
#
# verify-rustdesk-pi.sh
# Confirms the headless RustDesk setup is fully working AFTER a reboot.
# Run as: sudo ./verify-rustdesk-pi.sh
#
set -uo pipefail
pass() { printf '\033[1;32m[PASS]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; FAILED=1; }
info() { printf '\033[1;36m[INFO]\033[0m %s\n' "$*"; }
FAILED=0

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0"; exit 1; }

echo "=== 1. Active X11 session on seat0 ==="
SID="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3!="" {print $1; exit}')"
if [[ -n "${SID:-}" ]]; then
  TYPE="$(loginctl show-session "$SID" -p Type --value 2>/dev/null)"
  ACTIVE="$(loginctl show-session "$SID" -p Active --value 2>/dev/null)"
  DISP="$(loginctl show-session "$SID" -p Display --value 2>/dev/null)"
  USERN="$(loginctl show-session "$SID" -p Name --value 2>/dev/null)"
  info "session=$SID user=$USERN Type=$TYPE Active=$ACTIVE Display=$DISP"
  [[ "$TYPE" == "x11" ]] && pass "Session type is x11" || fail "Session type is '$TYPE' (need x11 — RustDesk cannot capture Wayland)"
  [[ "$ACTIVE" == "yes" ]] && pass "Session is active" || fail "Session is not active"
else
  fail "No graphical login session found (auto-login not working — RustDesk has nothing to capture)"
fi
[[ -S /tmp/.X11-unix/X0 ]] && pass "X socket /tmp/.X11-unix/X0 present" || fail "No X0 socket — Xorg not running on :0"

echo "=== 2. Headless framebuffer has a real mode ==="
MODES="$(cat /sys/class/drm/card*-HDMI-A-*/modes 2>/dev/null | head -n3 | tr '\n' ' ')"
if [[ -n "$MODES" ]]; then pass "DRM HDMI modes present: $MODES"; else fail "No DRM HDMI modes (cmdline.txt video= not applied / wrong connector → black capture)"; fi

echo "=== 3. RustDesk service health ==="
if systemctl is-active --quiet rustdesk; then pass "rustdesk.service is active"; else fail "rustdesk.service is not active"; fi
if journalctl -u rustdesk -b 2>/dev/null | grep -qi "can't open display"; then
  fail "Log still shows \"Can't open display\" — session not being detected"
  journalctl -u rustdesk -b 2>/dev/null | grep -i display | tail -n3
else
  pass "No \"Can't open display\" in this boot's logs"
fi

echo "=== 4. Bound to the self-hosted server ==="
RD2=/root/.config/rustdesk/RustDesk2.toml
SRV="$(grep -E "custom-rendezvous-server|relay-server" "$RD2" 2>/dev/null | tr -d ' ' | tr '\n' ' ')"
if [[ -n "$SRV" ]]; then pass "Config points at: $SRV"; else fail "No custom server in $RD2 (it likely reverted to the PUBLIC rustdesk server — re-run setup)"; fi
# The live rendezvous_server must NOT be a public rs-*.rustdesk.com host.
if grep -qiE "rendezvous_server[[:space:]]*=[[:space:]]*'[^']*rustdesk\.com" "$RD2" 2>/dev/null; then
  fail "RustDesk2.toml rendezvous_server is a PUBLIC rustdesk.com host — custom server not in effect (re-run setup)"
fi
if journalctl -u rustdesk -b 2>/dev/null | grep -qiE "rs-.*\.rustdesk\.com"; then
  fail "Logs show the PUBLIC rustdesk rendezvous — custom server not taking effect"
else
  info "No public-server registration seen (good if your server config is correct)"
fi
# Permanent (unattended) password must be set, or unattended access won't work.
if grep -q "^password = '.\+'" /root/.config/rustdesk/RustDesk.toml 2>/dev/null; then
  pass "Permanent password is set"
else
  fail "Permanent password is empty in RustDesk.toml — set it with: sudo rustdesk --password '<pw>'"
fi

echo "=== 5. RustDesk identity ==="
RD_ID="$(rustdesk --get-id 2>/dev/null || true)"
[[ -n "$RD_ID" ]] && pass "RustDesk ID: $RD_ID" || fail "Could not read RustDesk ID"

echo
if [[ "$FAILED" -eq 0 ]]; then
  printf '\033[1;32mAll checks passed.\033[0m Connect from your client by ID %s + the permanent password.\n' "${RD_ID:-?}"
else
  printf '\033[1;31mSome checks failed.\033[0m See the [FAIL] lines above; re-run setup-rustdesk-pi.sh and reboot if needed.\n'
  exit 1
fi
