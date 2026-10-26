# easysandbox

The **Linux desktop sandbox images**: one self-contained image per desktop
environment, each with the screen stack, the easystream daemon and the
easyworker baked in.

One repository holds them all — **adding a desktop means adding a subdirectory**
with its own `Containerfile`, plus a line in the flavor → image table in
`build.sh` and in the two workflow matrices.

Seven flavors, four X11 and three Wayland:

```
                 X11
openbox/          Xvfb + openbox        -> sandbox-x11
i3/               Xvfb + i3             -> sandbox-i3
cinnamon/         Xvfb + cinnamon       -> sandbox-cinnamon
xfce4/            Xvfb + xfce4          -> sandbox-xfce

                 Wayland
labwc/            labwc (wlroots)       -> sandbox-wayland
sway/             sway (wlroots)        -> sandbox-sway
cage/             cage + foot           -> sandbox-cage   (single-app kiosk)
```

The X11 half is not a preference: i3, openbox, cinnamon and xfce4 have no
Wayland session of their own. The Wayland half is wlroots, which drives
`wlr-virtual-pointer` and `wlr-screencopy` directly.

## Two stages

Every flavor is built as **two images**, because the halves move at different
speeds:

```
stage 1   <flavor>/Containerfile        debian + apt desktop + entrypoint
          -> sandbox-base-<flavor>      expensive (minutes), changes rarely

stage 2   Containerfile.worker          FROM that base
          -> sandbox-<flavor>           + easyworker + easystream
                                        cheap (one COPY), changes often
```

The desktop is not a build-time dependency of the two binaries, and the two
binaries are separate GitHub releases on their own cadence. Keeping them in the
base meant every daemon bump paid for a full apt run across seven desktops.
Now it is a layer.

```sh
./build.sh --stage base   openbox     # -> sandbox-base-x11
./build.sh --stage worker openbox     # -> sandbox-x11, on top of that base
./build.sh                openbox     # both (STAGE=all)
```

`STAGE=worker` against a base you already trust is the normal case: "give me
the image we ship, with today's easyworker".

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
