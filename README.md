# easysandbox

The **Linux desktop sandbox images**: one self-contained image per desktop
environment, each with the screen stack, the easystream daemon and the
agent-worker baked in.

One repository holds them all — **adding a desktop means adding a subdirectory**
(`gnome/`, `kde/`, …) with its own `Containerfile` + `entrypoint.sh`, plus a line
in the flavor → image table in `build.sh`.

```
build.sh          build + push any flavor (fetches the guest binaries)
openbox/          Xvfb + openbox        -> sandbox-x11
labwc/            labwc (wlroots)       -> sandbox-wayland
                  gnome/ (planned)      -> sandbox-gnome
                  kde/   (planned)      -> sandbox-kde
```

The other OSes live in their own repos: `easysandbox-windows`,
`easysandbox-macos`, `easysandbox-android`.

## Guest binaries

Both come from GitHub **releases** at build time — nothing is vendored:

| binary | from |
|---|---|
| `agent-worker` | `easydev-org/easyworker` release `WORKER_VERSION` |
| `easystream` | `easydev-org/easystream` release `EASYSTREAM_VERSION` |

## Build

```sh
./build.sh openbox     # -> sandbox-x11
./build.sh labwc       # -> sandbox-wayland
# WORKER_VERSION / EASYSTREAM_VERSION default to v0.1.0; TAG defaults to debian-trixie
```

Every desktop runs at 1024x768, matching the Windows/macOS/Android sandboxes.
The screen is served by the easystream daemon inside the guest (est:// H.264),
**not** by VNC/noVNC.
