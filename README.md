# easysandbox

The **Linux desktop sandbox images**: one self-contained image per desktop
environment, each with the screen stack, the easystream daemon and the
easyworker baked in.

One repository holds them all — **adding a desktop means adding a subdirectory**
(`gnome/`, `kde/`, …) with its own `Containerfile` + `entrypoint.sh`, plus a line
in the flavor → image table in `build.sh`.

```
build.sh          build + push any flavor (fetches the guest binaries)
openbox/          Xvfb + openbox        -> sandbox-x11
labwc/            labwc (wlroots)       -> sandbox-wayland
cage/             cage + foot           -> sandbox-cage   (single-app kiosk)
kiosk/            cage + chromium       -> sandbox-kiosk  (LOCKED-DOWN browser)
                  gnome/ (planned)      -> sandbox-gnome
                  kde/   (planned)      -> sandbox-kde
```

The other OSes live in their own repos: `easysandbox-windows`,
`easysandbox-macos`, `easysandbox-android`.

## Guest binaries

Both come from GitHub **releases** at build time — nothing is vendored:

| binary | from |
|---|---|
| `easyworker` | `easydev-org/easyworker` release `WORKER_VERSION` |
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

## kiosk — the locked-down browser sandbox

`sandbox-kiosk` is not a desktop: it is a **single-app browser kiosk**. `cage`
(the Wayland kiosk compositor) runs exactly **one** client — `chromium` —
full-screen, with Chrome's own UI (tabs / omnibox) visible. There is **no
window manager, no launcher, no panel and no terminal**, so nothing can spawn a
second application.

On top of cage's single-app guarantee the image adds defence in depth:

| layer | what it does |
|---|---|
| **compositor** | `cage` runs one client; no WM, no keybindings, no launcher |
| **image** | every user-launchable app except chromium is removed — terminals (`foot`, `xterm`, …), file managers, editors, and all package managers / downloaders / interpreters (`apt`, `curl`, `python3`, `node`, …) |
| **Chrome policy** | `/etc/chromium/policies/managed/kiosk.json` disables DevTools, downloads, `chrome://settings|flags|extensions|downloads|…`, incognito, the password manager and more |
| **deployment** | `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false` (`deploy/kiosk.yaml`) |

The guest is reachable **only** through the easystream daemon — `est://` (video
+ input on `:48079`) and `/a11y/*` (the accessibility/input HTTP API on `:48078`).
There is no shell, no SSH and no VNC.

### Run it

```sh
./build.sh kiosk EASYSTREAM_VERSION=v0.2.1   # -> sandbox-kiosk:debian-trixie
kubectl apply -f kiosk/deploy/kiosk.yaml
```

Then open the web UI. **It must be served over HTTPS** (or localhost): the H.264
decoder (WebCodecs `VideoDecoder`) only exists in a *secure context*, so a plain
`http://` URL shows `no WebCodecs (need HTTPS)`. Put the `kiosk-web` Service
behind a TLS-terminating gateway and browse to it.

### Differences from `cage/`

`cage/` is the generic single-app kiosk (it runs `foot`, a terminal — useful
when the app you want to drive is a shell). `kiosk/` is the **browser** variant:
chromium, locked down, with a Chrome enterprise policy and a stripped image.
