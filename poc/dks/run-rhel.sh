#!/bin/bash
# Runs INSIDE a RHEL-family container. Driven by poc/dks/poc.sh on the host.
#
# Differences from the deb path that matter:
#  - components are pruned by removing SRPMS/*.src.rpm, not SOURCES/*.orig.t*
#  - the kernel component is mlnx-ofa_kernel, not mlnx-ofed-kernel
#  - no MLNX_KO_NO_STRIP patch: rpm_build never sets it, so the spec strips
#    normally via __os_install_post
#  - KMP is left enabled, which is what a precompiled image wants
set -euo pipefail

TARGET_KVER="${TARGET_KVER:-5.14.0-687.42.1.el9_8.x86_64}"
TARBALL="${TARBALL:-/ofed/MLNX_OFED_SRC-26.07-0.7.7.0.tgz}"
MODE="${MODE:-dryrun}"
KEEP="${KEEP:-}"
# Rewrite /etc/os-release so get_distro() reports rhel:X.Y. doca-kernel-support
# has no --distro override, and DISTRO changes real build behaviour: rhel gets
# --with-gds, and the KMP dist tag becomes .rhel9u8. Needed to reproduce a true
# RHEL build from a rebuild-distro base image, and the only lever available for
# RHCOS/DTK where os-release will not say what we need.
SPOOF_DISTRO="${SPOOF_DISTRO:-}"
DKS=/opt/mellanox/doca/tools/doca-kernel-support

echo "### mode:                             ${MODE}"
echo "### host kernel visible in container: $(uname -r)"
echo "### target kernel:                    ${TARGET_KVER}"
echo "### tarball:                          ${TARBALL}"
echo "### keep:                             ${KEEP:-<all>}"

# make is needed for set_kernel_vars()' `make kernelrelease` probe.
dnf install -y -q "kernel-devel-${TARGET_KVER}" make >/dev/null

# Use -s, not -k. On EL9 kernel-devel owns /usr/src/kernels/<ver> and does NOT
# create the /lib/modules/<ver>/build symlink, which is the path set_kernel_vars()
# hardcodes for -k -- so -k always fails in a container that has headers but no
# installed kernel. -s takes the source directory directly and derives the
# version from it, which is the supported way to do this.
KSRC="/usr/src/kernels/${TARGET_KVER}"
if [ ! -d "$KSRC" ]; then
	echo "!!! no kernel source tree at $KSRC" >&2
	exit 4
fi

if [ "$MODE" = build ]; then
	# Everything rpm_install_build_deps() probes with `rpm -q --whatprovides`.
	# createrepo_c satisfies the "createrepo" name via an explicit Provides.
	# If this list is complete the script never reaches for the network, which
	# is the offline (R6) requirement.
	dnf install -y -q createrepo_c rpm-build gcc autoconf automake libtool \
		elfutils-libelf-devel binutils kernel-headers kernel-rpm-macros \
		kernel-abi-stablelists >/dev/null
fi

if [ -n "$SPOOF_DISTRO" ]; then
	echo "### spoofing os-release to ${SPOOF_DISTRO}"
	cp /etc/os-release /etc/os-release.orig
	sed -i -e "s/^ID=.*/ID=\"${SPOOF_DISTRO%%:*}\"/" \
		-e "s/^VERSION_ID=.*/VERSION_ID=\"${SPOOF_DISTRO##*:}\"/" /etc/os-release
fi

install -d /opt/mellanox/doca/tools/resources
install -m 0755 /vendor/doca-kernel-support "$DKS"
install -m 0755 /poc/get_mlnx_ofed_version /opt/mellanox/doca/tools/
install -m 0644 /vendor/resources/find-provides.ksyms \
	/opt/mellanox/doca/tools/resources/

# Component exclusion by pruning SRPMs. rpm_build() globs
# SRPMS/<base>-[0-9]*.src.rpm and skips with "Missing package X, skipping" when
# absent, so doca-kernel-support stays unmodified.
if [ -n "$KEEP" ]; then
	work=/tmp/prune
	rm -rf "$work"
	mkdir -p "$work"
	tar xzf "$TARBALL" --no-same-owner -C "$work"
	root=$(echo "$work"/*)
	for f in "$root"/SRPMS/*.src.rpm; do
		[ -e "$f" ] || continue
		name=${f##*/}
		hit=0
		for k in $KEEP; do
			case "$name" in "$k"-[0-9]*) hit=1 ;; esac
		done
		if [ "$hit" = 1 ]; then
			echo "### keeping  $name"
		else
			rm -f "$f"
		fi
	done
	TARBALL=/out/pruned-rpm.tgz
	rm -f "$TARBALL"
	tar czf "$TARBALL" -C "$work" "$(basename "$root")"
	echo "### pruned archive: $TARBALL"
fi

cd /root

if [ "$MODE" = dryrun ]; then
	set -x
	"$DKS" --verbose --dry-run -s "$KSRC" -t "${TARBALL}"
	exit $?
fi

rc=0
"$DKS" --verbose --dirty -s "$KSRC" -t "${TARBALL}" || rc=$?
echo "### doca-kernel-support exit code: $rc"

top_dir=$(ls -dt /tmp/DOCA.* 2>/dev/null | head -1 || true)
echo "### TOP_DIR: ${top_dir:-<none>}"
if [ -n "$top_dir" ]; then
	echo "### loose packages under packages/<kver>/<component>/ ###"
	find "$top_dir/packages" -name '*.rpm' -printf '%P\n' 2>/dev/null | sort || true
	mkdir -p /out
	find "$top_dir/packages" -name '*.rpm' -exec cp -a {} /out/ \; 2>/dev/null || true
	find "$top_dir" -maxdepth 1 -name '*.rpm' -exec cp -a {} /out/ \; 2>/dev/null || true
	cp -a "$top_dir"/logs /out/ 2>/dev/null || true
fi
exit 0
