#!/usr/bin/env bash
# Build and push an easyworker GUI sandbox image.
#
#   ./agent-toolchain/desktop/build.sh openbox      # -> sandbox-x11     (Xvfb+openbox)
#   ./agent-toolchain/desktop/build.sh labwc        # -> sandbox-wayland (labwc)
#
# The two flavors are separate IMAGES (not two tags of one image): `openbox` is
# the X11 desktop (`sandbox-x11`) and `labwc` the Wayland desktop
# (`sandbox-wayland`), both tagged `debian-trixie` like the rest of the catalog.
#
# SELF-CONTAINED / RUN-ONLY: the image bakes the screen stack AND the
# easyworker binary, and its entrypoint starts both. The gateway runs only
# `sandbox-<lang>` images (easyworker as the sole ENTRYPOINT), so this image
# is NOT used as a sandbox base; deploy it as a plain Deployment
# (abc-protocol/deploy: worker-k8s/easyworker-desktop.yaml).
#
# Built FROM agent-toolchain/toolchain-base, so the base build tools come along.
#
# Prerequisites:
#   * dist/easyworker-linux-amd64    (scripts/build-all.sh)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"

# This repo holds EVERY Linux desktop sandbox — one subdirectory per flavor,
# each with its own Containerfile + entrypoint.sh. Adding a desktop means adding
# a directory (gnome/, kde/, ...) and a line to the flavor -> image table below.
FLAVOR="${1:-${FLAVOR:-openbox}}"
case "$FLAVOR" in
  openbox)      DEFAULT_NAME=sandbox-x11 ;;
  i3)           DEFAULT_NAME=sandbox-i3 ;;
  xfce4)        DEFAULT_NAME=sandbox-xfce ;;
  mate)         DEFAULT_NAME=sandbox-mate ;;
  cinnamon)     DEFAULT_NAME=sandbox-cinnamon ;;
  lxqt)         DEFAULT_NAME=sandbox-lxqt ;;
  labwc)        DEFAULT_NAME=sandbox-wayland ;;
  sway)         DEFAULT_NAME=sandbox-sway ;;
  cage)         DEFAULT_NAME=sandbox-cage ;;
  kiosk)        DEFAULT_NAME=sandbox-kiosk ;;
  niri)         DEFAULT_NAME=sandbox-niri ;;
  hyprland)     DEFAULT_NAME=sandbox-hyprland ;;
  *) echo "unknown flavor '$FLAVOR'" >&2; exit 2 ;;
esac

REGISTRY="${REGISTRY:-artifact.worker.svc.cluster.local}"
NAMESPACE="${NAMESPACE:-sandbox}"
NAME="${NAME:-$DEFAULT_NAME}"
TAG="${TAG:-debian-trixie}"
DEST="${REGISTRY}/${NAMESPACE}/${NAME}:${TAG}"
BUILDKIT="${BUILDKIT_ADDR:-tcp://buildkitd.agent.svc.cluster.local:1234}"
PROXY="${PROXY:-http://mihomo.develop.svc.cluster.local:7890}"
# Keep in-cluster traffic OFF the proxy (buildctl gRPC to buildkitd, the
# artifact registry). Both spellings: some tools read no_proxy, others NO_PROXY.
NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,.svc,.svc.cluster.local,.cluster.local,artifact.worker.svc.cluster.local,buildkitd.worker.svc.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"
no_proxy="${no_proxy:-$NO_PROXY}"
export NO_PROXY no_proxy
# Both guest binaries come from their GitHub releases, like every other sandbox
# image (no staged dist/). The desktop image bakes them in and its entrypoint
# starts them.
WORKER_VERSION="${WORKER_VERSION:-v0.1.0}"
EASYSTREAM_VERSION="${EASYSTREAM_VERSION:-v0.5.3}"
RELEASE_PROXY="${RELEASE_PROXY:-${PROXY:-http://mihomo.develop.svc.cluster.local:7890}}"
GH="https://github.com/easydev-org"
# The image is built FROM the generic toolchain base (build-essential etc.).
BASE_IMAGE="${BASE_IMAGE:-artifact.worker.svc.cluster.local/library/debian:trixie-slim}"

