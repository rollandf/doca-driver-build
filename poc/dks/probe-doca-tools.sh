#!/bin/bash
# Runs on the registered RHEL VM, against the locally built sources image.
#
# Answers the three things needed to stage doca-kernel-support into the DTK
# sidecar (the chosen DTK design):
#
#   1. WHAT to stage -- the exact contents of /opt/mellanox/doca/tools, so the
#      staging copies everything the tool reaches for rather than the three files
#      §11.3 guessed at.
#   2. HOW the tool uses RES_FOLDER, createrepo and its work directory -- the
#      last one decides whether the sidecar can be told where to write its
#      output, or has to harvest from an mktemp dir and copy to the shared volume.
#   3. WHICH createrepo_c RPMs to bake into the image for the sidecar. DTK has
#      only the three UBI repos and no entitlements, so createrepo_c has to
#      arrive as files on the shared volume.
#
# Read-only apart from the throwaway container.
set -uo pipefail

IMAGE="${IMAGE:-localhost/doca-driver:local-rhel9.8-src}"

command -v podman >/dev/null || { echo "ERROR: podman not found" >&2; exit 1; }
podman image exists "$IMAGE" || {
	echo "ERROR: image $IMAGE not found. Build it with poc/dks/build-rhel-image.sh," >&2
	echo "       or set IMAGE=<tag>." >&2
	exit 1
}

echo "### image: ${IMAGE}"

podman run --rm --entrypoint bash "$IMAGE" -c '
echo "================================================================"
echo "1. what doca-extra actually installs under /opt/mellanox"
echo "================================================================"
find /opt/mellanox -printf "%y %M %10s %p\n" | sort -k4
echo
echo "--- owning package(s):"
rpm -qf /opt/mellanox/doca/tools/doca-kernel-support 2>&1
echo "--- full file list of that package:"
rpm -ql doca-extra 2>&1 | head -40

echo
echo "================================================================"
echo "2. how the tool uses RES_FOLDER, createrepo and its work dir"
echo "================================================================"
echo "--- RES_FOLDER assignment and every use:"
grep -n "RES_FOLDER" /opt/mellanox/doca/tools/doca-kernel-support
echo
echo "--- createrepo invocations (the DTK dependency gap):"
grep -n "createrepo" /opt/mellanox/doca/tools/doca-kernel-support
echo
echo "--- does createrepo_c ship the bare createrepo binary the tool actually calls?"
rpm -ql createrepo_c | grep bin
echo
echo "--- the self-installing dependency check (must be fully satisfied in DTK,"
echo "    which has no repos to install from):"
awk "NR>=245 && NR<=300" /opt/mellanox/doca/tools/doca-kernel-support
echo
echo "--- work directory: is it mktemp-only, or can it be pointed somewhere?"
grep -nE "mktemp|TOPDIR|topdir|--dirty|OUTDIR|outdir|Building a single package|packages/" \
	/opt/mellanox/doca/tools/doca-kernel-support
echo
echo "--- the full option spec (what the sidecar may legally pass):"
grep -nE "getopt|--long|^[[:space:]]*(-[a-z]|--[a-z-]+)\)" \
	/opt/mellanox/doca/tools/doca-kernel-support | head -60

echo
echo "================================================================"
echo "3. createrepo_c dependency closure to bake in for the sidecar"
echo "================================================================"
echo "--- direct requires:"
rpm -qR createrepo_c 2>&1
echo
echo "--- resolved recursive closure (candidate stage list):"
dnf repoquery -q --requires --resolve --recursive createrepo_c 2>/dev/null | sort -u
echo
echo "--- createrepo_c and its non-base siblings, with sizes:"
for p in createrepo_c createrepo_c-libs drpm libmodulemd; do
	printf "%-20s %s\n" "$p" "$(rpm -q --qf "%{VERSION}-%{RELEASE}.%{ARCH}  %{SIZE} bytes" "$p" 2>&1)"
done
'

echo
echo "### next: check which of the closure above is MISSING in the DTK sidecar."
echo "### Feed the list into probe-dtk.sh section 4, or run directly:"
echo "###   oc exec -n <ns> <pod> -c openshift-driver-toolkit-ctr -- \\"
echo "###     bash -c 'for p in <list>; do rpm -q \$p >/dev/null 2>&1 || echo MISSING \$p; done'"
