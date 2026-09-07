#!/bin/bash
# Runs INSIDE a UBI container. Answers one question: which of RHEL_Dockerfile's
# base + driver-src packages are reachable from UBI's public repos (+ EPEL), and
# which need a RHEL subscription. That decides whether the sources image can be
# built on any machine or only on a registered one.
set -x
RELEASE_VER="${RELEASE_VER:-9.8}"
MAJOR_VER="${RELEASE_VER%%.*}"

rpm --import "https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-${MAJOR_VER}" || true
dnf install -y -q "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${MAJOR_VER}.noarch.rpm" >/dev/null 2>&1 || true
set +x

echo "=== enabled repos ==="
dnf repolist 2>/dev/null

# base stage, then driver-src stage, in Dockerfile order.
PKGS="perl jq iproute kmod procps-ng udev
autoconf python3-devel ethtool automake pciutils libtool hostname dracut
elfutils-libelf-devel kernel-rpm-macros numactl-libs lsof rpm-build patch
gcc make bison flex createrepo_c binutils kernel-abi-stablelists dkms"

echo "=== availability (releasever=${RELEASE_VER}) ==="
missing=""
for p in $PKGS; do
	if rpm -q "$p" >/dev/null 2>&1; then
		echo "PREINSTALLED $p"
	elif dnf --releasever="${RELEASE_VER}" -q list --available "$p" >/dev/null 2>&1; then
		repo=$(dnf --releasever="${RELEASE_VER}" -q repoquery --qf '%{reponame}' "$p" 2>/dev/null | head -1)
		echo "OK           $p  (${repo:-?})"
	else
		echo "MISSING      $p"
		missing="$missing $p"
	fi
done

echo "=== verdict ==="
if [ -n "$missing" ]; then
	echo "needs a subscription (or another source):$missing"
else
	echo "all packages reachable from public repos - no subscription needed"
fi