# Every flavor is a directory with a Containerfile; the entrypoint is SHARED
# (common/entrypoint.sh), parameterised by the DESKTOP_* env vars the
# Containerfile sets. Adding a desktop therefore means adding one directory.
FDIR="${DIR}/${FLAVOR}"
[ -e "${FDIR}/Containerfile" ] || { echo "missing ${FDIR}/Containerfile" >&2; exit 1; }
[ -e "${DIR}/common/entrypoint.sh" ] || { echo "missing common/entrypoint.sh" >&2; exit 1; }
BUILDCTL="${BUILDCTL:-$(command -v buildctl || echo /opt/tools/mise/installs/aqua-moby-buildkit/0.32.2/bin/buildctl)}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cp "${FDIR}/Containerfile" "${WORK}/Dockerfile"
# A flavor may ship its OWN entrypoint (e.g. kiosk: cage+chromium+lockdown);
# otherwise the shared common/entrypoint.sh is used, parameterised by DESKTOP_*.
if [ -f "${FDIR}/entrypoint.sh" ]; then
  ENTRY_SRC="${FDIR}/entrypoint.sh"
else
  ENTRY_SRC="${DIR}/common/entrypoint.sh"
fi
cp "${ENTRY_SRC}" "${WORK}/entrypoint.sh"
# The entrypoint is copied into the build context, so buildkit can reuse a
# stale COPY layer across builds. Bust it with the script's hash.
ENTRY_HASH="$(sha256sum "${ENTRY_SRC}" | cut -c1-16)"
# Content hash of both binaries: their COPY layers are keyed only on the file
# names, so a new release would otherwise be silently reused from cache.
BIN_HASH="$(cat "${WORK}/easyworker" "${WORK}/easystream" 2>/dev/null | sha256sum | cut -c1-16)"
# A flavor may also ship extra build-context files (e.g. kiosk/chrome-policy.json).
for f in "${FDIR}"/*; do
  case "$(basename "$f")" in
    Containerfile|entrypoint.sh) ;;  # handled above
    *) cp "$f" "${WORK}/" 2>/dev/null || true ;;
  esac
done
# Fetch the guest binaries from the releases (build time, via the proxy).
curl -fsSL -x "${RELEASE_PROXY}" -o "${WORK}/easyworker" \
  "${GH}/easyworker/releases/download/${WORKER_VERSION}/easyworker-linux-amd64"
curl -fsSL -x "${RELEASE_PROXY}" -o "${WORK}/easystream" \
  "${GH}/easystream/releases/download/${EASYSTREAM_VERSION}/easystream-linux-amd64"
chmod 755 "${WORK}/easyworker" "${WORK}/easystream"

echo "Building ${NAME}:${TAG} (flavor=${FLAVOR}, buildkitd=${BUILDKIT})"
"${BUILDCTL}" --addr "${BUILDKIT}" build \
  --frontend dockerfile.v0 \
  --local "context=${WORK}" \
  --local "dockerfile=${WORK}" \
  --opt "filename=Dockerfile" \
  --opt "build-arg:BASE_IMAGE=${BASE_IMAGE}" \
  --opt "build-arg:ENTRY_HASH=${ENTRY_HASH}" \
  --opt "build-arg:BIN_HASH=${BIN_HASH}" \
  --opt "build-arg:HTTP_PROXY=${PROXY}" \
  --opt "build-arg:HTTPS_PROXY=${PROXY}" \
  --opt "build-arg:NO_PROXY=localhost,127.0.0.1,.svc.cluster.local,.svc,.nip.io,10.199.64.20" \
  --output "type=image,name=${DEST},push=true,registry.insecure=true,compression=zstd" \
  --progress plain

echo "Pushing to ${DEST}"
echo "pushed by buildctl: ${DEST}"
