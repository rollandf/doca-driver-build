#!/bin/bash
# Runs INSIDE an Ubuntu container. Driven by poc/dks/poc.sh on the host.
#
# MODE=dryrun  -> stage the script and run --dry-run (proves R1 + reports deps)
# MODE=build   -> real build, then harvest loose packages to /out
set -euo pipefail

TARGET_KVER="${TARGET_KVER:-6.8.0-139-generic}"
TARBALL="${TARBALL:-/ofed/MLNX_OFED_SRC-debian-26.07-0.7.7.0.tgz}"
MODE="${MODE:-dryrun}"
KEEP="${KEEP:-}"
# Flip deb_build's hardcoded MLNX_KO_NO_STRIP="1" to "0". debian/rules strips by
# default; doca-kernel-support opts out, costing 571MB installed vs 85MB. The
# same override_dh_strip target also hosts the WITH_MOD_SIGN hook, so opting out
# of stripping silently disables module signing too.
PATCH_STRIP="${PATCH_STRIP:-1}"
# Inject WITH_MOD_SIGN="1" and sign with a throwaway key, to prove the hook that
# PATCH_STRIP restores is actually reachable.
SIGN_MODULES="${SIGN_MODULES:-0}"
DKS=/opt/mellanox/doca/tools/doca-kernel-support

echo "### mode:                             ${MODE}"
echo "### host kernel visible in container: $(uname -r)"
echo "### target kernel:                    ${TARGET_KVER}"
echo "### tarball:                          ${TARBALL}"
echo "### keep:                             ${KEEP:-<all>}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# `make` and the target headers are the minimum for set_kernel_vars() to
# resolve the target kernel at all: it runs `make -s -C <ksrc> kernelrelease`.
apt-get install -y -qq --no-install-recommends \
	"linux-headers-${TARGET_KVER}" make

if [ "$MODE" = build ]; then
	# Pre-install everything deb_install_build_deps() looks for, so that its
	# install step becomes a no-op. This is the R6 (offline) rehearsal: if the
	# list is complete, the script never reaches for the network.
	apt-get install -y -qq --no-install-recommends \
		build-essential debhelper dh-exec fakeroot autoconf automake \
		quilt pkgconf apt-utils
fi

# Stage doca-kernel-support exactly where it expects to live.
install -d /opt/mellanox/doca/tools/resources
install -m 0755 /vendor/doca-kernel-support "$DKS"
install -m 0755 /poc/get_mlnx_ofed_version /opt/mellanox/doca/tools/
install -m 0644 /vendor/resources/find-provides.ksyms \
	/opt/mellanox/doca/tools/resources/

# Patch the staged copy, never the read-only vendor original.
#
# Every sed below verifies it actually matched. A silently-no-op sed against a
# vendor script is precisely the bug already living in entrypoint.sh, where the
# UNLOAD_MODULES injection matches nothing in 26.07 and no one noticed.
patch_dks() {
	local desc="$1" expr="$2" probe="$3"
	if ! grep -q -- "$probe" "$DKS"; then
		echo "!!! sed target vanished ($desc): pattern '$probe' not found" >&2
		exit 4
	fi
	sed -i "$expr" "$DKS"
	echo "### patched: $desc"
}

if [ "$PATCH_STRIP" = 1 ]; then
	patch_dks "MLNX_KO_NO_STRIP 1 -> 0" \
		's/MLNX_KO_NO_STRIP="1"/MLNX_KO_NO_STRIP="0"/' \
		'MLNX_KO_NO_STRIP="1"'
fi

if [ "$SIGN_MODULES" = 1 ]; then
	apt-get install -y -qq --no-install-recommends openssl >/dev/null
	openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
		-keyout /tmp/poc-signing.key \
		-outform DER -out /tmp/poc-signing.der \
		-subj "/CN=doca-driver-build POC module signing/" 2>/dev/null
	# sign-modules reads these from the environment; `env` in deb_build does not
	# use -i, so exported values are inherited.
	export MODULE_SIGN_PRIV_KEY=/tmp/poc-signing.key
	export MODULE_SIGN_PUB_KEY=/tmp/poc-signing.der
	patch_dks "inject WITH_MOD_SIGN=1" \
		's|WITH_DKMS="0" \\|WITH_DKMS="0" \\\n\t\tWITH_MOD_SIGN="1" \\|' \
		'WITH_DKMS="0" \\'
	echo "### signing key: $MODULE_SIGN_PRIV_KEY / $MODULE_SIGN_PUB_KEY"
fi

# Component exclusion by pruning the source archive rather than patching the
# script. deb_build()/rpm_build() skip any component whose source file is absent
# ("Missing package X, skipping"), so exclusion becomes a data operation and
# doca-kernel-support stays unmodified.
if [ -n "$KEEP" ]; then
	work=/tmp/prune
	rm -rf "$work"
	mkdir -p "$work"
	tar xzf "$TARBALL" --no-same-owner -C "$work"
	root=$(echo "$work"/*)
	for f in "$root"/SOURCES/*.orig.t*; do
		[ -e "$f" ] || continue
		base=${f##*/}
		base=${base%%_*}
		case " $KEEP " in
		*" $base "*) echo "### keeping  $base" ;;
		*) echo "### pruning  $base"; rm -f "$f" ;;
		esac
	done
	TARBALL=/out/pruned.tgz
	rm -f "$TARBALL"
	tar czf "$TARBALL" -C "$work" "$(basename "$root")"
	echo "### pruned archive: $TARBALL"
fi

cd /root

if [ "$MODE" = dryrun ]; then
	set -x
	"$DKS" --verbose --dry-run -k "${TARGET_KVER}" -t "${TARBALL}"
	exit $?
fi

# Real build. --dirty keeps $TOP_DIR/packages alive so we can harvest loose
# packages instead of unwrapping the doca-kernel-repo output package.
rc=0
"$DKS" --verbose --dirty -k "${TARGET_KVER}" -t "${TARBALL}" || rc=$?
echo "### doca-kernel-support exit code: $rc"

# Harvest regardless of exit code: repo/metapackage creation happens after the
# module build, so partial success still leaves usable packages behind.
top_dir=$(ls -d /tmp/DOCA.* 2>/dev/null | head -1 || true)
echo "### TOP_DIR: ${top_dir:-<none>}"
if [ -n "$top_dir" ]; then
	echo "### loose packages under packages/<kver>/<component>/ ###"
	find "$top_dir/packages" -name '*.deb' -printf '%P\n' 2>/dev/null | sort || true
	echo "### build logs ###"
	for l in "$top_dir"/logs/*.log; do
		[ -f "$l" ] || continue
		echo "--- ${l##*/} (last 25 lines) ---"
		tail -25 "$l"
	done
	mkdir -p /out
	find "$top_dir/packages" -name '*.deb' -exec cp -a {} /out/ \; 2>/dev/null || true
	find "$top_dir" -maxdepth 1 -name '*.deb' -exec cp -a {} /out/ \; 2>/dev/null || true
	cp -a "$top_dir"/logs /out/ 2>/dev/null || true
fi
exit 0
