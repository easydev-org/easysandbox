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
# Two stages, because they move at different speeds:
#
#   base    debian + apt desktop + the shared entrypoint. Expensive (minutes),
#           changes only when a desktop package or the entrypoint does.
#   worker  FROM that base, plus easyworker and easystream. Cheap (one COPY),
#           and this is what normally gets rebuilt - the binaries come from
#           their own releases and change often.
#   all     both, worker on top of the base built in the same run.
#
# STAGE=worker against an existing base is the common case: "give me the image
# we already trust with the newest easyworker". Neither binary is a build-time
# dependency of the desktop, so that is a layer, not a rebuild.
STAGE="${STAGE:-all}"
if [ "${1:-}" = "--stage" ]; then STAGE="${2:?--stage needs base|worker|all}"; shift 2; fi
case "${STAGE}" in base|worker|all) ;; *) echo "STAGE must be base, worker or all (got '${STAGE}')" >&2; exit 2 ;; esac

FLAVOR="${1:-${FLAVOR:-openbox}}"
# Seven flavors: four X11, three Wayland. X11 keeps the desktops that have no
# Wayland session of their own (i3, openbox, cinnamon, xfce4); Wayland holds the
# wlroots ones (sway, labwc, cage).
case "$FLAVOR" in
  # X11
  openbox)      DEFAULT_NAME=sandbox-x11 ;;
  i3)           DEFAULT_NAME=sandbox-i3 ;;
  cinnamon)     DEFAULT_NAME=sandbox-cinnamon ;;
  xfce4)        DEFAULT_NAME=sandbox-xfce ;;
  # Wayland
  labwc)        DEFAULT_NAME=sandbox-wayland ;;
  sway)         DEFAULT_NAME=sandbox-sway ;;
  cage)         DEFAULT_NAME=sandbox-cage ;;
  *) echo "unknown flavor '$FLAVOR' (x11: openbox i3 cinnamon xfce4 / wayland: labwc sway cage)" >&2; exit 2 ;;
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
# v0.4.0 IS THE FIRST RELEASE WITH THE SCRIPT ENGINE BAKED IN. Before it the worker shelled out to a
# separate easyscript daemon; from it the engine is part of this binary, and the contract changed with
# it: `lang` is required, `env` is gone, and the dataflow RPCs no longer exist.
#
# AN IMAGE BUILT FROM AN OLDER TAG WOULD STILL START and still answer Info — which is exactly why the
# version is pinned here rather than floating: the mismatch shows up as every command being refused for
# a missing language, on a sandbox whose worker reported itself healthy.
WORKER_VERSION="${WORKER_VERSION:-v0.4.1}"
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

BASE_NAME="${BASE_NAME:-sandbox-base-${NAME#sandbox-}}"
BASE_DEST="${REGISTRY}/${NAMESPACE}/${BASE_NAME}:${TAG}"
NO_PROXY_OPT="localhost,127.0.0.1,.svc.cluster.local,.svc,.nip.io,10.199.64.20"

echo "stage=${STAGE} flavor=${FLAVOR} base=${BASE_DEST} image=${DEST}"

# ---------------------------------------------------------------------------
# stage: base
# ---------------------------------------------------------------------------
build_base() {
  local work
  work="$(mktemp -d)"
  cp "${FDIR}/Containerfile" "${work}/Dockerfile"

  # A flavor may ship its OWN entrypoint (kiosk did, before it was dropped);
  # otherwise the shared common/entrypoint.sh is used, parameterised by the
  # DESKTOP_* env vars the flavor's Containerfile sets.
  local entry_src
  if [ -f "${FDIR}/entrypoint.sh" ]; then
    entry_src="${FDIR}/entrypoint.sh"
  else
    entry_src="${DIR}/common/entrypoint.sh"
  fi
  cp "${entry_src}" "${work}/entrypoint.sh"
  local entry_hash
  entry_hash="$(sha256sum "${entry_src}" | cut -c1-16)"

  # Any other file the flavor wants in the context (none today, kept because
  # the pattern is what made kiosk's chrome policy work).
  local f
  for f in "${FDIR}"/*; do
    case "$(basename "$f")" in
      Containerfile|entrypoint.sh) ;;
      *) cp "$f" "${work}/" 2>/dev/null || true ;;
    esac
  done

  echo "Building base ${BASE_NAME}:${TAG} (flavor=${FLAVOR})"
  "${BUILDCTL}" --addr "${BUILDKIT}" build \
    --frontend dockerfile.v0 \
    --local "context=${work}" \
    --local "dockerfile=${work}" \
    --opt "filename=Dockerfile" \
    --opt "build-arg:BASE_IMAGE=${BASE_IMAGE}" \
    --opt "build-arg:ENTRY_HASH=${entry_hash}" \
    --opt "build-arg:HTTP_PROXY=${PROXY}" \
    --opt "build-arg:HTTPS_PROXY=${PROXY}" \
    --opt "build-arg:NO_PROXY=${NO_PROXY_OPT}" \
    --output "type=image,name=${BASE_DEST},push=true,registry.insecure=true,compression=zstd" \
    --progress plain
  rm -rf "${work}"
  echo "pushed base: ${BASE_DEST}"
}

# ---------------------------------------------------------------------------
# stage: worker
# ---------------------------------------------------------------------------
build_worker() {
  local work
  work="$(mktemp -d)"
  cp "${DIR}/Containerfile.worker" "${work}/Dockerfile"

  # Fetch the guest binaries from their releases (build time, via the proxy).
  # Nothing is vendored, so the version is the only thing that decides what is
  # in the image.
  curl -fsSL -x "${RELEASE_PROXY}" -o "${work}/easyworker" \
    "${GH}/easyworker/releases/download/${WORKER_VERSION}/easyworker-linux-amd64"
  curl -fsSL -x "${RELEASE_PROXY}" -o "${work}/easystream" \
    "${GH}/easystream/releases/download/${EASYSTREAM_VERSION}/easystream-linux-amd64"
  chmod 755 "${work}/easyworker" "${work}/easystream"

  # Their COPY layers are keyed on the file NAMES only, so a new release with the
  # same names would be served from cache. Hash the content to bust it.
  local bin_hash
  bin_hash="$(cat "${work}/easyworker" "${work}/easystream" | sha256sum | cut -c1-16)"

  # The base always comes from the registry, not from a local build: with
  # STAGE=worker that is the only source, and with STAGE=all build_base has just
  # pushed it. Either way there is one definition of "the base for this flavor".
  echo "Building ${NAME}:${TAG} from ${BASE_DEST} (worker=${WORKER_VERSION} easystream=${EASYSTREAM_VERSION})"
  "${BUILDCTL}" --addr "${BUILDKIT}" build \
    --frontend dockerfile.v0 \
    --local "context=${work}" \
    --local "dockerfile=${work}" \
    --opt "filename=Dockerfile" \
    --opt "build-arg:BASE_IMAGE=${BASE_DEST}" \
    --opt "build-arg:BIN_HASH=${bin_hash}" \
    --opt "build-arg:HTTP_PROXY=${PROXY}" \
    --opt "build-arg:HTTPS_PROXY=${PROXY}" \
    --opt "build-arg:NO_PROXY=${NO_PROXY_OPT}" \
    --output "type=image,name=${DEST},push=true,registry.insecure=true,compression=zstd" \
    --progress plain
  rm -rf "${work}"
  echo "pushed: ${DEST}"
}

case "${STAGE}" in
  base)   build_base ;;
  worker) build_worker ;;
  all)    build_base; build_worker ;;
esac
