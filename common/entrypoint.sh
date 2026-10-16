#!/usr/bin/env bash
# The shared entrypoint for EVERY Linux desktop sandbox in this repo.
#
# The flavor is described entirely by environment variables, so adding a desktop
# means adding a Containerfile that installs it and sets these — no new script:
#
#   DESKTOP_KIND=x11|wayland     which display server to bring up
#   DESKTOP_CMD="..."            how to start the WM / DE / compositor
#   DESKTOP_TERM="..."           a terminal, so the desktop is not empty
#   DESKTOP_ENV="K=V K=V"        extra env for the DESKTOP_CMD (optional)
#
# Order matters and is the same on both kinds: the D-Bus session bus + AT-SPI2
# MUST be up before agent-worker starts, because a job's app publishes its
# accessibility tree over D-Bus, and jobs inherit the worker's environment.
#
# The screen is served by the easystream daemon inside the guest (est:// H.264);
# there is no VNC/noVNC anywhere.
set -Eeuo pipefail

DESKTOP_KIND="${DESKTOP_KIND:-x11}"
DESKTOP_ENV="${DESKTOP_ENV:-}"
DESKTOP_CMD="${DESKTOP_CMD:-}"
DESKTOP_TERM="${DESKTOP_TERM:-}"
# DESKTOP_POST runs after the desktop is up (e.g. plasmashell, which needs a
# compositor to connect to first).
DESKTOP_POST="${DESKTOP_POST:-}"
DISPLAY_NUM="${DISPLAY_NUM:-99}"
GEOMETRY="${SCREEN_GEOMETRY:-1024x768x24}"
# X11 gets a display; Wayland must NOT have one, or a session that probes for an
# X display (gnome-session-check-accelerated, xrdb in startplasma-wayland)
# fails on a display that does not exist.
if [ "${DESKTOP_KIND:-x11}" = "x11" ]; then
  export DISPLAY=":${DISPLAY_NUM}"
  export XDG_SESSION_TYPE=x11
else
  # A non-wlroots Wayland compositor (kwin/mutter) starts Xwayland; easystream's
  # X11 backend needs DISPLAY to reach it. wlroots compositors have no Xwayland
  # by default, so there DISPLAY stays unset.
  if [ "${DESKTOP_WLROOTS:-1}" = "1" ]; then
    unset DISPLAY || true
  else
    export DISPLAY="${XWAYLAND_DISPLAY_NUM:-:0}"
  fi
  export XDG_SESSION_TYPE=wayland
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg}"
# Do NOT export WAYLAND_DISPLAY on an X11 desktop: the easystream daemon picks
# its backend by what is present, and a stray WAYLAND_DISPLAY made it choose the
# Wayland backend (whose input then failed) on an Xvfb screen. The Wayland path
# sets it from the real compositor socket in bring_up_wayland.
#
# A non-wlroots Wayland compositor (kwin/mutter) also gets NO WAYLAND_DISPLAY:
# easystream's Wayland backend needs the wlroots protocols, so it must fall back
# to X11 (through the compositor's Xwayland).
if [ "${DESKTOP_KIND:-x11}" = "wayland" ] && [ "${DESKTOP_WLROOTS:-1}" = "1" ]; then
  export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
fi
mkdir -p "$XDG_RUNTIME_DIR" "$HOME/workspace" /data
chmod 700 "$XDG_RUNTIME_DIR"
# Remove any stale compositor socket: a leftover wayland-1 makes the compositor
# pick wayland-1 while the worker (already started) inherited wayland-0.
rm -f "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null || true

cleanup() {
  kill "${WORKER_PID:-}" \
       "$(cat /tmp/at-spi-registry.pid 2>/dev/null)" \
       "$(cat /tmp/at-spi-bus.pid 2>/dev/null)" \
       "$(cat /tmp/dbus.pid 2>/dev/null)" \
       "$(cat /tmp/desktop.pid 2>/dev/null)" \
       "$(cat /tmp/term.pid 2>/dev/null)" \
       "$(cat /tmp/easystream.pid 2>/dev/null)" \
       "$(cat /tmp/xvfb.pid 2>/dev/null)" 2>/dev/null || true
}
trap cleanup TERM INT

