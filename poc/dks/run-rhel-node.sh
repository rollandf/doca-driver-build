#!/bin/bash
# Runs the RHEL "sources" image on the node it was built on, exercising the
# doca-kernel-support build path end to end: build -> harvest -> install -> load.
#
# Mirrors the Ubuntu node run, with three RHEL-only additions explained inline.
# Deliberately does NOT use --rm: doca-kernel-support writes its per-component
# build logs as files under a mktemp directory and only prints their names, so a
# failed run is undiagnosable once the container is gone. Recover them with
#   podman cp <name>:/tmp/<dir> .
set -euo pipefail

NAME="${NAME:-dks-rhel}"
IMAGE="${IMAGE:-localhost/doca-driver:local-rhel9.8-src}"
INVENTORY="${INVENTORY:-/host/cache/drivers}"

# On RHEL /etc/os-release is a RELATIVE symlink to ../usr/lib/os-release. The Go
# entrypoint reads /host/etc/os-release for host version info, which therefore
# resolves to /host/usr/lib/os-release inside the container. Mounting only /etc
# leaves that dangling, GetRedHatVersionInfo fails, and the build aborts before
# it starts. This mount is a no-op on Ubuntu but load-bearing here.
if [ ! -f /usr/lib/os-release ]; then
	echo "ERROR: no /usr/lib/os-release on this host; the /host/etc/os-release symlink will dangle." >&2
	exit 1
fi

# installKernelPackages dnf-installs kernel-core/kernel-modules/kernel-devel for
# the running kernel, and none of those exist in UBI's public repos. So the
# container needs the host's entitled repo definitions plus the certs they point
# at. redhat.repo references /etc/pki/entitlement/*.pem by absolute path, hence
# mounting the certs at that same path rather than at entitlement-host.
REPO_MOUNTS=()
if [ -f /etc/yum.repos.d/redhat.repo ] && compgen -G "/etc/pki/entitlement/*.pem" >/dev/null; then
	REPO_MOUNTS+=(-v /etc/yum.repos.d/redhat.repo:/etc/yum.repos.d/redhat.repo:ro)
	REPO_MOUNTS+=(-v /etc/pki/entitlement:/etc/pki/entitlement:ro)
	echo "### entitled repos: mounting host redhat.repo + entitlement certs"
else
	echo "### WARNING: host has no redhat.repo or no entitlement certs."
	echo "###          Expect installKernelPackages to fail on kernel-devel."
	echo "###          Register the host, or pre-create /lib/modules/<kver>/build in the image."
fi

# Only mounting redhat.repo, not the whole /etc/yum.repos.d, so the image's own
# doca.repo/epel/ubi definitions survive.

# installKernelPackages dnf-installs kernel-<ver>, kernel-core, kernel-modules and
# kernel-devel for the running kernel -- but it returns early if
# /lib/modules/<ver>/build already exists. Taking that exit is better than letting
# it run: the build only ever needs the header tree at /usr/src/kernels/<ver> (the
# RHEL path passes -s, precisely because kernel-devel owns no build symlink), so
# installing a whole kernel into a container is pure waste. It is also the only
# option on a host whose kernel is not in the repos the container can reach --
# e.g. a pre-GA kernel, tagged .el9 rather than .el9_N, which lives in the beta
# repos while the container resolves against GA with --releasever.
#
# kernel-devel does not create the build symlink on EL, so make it here.
#
# Set SKIP_KERNEL_PKGS=0 to decline the shortcut and exercise the real
# installKernelPackages path -- which is the point once the host is a normal GA
# machine whose running kernel is actually in the repos.
KVER="$(uname -r)"
HDRS="/usr/src/kernels/${KVER}"
ENTRY=()
CMD=()
if [ "${SKIP_KERNEL_PKGS:-auto}" = "0" ]; then
	echo "### SKIP_KERNEL_PKGS=0: letting installKernelPackages dnf-install kernel-${KVER}"
elif [ -d "$HDRS" ]; then
	echo "### kernel headers: ${HDRS} (mounting; kernel package install will be skipped)"
	REPO_MOUNTS+=(-v "${HDRS}:${HDRS}:ro")
	ENTRY=(--entrypoint bash)
	CMD=(-c "set -e
mkdir -p /lib/modules/${KVER}
ln -sfn ${HDRS} /lib/modules/${KVER}/build
cd /root
exec ./loader.sh sources")
else
	echo "### WARNING: no ${HDRS} on this host."
	echo "###          installKernelPackages will try to dnf-install kernel-${KVER}."
	echo "###          If that kernel is pre-GA it is not in the GA repos and will fail."
	echo "###          Fix by installing the header tree on the HOST first:"
	echo "###            dnf install -y kernel-devel-${KVER}"
	echo "###          adding --enablerepo=rhel-9-for-x86_64-baseos-beta-rpms if needed."
fi

mkdir -p /host/cache/drivers
podman rm -f "$NAME" >/dev/null 2>&1 || true

echo "### image:  ${IMAGE}"
echo "### kernel: $(uname -r)"
echo "### name:   ${NAME}  (not auto-removed, so build logs stay recoverable)"

set -x
podman run -ti --name "$NAME" \
	-e RESTORE_DRIVER_ON_POD_TERMINATION=true \
	-e UNLOAD_STORAGE_MODULES=true \
	-e CREATE_IFNAMES_UDEV=true \
	-e ENTRYPOINT_DEBUG=true \
	-e DEBUG_SLEEP_SEC_ON_EXIT="${DEBUG_SLEEP_SEC_ON_EXIT:-0}" \
	-e NVIDIA_NIC_DRIVERS_INVENTORY_PATH="${INVENTORY}" \
	-e ENABLE_NFSRDMA="${ENABLE_NFSRDMA:-false}" \
	-v /run/mellanox/drivers:/run/mellanox/drivers:shared \
	-v /host/cache/drivers:/host/cache/drivers \
	-v /etc:/host/etc \
	-v /lib/modules:/host/lib/modules \
	-v /lib/udev:/host/lib/udev \
	-v /usr/lib/os-release:/host/usr/lib/os-release:ro \
	-v /run/udev:/run/udev:ro \
	"${REPO_MOUNTS[@]}" \
	--net=host \
	--privileged \
	"${ENTRY[@]}" \
	"${IMAGE}" "${CMD[@]}" || rc=$?
set +x

rc="${rc:-0}"
echo "### exit code: $rc"
echo "### to pull build logs out of the stopped container:"
echo "###   podman cp ${NAME}:/tmp/. ./dks-logs/"
echo "### to see what got harvested:"
echo "###   ls -la /host/cache/drivers/\$(uname -r)/"
exit "$rc"
