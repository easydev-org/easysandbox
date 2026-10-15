#!/usr/bin/env bash
# Build and push an agent-worker GUI sandbox image.
#
#   ./agent-toolchain/desktop/build.sh openbox      # -> sandbox-x11     (Xvfb+openbox)
#   ./agent-toolchain/desktop/build.sh labwc        # -> sandbox-wayland (labwc)
#
# The two flavors are separate IMAGES (not two tags of one image): `openbox` is
# the X11 desktop (`sandbox-x11`) and `labwc` the Wayland desktop
# (`sandbox-wayland`), both tagged `debian-trixie` like the rest of the catalog.
#
# SELF-CONTAINED / RUN-ONLY: the image bakes the screen stack AND the
# agent-worker binary, and its entrypoint starts both. The gateway runs only
# `sandbox-<lang>` images (agent-worker as the sole ENTRYPOINT), so this image
# is NOT used as a sandbox base; deploy it as a plain Deployment
# (abc-protocol/deploy: worker-k8s/agent-worker-desktop.yaml).
#
# Built FROM agent-toolchain/toolchain-base, so the base build tools come along.
#
# Prerequisites:
#   * dist/agent-worker-linux-amd64    (scripts/build-all.sh)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"

# This repo holds EVERY Linux desktop sandbox — one subdirectory per flavor,
# each with its own Containerfile + entrypoint.sh. Adding a desktop means adding
# a directory (gnome/, kde/, ...) and a line to the flavor -> image table below.
FLAVOR="${1:-${FLAVOR:-openbox}}"
case "$FLAVOR" in
  # X11
  openbox)      DEFAULT_NAME=sandbox-x11 ;;
  i3)           DEFAULT_NAME=sandbox-i3 ;;
  xfce4)        DEFAULT_NAME=sandbox-xfce ;;
  mate)         DEFAULT_NAME=sandbox-mate ;;
  cinnamon)     DEFAULT_NAME=sandbox-cinnamon ;;
  lxqt)         DEFAULT_NAME=sandbox-lxqt ;;
  gnome-x11)    DEFAULT_NAME=sandbox-gnome-x11 ;;
  kde-x11)      DEFAULT_NAME=sandbox-kde-x11 ;;
  # Wayland
  labwc)        DEFAULT_NAME=sandbox-wayland ;;
  sway)         DEFAULT_NAME=sandbox-sway ;;
  cage)         DEFAULT_NAME=sandbox-cage ;;
  niri)         DEFAULT_NAME=sandbox-niri ;;
  hyprland)     DEFAULT_NAME=sandbox-hyprland ;;
  cosmic)       DEFAULT_NAME=sandbox-cosmic ;;
  gnome-wayland) DEFAULT_NAME=sandbox-gnome ;;
  kde-wayland)  DEFAULT_NAME=sandbox-kde ;;
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
EASYSTREAM_VERSION="${EASYSTREAM_VERSION:-v0.1.0}"
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
cp "${DIR}/common/entrypoint.sh" "${WORK}/entrypoint.sh"
# Fetch the guest binaries from the releases (build time, via the proxy).
curl -fsSL -x "${RELEASE_PROXY}" -o "${WORK}/agent-worker" \
  "${GH}/easyworker/releases/download/${WORKER_VERSION}/agent-worker-linux-amd64"
curl -fsSL -x "${RELEASE_PROXY}" -o "${WORK}/easystream" \
  "${GH}/easystream/releases/download/${EASYSTREAM_VERSION}/easystream-linux-amd64"
chmod 755 "${WORK}/agent-worker" "${WORK}/easystream"

echo "Building ${NAME}:${TAG} (flavor=${FLAVOR}, buildkitd=${BUILDKIT})"
"${BUILDCTL}" --addr "${BUILDKIT}" build \
  --frontend dockerfile.v0 \
  --local "context=${WORK}" \
  --local "dockerfile=${WORK}" \
  --opt "filename=Dockerfile" \
  --opt "build-arg:BASE_IMAGE=${BASE_IMAGE}" \
  --opt "build-arg:HTTP_PROXY=${PROXY}" \
  --opt "build-arg:HTTPS_PROXY=${PROXY}" \
  --opt "build-arg:NO_PROXY=localhost,127.0.0.1,.svc.cluster.local,.svc,.nip.io,10.199.64.20" \
  --output "type=oci,dest=${WORK}/image.oci,compression=zstd" \
  --progress plain

echo "Pushing to ${DEST}"
mkdir -p "${WORK}/oci" && tar -xf "${WORK}/image.oci" -C "${WORK}/oci"
skopeo copy --src-tls-verify=false --dest-tls-verify=false \
  --dest-creds "${FORGEJO_USER:-root}:${FORGEJO_PASS:-devpassword}" \
  "oci:${WORK}/oci" "docker://${DEST}"

echo "Verifying push:"
skopeo inspect --creds "${FORGEJO_USER:-root}:${FORGEJO_PASS:-devpassword}" \
  --tls-verify=false "docker://${DEST}" >/dev/null 2>&1 \
  && echo "OK ${DEST}" \
  || echo "inspect failed for ${DEST} (image may still be present)"
