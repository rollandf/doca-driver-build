#!/bin/bash
# Host-side driver for the doca-kernel-support POC.
#
#   ./poc.sh dryrun   # stage + --dry-run, no compiling
#   ./poc.sh build    # real module build, harvests packages into poc/dks/out/
#
# Nothing is copied into the repo: the vendor script and the OFED tarballs are
# bind-mounted read-only from wherever they already live.
set -euo pipefail

MODE="${1:-dryrun}"
OS="${2:-${OS:-ubuntu}}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

case "$OS" in
ubuntu)
	DEFAULT_IMAGE="docker.io/library/ubuntu:24.04"
	DEFAULT_KVER="6.8.0-139-generic"
	DEFAULT_TARBALL="/ofed/MLNX_OFED_SRC-debian-26.07-0.7.7.0.tgz"
	RUNNER="run-ubuntu.sh"
	;;
ubuntu-baseline)
	DEFAULT_IMAGE="docker.io/library/ubuntu:24.04"
	DEFAULT_KVER="6.8.0-139-generic"
	DEFAULT_TARBALL="/ofed/MLNX_OFED_SRC-debian-26.07-0.7.7.0.tgz"
	RUNNER="run-ubuntu-baseline.sh"
	;;
rhel)
	DEFAULT_IMAGE="docker.io/library/almalinux:9"
	DEFAULT_KVER="5.14.0-687.42.1.el9_8.x86_64"
	DEFAULT_TARBALL="/ofed/MLNX_OFED_SRC-26.07-0.7.7.0.tgz"
	RUNNER="run-rhel.sh"
	;;
rhel-baseline)
	DEFAULT_IMAGE="docker.io/library/almalinux:9"
	DEFAULT_KVER="5.14.0-687.42.1.el9_8.x86_64"
	DEFAULT_TARBALL="/ofed/MLNX_OFED_SRC-26.07-0.7.7.0.tgz"
	RUNNER="run-rhel-baseline.sh"
	;;
*)
	echo "usage: $0 [dryrun|build] [ubuntu|ubuntu-baseline|rhel|rhel-baseline]" >&2
	exit 2
	;;
esac

# doca-kernel-support + resources/find-provides.ksyms, as extracted from
# doca-extra-2607.0.10-1.el9.noarch.rpm.
VENDOR="${VENDOR:-/tmp/dx/opt/mellanox/doca/tools}"
OFED_DIR="${OFED_DIR:-$REPO/ofed}"
IMAGE="${IMAGE:-$DEFAULT_IMAGE}"
TARGET_KVER="${TARGET_KVER:-$DEFAULT_KVER}"
TARBALL="${TARBALL:-$DEFAULT_TARBALL}"

if [ ! -x "$VENDOR/doca-kernel-support" ]; then
	echo "error: no doca-kernel-support at $VENDOR" >&2
	echo "extract it with: rpm2cpio doca-extra-*.rpm | cpio -idmv" >&2
	exit 2
fi

# Per-OS output dir so deb and rpm runs do not clobber each other's logs.
OUT="$HERE/out-$OS"
mkdir -p "$OUT"

exec podman run --rm \
	-v "$HERE:/poc:ro" \
	-v "$VENDOR:/vendor:ro" \
	-v "$OFED_DIR:/ofed:ro" \
	-v "$OUT:/out" \
	-e "MODE=$MODE" \
	-e "TARGET_KVER=$TARGET_KVER" \
	-e "TARBALL=$TARBALL" \
	-e "KEEP=${KEEP:-}" \
	-e "PATCH_STRIP=${PATCH_STRIP:-1}" \
	-e "SIGN_MODULES=${SIGN_MODULES:-0}" \
	-e "SPOOF_DISTRO=${SPOOF_DISTRO:-}" \
	"$IMAGE" \
	bash "/poc/$RUNNER"