# --- accessibility stack (D-Bus + AT-SPI2) ---------------------------------
bring_up_a11y() {
  echo "desktop[${DESKTOP_KIND}]: D-Bus session bus at ${DBUS_SESSION_BUS_ADDRESS:-?}"
  rm -f /tmp/agent-dbus
  # dbus-daemon wants `--print-pid` to be an OPEN FD, not a path: hand it fd 4.
  dbus-daemon --session --address="${DBUS_SESSION_BUS_ADDRESS}" \
    --fork --print-pid=4 4>/tmp/dbus.pid >/tmp/dbus.log 2>&1
  for _ in $(seq 1 50); do [ -S /tmp/agent-dbus ] && break; sleep 0.1; done
  echo "desktop[${DESKTOP_KIND}]: session bus up"

  # The SYSTEM bus: gnome-session and several KDE components refuse to start
  # without /run/dbus/system_bus_socket ("Failed to connect to system bus").
  # A container has none, so start one.
  mkdir -p /run/dbus
  if [ ! -S /run/dbus/system_bus_socket ]; then
    # A stale pid file (e.g. baked into the image) makes dbus-daemon refuse to
    # start ("The pid file /run/dbus/pid exists"), leaving /run/dbus empty.
    rm -f /run/dbus/pid
    timeout 10 dbus-daemon --system --fork --print-pid=4 4>/tmp/system-dbus.pid >/tmp/system-dbus.log 2>&1 \
      || echo "desktop[${DESKTOP_KIND}]: system bus start failed (continuing)" >&2
  fi
  echo "desktop[${DESKTOP_KIND}]: system bus step done"

  # The bus launcher proxies org.a11y.Bus; the registry aggregates the per-app
  # trees. Then flip the Status flags on so clients see the tree.
  echo "desktop[${DESKTOP_KIND}]: at-spi2 bus launcher + registry"
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

# --- the display server -----------------------------------------------------
bring_up_x11() {
  echo "desktop[x11]: Xvfb on ${DISPLAY} (${GEOMETRY})"
  Xvfb "${DISPLAY}" -screen 0 "${GEOMETRY}" -ac -nolisten tcp >/tmp/xvfb.log 2>&1 &
  echo $! > /tmp/xvfb.pid
  for _ in $(seq 1 100); do [ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ] && break; sleep 0.1; done
}

# bring_up_wayland waits for the compositor's socket and pins the output mode.
bring_up_wayland() {
  echo "desktop[wayland]: ${DESKTOP_CMD} (headless)"
  # shellcheck disable=SC2086
  env $DESKTOP_ENV $DESKTOP_CMD >/tmp/desktop.log 2>&1 &
  echo $! > /tmp/desktop.pid
  for _ in $(seq 1 100); do
    ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -q '^wayland' && break
    sleep 0.2
  done
  local sock; sock="$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep '^wayland' | head -1 || true)"
  if [ -z "$sock" ]; then
    echo "desktop[wayland]: compositor failed" >&2; cat /tmp/desktop.log >&2 || true; return 0
  fi
  # The compositor picks its own socket name; adopt it so agent-worker (started
  # next) and every job it spawns inherit the RIGHT WAYLAND_DISPLAY. Guessing
  # wayland-0 breaks as soon as the compositor chooses wayland-1.
  #
  # EXCEPT for a non-wlroots compositor (kwin/mutter): easystream's Wayland
  # backend speaks the wlroots protocols (wlr-screencopy / wlr-virtual-pointer)
  # which those do NOT implement, so capture/input would be dead. With no
  # WAYLAND_DISPLAY it falls back to its X11 backend, which works through the
  # compositor's Xwayland (DESKTOP_CMD starts one).
  if [ "${DESKTOP_WLROOTS:-1}" = "1" ]; then
    export WAYLAND_DISPLAY="$sock"
    echo "desktop[wayland]: WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"
  else
    echo "desktop[wayland]: non-wlroots; easystream will use the X11 backend"
  fi

  # A wlroots headless output always starts at 1280x720; wlr-randr is the only
  # way to change it. Retry until the output exists. NOT every compositor speaks
  # wlr-randr (kwin/mutter do not), so never let it block: `timeout` bounds each
  # attempt and the loop is bounded too.
  if [ "${DESKTOP_WLROOTS:-1}" != "1" ]; then
    echo "desktop[wayland]: not wlroots; skipping wlr-randr"
    return 0
  fi
  local geom="${SCREEN_GEOMETRY_WL:-1024x768}"
  for _ in $(seq 1 15); do
    local out; out="$(timeout -k 1 3 wlr-randr 2>/dev/null | awk '/^[^ ]/{print $1; exit}')"
    if [ -n "${out}" ]; then
      timeout -k 1 3 wlr-randr --output "${out}" --custom-mode "${geom}" >/tmp/wlr-randr.log 2>&1 \
        && { echo "desktop[wayland]: ${out} -> ${geom}"; break; }
    fi
    sleep 0.2
  done
}

# --- the desktop (WM/DE/compositor + a terminal) ----------------------------
bring_up_desktop() {
  if [ "$DESKTOP_KIND" = "x11" ]; then
    echo "desktop[x11]: ${DESKTOP_CMD}"
    # shellcheck disable=SC2086
    env $DESKTOP_ENV $DESKTOP_CMD >/tmp/desktop.log 2>&1 &
    echo $! > /tmp/desktop.pid
    sleep 2
  else
    # Wayland: portals + pipewire for screenshot/screencast, then the terminal.
    # Best-effort: a compositor that does not need them (kwin/mutter) must not
    # block on them, so each is backgrounded and its failure ignored.
    pipewire >/tmp/pipewire.log 2>&1 &
    echo $! > /tmp/pipewire.pid
    sleep 1
    if command -v xdg-desktop-portal-wlr >/dev/null 2>&1 && [ -x /usr/libexec/xdg-desktop-portal-wlr ]; then
      XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-wlroots}" /usr/libexec/xdg-desktop-portal-wlr \
        >/tmp/portal-wlr.log 2>&1 &
      echo $! > /tmp/portal-wlr.pid
    fi
    if [ -x /usr/libexec/xdg-desktop-portal ]; then
      /usr/libexec/xdg-desktop-portal >/tmp/portal.log 2>&1 &
      echo $! > /tmp/portal.pid
    fi
  fi

  # A non-wlroots Wayland compositor does not necessarily bring up Xwayland
  # on its own (kwin --virtual did not), and easystream's X11 backend needs it.
  # Start it BEFORE easystream and wait for its socket.
  if [ "${DESKTOP_KIND}" = "wayland" ] && [ "${DESKTOP_WLROOTS:-1}" != "1" ]; then
    if ! [ -S /tmp/.X11-unix/X0 ]; then
      # Xwayland takes no -screen (that is Xorg); its size comes from the
      # compositor's virtual output, which we already set to 1024x768.
      Xwayland :0 >/tmp/xwayland.log 2>&1 &
      echo $! > /tmp/xwayland.pid
      for _ in $(seq 1 50); do [ -S /tmp/.X11-unix/X0 ] && break; sleep 0.2; done
    fi
    # Xwayland comes up at 640x480; set the output to our resolution. The
    # compositor exposes it as the mode list, so xrandr can pick it.
    if [ -S /tmp/.X11-unix/X0 ]; then
      for _ in $(seq 1 15); do
        out="$(DISPLAY=:0 timeout 3 xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')"
        if [ -n "${out}" ]; then
          DISPLAY=:0 timeout 3 xrandr --output "${out}" --mode "${GEOMETRY%x24}" >/tmp/xrandr.log 2>&1 \
            && { echo "desktop[wayland]: Xwayland ${out} -> ${GEOMETRY%x24}"; break; }
        fi
        sleep 0.3
      done
    fi
    echo "desktop[wayland]: Xwayland $( [ -S /tmp/.X11-unix/X0 ] && echo up || echo MISSING )"
  fi

  if [ -n "${DESKTOP_TERM:-}" ]; then
    # shellcheck disable=SC2086
    $DESKTOP_TERM >/tmp/term.log 2>&1 &
    echo $! > /tmp/term.pid
  fi

  if [ -n "${DESKTOP_POST:-}" ]; then
    sleep 2
    # shellcheck disable=SC2086
    $DESKTOP_POST >/tmp/desktop-post.log 2>&1 &
    echo $! > /tmp/desktop-post.pid
  fi


  # easystream: a11y/input/capture/H.264 on 127.0.0.1:48078/48079. Started after
  # the display so its backend can bind.
  if command -v easystream >/dev/null 2>&1; then
    echo "desktop[${DESKTOP_KIND}]: easystream on :48079"
    EAZYSTREAM_HTTP_PORT=${EAZYSTREAM_HTTP_PORT:-48078} easystream serve >/tmp/easystream.log 2>&1 &
    echo $! > /tmp/easystream.pid
  fi
}

if [ "$DESKTOP_KIND" = "x11" ]; then bring_up_x11; fi
# On Wayland the compositor must exist BEFORE the worker starts: the worker (and
# every job) inherits WAYLAND_DISPLAY, and the compositor chooses the socket
# name. bring_up_wayland exports the real one.
if [ "$DESKTOP_KIND" = "wayland" ]; then bring_up_wayland; fi
bring_up_a11y

# agent-worker is the PID of record (it owns the container's lifetime). It is
# started AFTER the a11y stack so its jobs inherit a live AT-SPI session.
echo "desktop[${DESKTOP_KIND}]: agent-worker on :${WORKER_PORT:-48080}"
GOMEMLIMIT=${GOMEMLIMIT:-768MiB} agent-worker &
WORKER_PID=$!

bring_up_desktop &

wait "$WORKER_PID"
