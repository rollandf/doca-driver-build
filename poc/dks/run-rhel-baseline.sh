#!/bin/bash
# Runs INSIDE a RHEL-family container. Driven by poc/dks/poc.sh on the host.
#
# Establishes the install.pl RPM baseline that the doca-kernel-support RHEL path
# has to be compared against. install.pl is invoked with exactly the flags
# buildDriverWithInstallPl() assembles for osType=redhat, UseDKMS=false,
# EnableNfsRdma=false -- both defaults.
#
# The one flag worth staring at is --disable-kmp. The runtime RHEL path passes it,
# so this baseline is a NON-KMP build producing mlnx-ofa_kernel-modules.
# doca-kernel-support defaults KMP=1 and only clears it for other distros, with no
# flag to turn it off, so it produces kmod-mlnx-ofa_kernel instead. Comparing the
# two package lists is the point of this script.
set -euo pipefail

TARGET_KVER="${TARGET_KVER:-5.14.0-687.42.1.el9_8.x86_64}"
TARBALL="${TARBALL:-/ofed/MLNX_OFED_SRC-26.07-0.7.7.0.tgz}"
# install.pl is told the distro explicitly, so unlike the doca-kernel-support
# runner this does not depend on the container's own os-release.
DISTRO="${SPOOF_DISTRO:-rhel:9.8}"
DISTRO_FLAG="rhel${DISTRO##*:}"

echo "### host kernel visible in container: $(uname -r)"
echo "### target kernel:                    ${TARGET_KVER}"
echo "### tarball:                          ${TARBALL}"
echo "### --distro:                         ${DISTRO_FLAG}"

# Union of RHEL_Dockerfile's base and driver-src stages: driver-src is FROM base,
# so the real build environment is both. Reproducing only driver-src is what cost
# an extra round on the Ubuntu baseline.
dnf install -y -q \
	perl jq iproute kmod procps-ng \
	autoconf python3-devel ethtool automake pciutils libtool hostname dracut \
	elfutils-libelf-devel kernel-rpm-macros numactl-libs lsof rpm-build patch \
	gcc make bison flex createrepo_c binutils kernel-abi-stablelists \
	"kernel-devel-${TARGET_KVER}" >/dev/null

# install.pl resolves --kernel through /lib/modules/<ver>/build, which kernel-devel
# does not create on EL9 (see B.3). Without it install.pl cannot find the headers.
if [ ! -e "/lib/modules/${TARGET_KVER}/build" ]; then
	echo "### creating the /lib/modules/<ver>/build symlink kernel-devel omits"
	mkdir -p "/lib/modules/${TARGET_KVER}"
	ln -sfn "/usr/src/kernels/${TARGET_KVER}" "/lib/modules/${TARGET_KVER}/build"
fi

work=/tmp/baseline
rm -rf "$work"
mkdir -p "$work"
tar xzf "$TARBALL" --no-same-owner -C "$work"
SRC=$(echo "$work"/*)
echo "### source tree: $SRC"

rc=0
"$SRC/install.pl" \
	--without-depcheck \
	--kernel "${TARGET_KVER}" \
	--kernel-only \
	--build-only \
	--with-mlnx-tools \
	--without-knem \
	--without-iser \
	--without-isert \
	--without-srp \
	--without-kernel-mft \
	--without-mlnx-rdma-rxe \
	--disable-kmp \
	--without-dkms \
	--distro "${DISTRO_FLAG}" \
	--without-xpmem \
	--without-xpmem-modules \
	--without-mlnx-nfsrdma \
	--without-mlnx-nvme || rc=$?
echo "### install.pl exit code: $rc"

# copyBuildArtifacts() harvests RPMS/*/<arch>/*.rpm, so look there first.
echo "### RPMS tree ###"
find "$SRC/RPMS" -name '*.rpm' -printf '%P\n' 2>/dev/null | sort || true

mkdir -p /out
find "$SRC/RPMS" -name '*.rpm' -exec cp -a {} /out/ \; 2>/dev/null || true

# install.pl writes everything under /tmp/OFED.<pid>.logs; on failure that
# directory is the only place the real error appears.
for d in /tmp/OFED.*.logs; do
	[ -d "$d" ] || continue
	cp -a "$d" /out/ 2>/dev/null || true
done

echo "### collected ###"
ls -la /out 2>/dev/null || true
exit "$rc"
