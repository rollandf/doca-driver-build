#!/bin/bash
# Runs INSIDE an Ubuntu container. Driven by poc/dks/poc.sh on the host.
#
# Establishes the install.pl baseline for the *sources* variant on Ubuntu, so the
# doca-kernel-support output can be diffed against what we ship today. The flag list
# below is not invented: it is exactly what buildDriverFromSource() assembles at runtime
# for osType=ubuntu with UseDKMS=false and EnableNfsRdma=false (both defaults), as of
# driver.go:1123-1180 plus getBuildFlagsForOS, getPackageSuffix ("-modules" here) and
# getAppendDriverBuildFlags.
#
# Deliberately NOT faithful to the Dockerfile in one respect: driver-src pins gcc-12,
# while this uses the image default so the result is directly comparable to the
# doca-kernel-support build in out-ubuntu/, which also used the default. Compiler choice
# is a real variable for module size (see the LTO finding in the plan doc, appendix B.7)
# but not for the package *set*, which is what this baseline exists to capture.
set -euo pipefail

TARGET_KVER="${TARGET_KVER:-6.8.0-139-generic}"
TARBALL="${TARBALL:-/ofed/MLNX_OFED_SRC-debian-26.07-0.7.7.0.tgz}"

echo "### install.pl baseline (sources variant, Ubuntu, non-DKMS)"
echo "### host kernel visible in container: $(uname -r)"
echo "### target kernel:                    ${TARGET_KVER}"
echo "### tarball:                          ${TARBALL}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# The image the sources variant actually ships is driver-src, which is FROM base, so the
# build environment is the union of both stages' package lists. Reproducing only
# driver-src is not enough: dh-python and python3 come from base, and mlnx-tools
# Build-Depends on dh-python, so omitting base makes the mlnx-tools build fail in a way
# that has nothing to do with install.pl.
#
# Neither stage passes --no-install-recommends, so this does not either.

# base stage (Ubuntu_Dockerfile:53-58)
apt-get install -y -qq apt-utils perl pciutils kmod lsof python3 dh-python \
	jq iproute2 udev ethtool ca-certificates >/dev/null

# driver-src stage (Ubuntu_Dockerfile:101-103), plus the target kernel headers
apt-get install -y -qq \
	"linux-headers-${TARGET_KVER}" \
	curl dkms make autoconf autotools-dev chrpath automake hostname \
	debhelper dh-exec gcc quilt libc6-dev build-essential pkg-config \
	ubuntu-advantage-tools bison flex libelf-dev zstd >/dev/null

# mlnx-ofed-kernel Build-Depends is "dh-dkms | dkms (<< 3.0)"; on Noble+ dkms is >= 3.0
# and dh_dkms lives in its own package, so dpkg-buildpackage fails without it.
apt-get install -y -qq --no-install-recommends dh-dkms >/dev/null 2>&1 || true

work=/tmp/src
mkdir -p "$work"
tar xzf "$TARBALL" --no-same-owner -C "$work"
SRC=$(echo "$work"/MLNX_OFED_SRC-*)
echo "### extracted to: $SRC"

if [ ! -x "$SRC/install.pl" ]; then
	echo "!!! no install.pl in $SRC" >&2
	exit 4
fi

cd /root
rc=0
"$SRC/install.pl" \
	--without-depcheck \
	--kernel "${TARGET_KVER}" \
	--kernel-only \
	--build-only \
	--with-mlnx-tools \
	--without-knem-modules \
	--without-iser-modules \
	--without-isert-modules \
	--without-srp-modules \
	--without-kernel-mft-modules \
	--without-mlnx-rdma-rxe-modules \
	--disable-kmp \
	--without-dkms \
	--without-xpmem \
	--without-xpmem-modules \
	--without-mlnx-nfsrdma-modules \
	--without-mlnx-nvme-modules || rc=$?
echo "### install.pl exit code: $rc"

# copyBuildArtifacts() harvests DEBS/ubuntu*/<arch>/*.deb, so look there first.
echo "### DEBS tree ###"
find "$SRC/DEBS" -name '*.deb' -printf '%P\n' 2>/dev/null | sort || true

mkdir -p /out
find "$SRC/DEBS" -name '*.deb' -exec cp -a {} /out/ \; 2>/dev/null || true

# install.pl writes everything under /tmp/OFED.<pid>.logs; on failure that directory is
# the only place the real error appears.
logdir=$(ls -dt /tmp/OFED.*.logs 2>/dev/null | head -1 || true)
if [ -n "$logdir" ]; then
	echo "### install.pl logs: $logdir"
	cp -a "$logdir" /out/ 2>/dev/null || true
	for l in "$logdir"/*.debbuild.log; do
		[ -f "$l" ] || continue
		echo "--- ${l##*/} (last 30 lines) ---"
		tail -30 "$l"
	done
fi
exit 0
