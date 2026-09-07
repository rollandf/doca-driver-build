#!/bin/bash
# Builds the RHEL "sources" (driver-src) image -- the variant that now runs
# doca-kernel-support instead of install.pl.
#
# MUST run on a machine registered with subscription-manager. UBI's public repos
# cannot supply kernel-rpm-macros, bison, flex, createrepo_c or
# kernel-abi-stablelists, all of which driver-src installs so that the runtime
# build never has to reach the network. podman on a registered RHEL host mounts
# the host entitlement certs and redhat.repo into the build automatically, which
# is what makes the full RHEL repos visible inside the UBI base image.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

D_OS="${D_OS:-rhel9.8}"
BASE_IMAGE="${BASE_IMAGE:-registry.access.redhat.com/ubi9/ubi:9.8}"
OFED_VERSION="${OFED_VERSION:-26.07-0.7.7.0}"
DOCA_VERSION="${DOCA_VERSION:-3.5.0}"
ARCH="${ARCH:-$(uname -m)}"
TAG="${TAG:-doca-driver:local-${D_OS}-src}"
TARGET="${TARGET:-driver-src}"

# Prefer a local tarball so the build does not pull 71MB every time, but fall
# back to the published URL. Note this is the RPM archive: the Ubuntu build uses
# the separate MLNX_OFED_SRC-debian-* one.
LOCAL_TGZ="ofed/MLNX_OFED_SRC-${OFED_VERSION}.tgz"
if [ -f "$LOCAL_TGZ" ]; then
	OFED_URL_PATH="$LOCAL_TGZ"
	echo "### sources: local ${LOCAL_TGZ}"
else
	OFED_URL_PATH="https://linux.mellanox.com/public/repo/doca/${DOCA_VERSION}/SOURCES/mlnx_ofed/MLNX_OFED_SRC-${OFED_VERSION}.tgz"
	echo "### sources: ${OFED_URL_PATH}"
fi

# Fail here rather than 300 lines into a dnf transaction.
if ! subscription-manager identity >/dev/null 2>&1; then
	echo "ERROR: this host is not registered. Run 'subscription-manager register' first." >&2
	echo "       Without entitlements the driver-src stage cannot install" >&2
	echo "       kernel-rpm-macros, bison, flex, createrepo_c, kernel-abi-stablelists." >&2
	exit 1
fi
if ! compgen -G "/etc/pki/entitlement/*.pem" >/dev/null; then
	echo "ERROR: /etc/pki/entitlement holds no certs despite registration." >&2
	echo "       Try 'subscription-manager refresh'." >&2
	exit 1
fi

echo "### base:   ${BASE_IMAGE}"
echo "### D_OS:   ${D_OS}   arch: ${ARCH}"
echo "### doca:   ${DOCA_VERSION}   ofed: ${OFED_VERSION}"
echo "### target: ${TARGET}   tag: ${TAG}"

# --build-context rhsm=... satisfies the driver-src bind mount. On podman the host
# entitlements arrive on their own too, but the Dockerfile names the context
# explicitly so the same file works under plain docker.
set -x
podman build \
	-f RHEL_Dockerfile \
	--target "${TARGET}" \
	--ignorefile poc/dks/dockerignore \
	--build-context rhsm=/etc/pki/entitlement \
	-t "${TAG}" \
	--build-arg D_BASE_IMAGE="${BASE_IMAGE}" \
	--build-arg D_OS="${D_OS}" \
	--build-arg D_ARCH="${ARCH}" \
	--build-arg D_OFED_VERSION="${OFED_VERSION}" \
	--build-arg D_DOCA_VERSION="${DOCA_VERSION}" \
	--build-arg D_CONTAINER_VER=0 \
	--build-arg D_KERNEL_VER= \
	--build-arg D_OFED_URL_PATH="${OFED_URL_PATH}" \
	.
set +x

echo
echo "### built ${TAG}"
echo "### the two things worth checking before running it on a node:"
podman run --rm --entrypoint bash "${TAG}" -c '
	echo "-- doca-kernel-support present:"
	ls -l /opt/mellanox/doca/tools/doca-kernel-support /opt/mellanox/doca/tools/get_mlnx_ofed_version
	echo "-- bundled archive removed (must list nothing):"
	ls /opt/mellanox/doca/tools/resources/MLNX_OFED_*.tgz 2>&1 || true
	echo "-- os-release the tool will read for DISTRO:"
	grep -E "^(ID|VERSION_ID)=" /etc/os-release
'
