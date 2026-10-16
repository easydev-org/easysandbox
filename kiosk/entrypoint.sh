#!/usr/bin/env bash
# kiosk desktop entrypoint — cage (Wayland kiosk) + chromium (fullscreen) + easystream.
#
#   cage (headless)  ->  chromium --start-fullscreen   the ONLY app
#   easystream :48079 (est) / :48078 (http)            the ONLY viewer/input surface
#
# ORDER: the a11y bus, then cage (which owns the Wayland socket), then
# easystream — easystream captures via wlr-screencopy and injects input via
# wlr-virtual-*, so it MUST start after the compositor's socket exists or it
# fails forever ("capture wl_display_connect / screencopy failed").
set -Eeuo pipefail

EST_PORT="${EAZYSTREAM_PORT:-48079}"
EST_HTTP_PORT="${EAZYSTREAM_HTTP_PORT:-48078}"
SCREEN_W="${SCREEN_GEOMETRY%%x*}"
SCREEN_H="${SCREEN_GEOMETRY##*x}"
export EAZYSTREAM_SCREEN_W="$SCREEN_W" EAZYSTREAM_SCREEN_H="$SCREEN_H"
KIOSK_URL="${KIOSK_URL:-about:blank}"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-wlroots}"
mkdir -p "$XDG_RUNTIME_DIR" "$HOME/workspace" /data
chmod 700 "$XDG_RUNTIME_DIR"

cleanup() {
  kill "${EST_PID:-}" \
       "$(cat /tmp/at-spi-registry.pid 2>/dev/null)" \
       "$(cat /tmp/at-spi-bus.pid 2>/dev/null)" \
       "$(cat /tmp/dbus.pid 2>/dev/null)" \
       "$(cat /tmp/cage.pid 2>/dev/null)" \
       "$(cat /tmp/pipewire.pid 2>/dev/null)" \
       "$(cat /tmp/portal-wlr.pid 2>/dev/null)" \
       "$(cat /tmp/portal.pid 2>/dev/null)" 2>/dev/null || true
}
trap cleanup TERM INT

# --- 1. accessibility stack (D-Bus + AT-SPI2) -----------------------------
bring_up_a11y() {
  echo "kiosk: starting D-Bus session bus at ${DBUS_SESSION_BUS_ADDRESS:-?}"
  rm -f /tmp/agent-dbus
  dbus-daemon --session --address="${DBUS_SESSION_BUS_ADDRESS}" \
    --fork --print-pid=4 4>/tmp/dbus.pid >/tmp/dbus.log 2>&1
  for _ in $(seq 1 50); do [ -S /tmp/agent-dbus ] && break; sleep 0.1; done
  /usr/libexec/at-spi-bus-launcher --launch-immediately >/tmp/at-spi-bus.log 2>&1 &
  echo $! > /tmp/at-spi-bus.pid
  sleep 1
  /usr/libexec/at-spi2-registryd >/tmp/at-spi-registry.log 2>&1 &
  echo $! > /tmp/at-spi-registry.pid
  sleep 1
  for prop in IsEnabled ScreenReaderEnabled; do
    dbus-send --session --print-reply --dest=org.a11y.Bus /org/a11y/bus \
      org.freedesktop.DBus.Properties.Set \
      string:org.a11y.Status string:"$prop" variant:boolean:true >/dev/null 2>&1 || true
  done
}
bring_up_a11y

# --- 2. portal stack (screenshot/screencast for a11y + computer-screenshot)
pipewire >/tmp/pipewire.log 2>&1 &
echo $! > /tmp/pipewire.pid
sleep 1
XDG_CURRENT_DESKTOP=wlroots /usr/libexec/xdg-desktop-portal-wlr >/tmp/portal-wlr.log 2>&1 &
echo $! > /tmp/portal-wlr.pid
/usr/libexec/xdg-desktop-portal >/tmp/portal.log 2>&1 &
echo $! > /tmp/portal.pid

# --- 3. cage: the kiosk compositor (runs exactly one client) --------------
WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=pixman \
  cage -- chromium \
    --no-sandbox \
    --test-type \
    --disable-gpu \
    --force-renderer-accessibility \
    --start-fullscreen \
    --no-first-run \
    --noerrdialogs \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --overscroll-history-navigation=0 \
    --disable-pinch \
    --incognito \
    --user-data-dir=/tmp/chromium-profile \
    "$KIOSK_URL" >/tmp/cage.log 2>&1 &
echo $! > /tmp/cage.pid

# Wait for the compositor's Wayland socket.
for _ in $(seq 1 150); do
  ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -q '^wayland' && break
  sleep 0.2
done
WL_SOCK="$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep '^wayland' | head -1 || true)"
if [ -z "$WL_SOCK" ]; then
  echo "kiosk: cage failed to start" >&2
  cat /tmp/cage.log >&2 || true
  exit 1
fi

# Force the headless output to the target geometry.
GEOM="${SCREEN_GEOMETRY:-1920x1080}"
sleep 2
for _ in $(seq 1 40); do
  OUT="$(wlr-randr 2>/dev/null | awk '/^[^ ]/{print $1; exit}')"
  if [ -n "${OUT}" ]; then
    wlr-randr --output "${OUT}" --custom-mode "${GEOM}" >/tmp/wlr-randr.log 2>&1
    CUR="$(wlr-randr 2>/dev/null | grep -m1 'current')"
    case "$CUR" in *"$GEOM"*) echo "kiosk: output ${OUT} = ${GEOM}"; break;; esac
  fi
  sleep 0.5
done

# --- 4. easystream daemon (est + HTTP/a11y) — the ONLY surface ------------
# Started AFTER the compositor so capture/input bind to a live Wayland socket.
echo "kiosk: easystream est=:${EST_PORT} http=:${EST_HTTP_PORT} (screen ${SCREEN_W}x${SCREEN_H})"
EAZYSTREAM_PORT="$EST_PORT" EAZYSTREAM_HTTP_PORT="$EST_HTTP_PORT" \
  easystream serve >/tmp/easystream.log 2>&1 &
EST_PID=$!

echo "kiosk: desktop up"
wait "$EST_PID"
