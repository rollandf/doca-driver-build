#!/bin/bash
# Runs on a machine with `oc` pointed at an OpenShift cluster running the OFED
# driver DaemonSet in DTK mode. Answers the questions that decide HOW the
# doca-kernel-support migration can work for DTK -- none of which can be
# answered from the repo, because they are all properties of the DTK image and
# the cluster's package access.
#
# Read-only. Installs nothing, changes nothing.
#
# Usage:
#   ./poc/dks/probe-dtk.sh                       # auto-discover the pod
#   POD=nvidia-nic-driver-xxxxx NS=nvidia-network-operator ./poc/dks/probe-dtk.sh
set -uo pipefail

NS="${NS:-}"
POD="${POD:-}"

command -v oc >/dev/null || { echo "ERROR: oc not found in PATH" >&2; exit 1; }

# --- discover the pod and its two containers ------------------------------------
# The DTK setup is two containers in one pod: the OFED driver container (which
# stages sources onto the shared volume) and the DTK sidecar (which compiles).
# Names vary by operator version, so find them by image/name substring rather
# than assuming.
if [ -z "$POD" ]; then
	echo "### searching for a pod with a driver-toolkit container..."
	read -r NS POD < <(oc get pods -A \
		-o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{range .spec.containers[*]}{.image}{","}{end}{"\n"}{end}' \
		2>/dev/null | grep -i "driver-toolkit" | head -1 | awk '{print $1, $2}')
fi

if [ -z "$POD" ] || [ -z "$NS" ]; then
	echo "ERROR: could not auto-discover a pod with a driver-toolkit container." >&2
	echo "       List candidates with:" >&2
	echo "         oc get pods -A -o wide | grep -i nic-driver" >&2
	echo "       then re-run with NS=<namespace> POD=<pod>" >&2
	exit 1
fi

echo "### namespace: ${NS}"
echo "### pod:       ${POD}"
echo
echo "### containers:"
oc get pod -n "$NS" "$POD" -o jsonpath='{range .spec.containers[*]}{"  "}{.name}{"  "}{.image}{"\n"}{end}'

# Pick the DTK container by image substring; fall back to the second container.
DTK_CTR="$(oc get pod -n "$NS" "$POD" \
	-o jsonpath='{range .spec.containers[*]}{.name}{" "}{.image}{"\n"}{end}' \
	| grep -i "driver-toolkit" | head -1 | awk '{print $1}')"
OFED_CTR="$(oc get pod -n "$NS" "$POD" \
	-o jsonpath='{range .spec.containers[*]}{.name}{" "}{.image}{"\n"}{end}' \
	| grep -iv "driver-toolkit" | head -1 | awk '{print $1}')"

echo
echo "### DTK container:  ${DTK_CTR:-<not found>}"
echo "### OFED container: ${OFED_CTR:-<not found>}"

[ -n "$DTK_CTR" ] || { echo "ERROR: no driver-toolkit container in this pod" >&2; exit 1; }

run_dtk() { oc exec -n "$NS" "$POD" -c "$DTK_CTR" -- bash -c "$1" 2>&1; }
run_ofed() { oc exec -n "$NS" "$POD" -c "$OFED_CTR" -- bash -c "$1" 2>&1; }

# The shared directory must be discovered, not assumed. config.go defaults
# DTK_OCP_NIC_SHARED_DIR to /mnt/shared-nvidia-nic-driver-toolkit, but the
# network-operator sets it to /mnt/shared-doca-driver-toolkit -- so hardcoding
# the repo default makes a perfectly healthy DTK build look like it never ran.
SHARED_DIR="$(oc get pod -n "$NS" "$POD" \
	-o jsonpath='{range .spec.containers[*]}{range .env[*]}{.name}{"="}{.value}{"\n"}{end}{end}' \
	2>/dev/null | grep '^DTK_OCP_NIC_SHARED_DIR=' | head -1 | cut -d= -f2-)"
if [ -z "$SHARED_DIR" ]; then
	# Not in the pod env, so the container is using the compiled-in default.
	# Try both known values before giving up.
	for cand in /mnt/shared-doca-driver-toolkit /mnt/shared-nvidia-nic-driver-toolkit; do
		if run_dtk "test -d $cand" >/dev/null 2>&1; then SHARED_DIR="$cand"; break; fi
	done
fi
SHARED_DIR="${SHARED_DIR:-/mnt/shared-doca-driver-toolkit}"
echo "### shared dir:     ${SHARED_DIR}"

echo
echo "================================================================"
echo "1. os-release in the DTK sidecar"
echo "================================================================"
# THE decisive probe. doca-kernel-support derives DISTRO straight from
# /etc/os-release and uses it to pick KMP dist tags, gate --with-gds, and decide
# which components are even buildable. It only recognises rhel:<maj>.<min>.
#
# If DTK reports ID=rhel VERSION_ID=9.x this is straightforward. If it reports
# ID=rhcos with VERSION_ID=4.x (the OCP version), then "trust the DTK
# os-release" cannot stand on its own and DTK needs the same rewrite the regular
# RHEL path got -- except sourced from the DTK image's RHEL version, not the node's.
run_dtk 'cat /etc/os-release'

echo
echo "================================================================"
echo "2. os-release of the RHCOS node, for contrast"
echo "================================================================"
run_ofed 'echo "--- container /etc/os-release:"; cat /etc/os-release; \
	echo "--- host /host/etc/os-release (what GetRedHatVersionInfo reads):"; \
	cat /host/etc/os-release 2>/dev/null || echo "(not mounted)"; \
	echo "--- /host/etc/redhat-release:"; \
	cat /host/etc/redhat-release 2>/dev/null || echo "(absent)"'

echo
echo "================================================================"
echo "3. kernel + header tree in the DTK sidecar"
echo "================================================================"
# The regular RHEL path passes -s /usr/src/kernels/<ver> because kernel-devel
# creates no /lib/modules/<ver>/build symlink on EL9. Need to know which of the
# two DTK actually provides, since that decides whether docaKernelTargetArgs can
# be reused verbatim.
run_dtk 'echo "uname -r:            $(uname -r)"; \
	echo "--- /usr/src/kernels:"; ls -1 /usr/src/kernels/ 2>&1; \
	echo "--- /lib/modules/*/build:"; ls -ld /lib/modules/*/build 2>&1; \
	echo "--- kernel packages installed:"; rpm -qa | grep -E "^kernel" | sort'

echo
echo "================================================================"
echo "4. package access in the DTK sidecar"
echo "================================================================"
# dtk.RunBuild already does `dnf install -y perl`, so SOME repo access exists.
# The question is whether it is enough for doca-kernel-support, which needs a
# heavier set. On the regular RHEL path these five were exactly the packages UBI
# could NOT supply and which forced the build onto a registered host:
#   kernel-rpm-macros bison flex createrepo_c kernel-abi-stablelists
# If DTK cannot install those either, they have to be staged onto the shared
# volume as RPMs, or the build has to stop needing them.
run_dtk 'echo "--- repolist:"; dnf repolist 2>&1 | head -30'
echo
# NOTE: do NOT test availability with `dnf list --available`. The dnf here is
# microdnf, which does not implement it and answers "This is microdnf, which
# implements subset of `dnf'" -- so every not-yet-installed package looks
# MISSING whether or not the repos carry it. An earlier run of this script drew
# exactly that wrong conclusion about createrepo_c.
#
# repoquery is the read-only test microdnf does support on recent builds; the
# --setopt install_weak_deps=0 --downloadonly install is the fallback that
# proves installability without committing to it.
run_dtk 'for p in rpm-build createrepo_c createrepo kernel-rpm-macros bison flex \
	elfutils-libelf-devel binutils kernel-abi-stablelists gcc make patch lsof hostname perl; do
	if rpm -q "$p" >/dev/null 2>&1; then
		printf "PREINSTALLED  %s\n" "$p"
	elif dnf repoquery "$p" 2>/dev/null | grep -q .; then
		printf "AVAILABLE     %s\n" "$p"
	elif dnf install -y --downloadonly "$p" >/dev/null 2>&1; then
		printf "INSTALLABLE   %s\n" "$p"
	else
		printf "UNRESOLVED    %s  (repoquery+downloadonly both failed - may still be a microdnf gap)\n" "$p"
	fi
done'

echo
echo "================================================================"
echo "5. is /opt/mellanox/doca/tools reachable/writable in DTK?"
echo "================================================================"
# doca-kernel-support hardcodes RES_FOLDER=/opt/mellanox/doca/tools/resources at
# assignment (not ${RES_FOLDER:-...}), and setup_rpm_dep_scripts calls
# $RES_FOLDER/find-provides.ksyms on the redhat vendor path. So the RPM build
# cannot run in a container lacking that exact absolute path. Staging the tool
# there is preferred option 1 in the plan (§11.3) -- but only if /opt is writable.
run_dtk 'echo "--- /opt:"; ls -ld /opt 2>&1; \
	echo "--- does anything mellanox already exist?"; ls -ld /opt/mellanox 2>&1; \
	echo "--- write test:"; \
	mkdir -p /opt/mellanox/doca/tools/resources 2>&1 && touch /opt/mellanox/doca/tools/resources/.probe \
		&& echo "WRITABLE" && rm -rf /opt/mellanox || echo "NOT WRITABLE"; \
	echo "--- read-only root fs?"; grep " / " /proc/mounts'

echo
echo "================================================================"
echo "6. the shared volume: contents and exec permission"
echo "================================================================"
# The loader already exec's the staged entrypoint binary from here, so exec
# should work -- confirm, because staging doca-kernel-support depends on it.
# Also shows what a real staging looks like today.
run_dtk "sd=${SHARED_DIR}; \
	echo \"--- mount options (noexec would break staging):\"; grep \"\$sd\" /proc/mounts || echo \"(not a separate mount)\"; \
	echo \"--- tree, 2 levels:\"; find \"\$sd\" -maxdepth 2 -printf '%y %M %p\n' 2>&1 | head -30; \
	echo \"--- dtk.env as currently generated:\"; cat \"\$sd\"/*/dtk.env 2>&1"

echo
echo "================================================================"
echo "7. does the DTK image happen to have doca-extra already?"
echo "================================================================"
# Option 3 in §11.3. Almost certainly absent, but cheap to rule out.
run_dtk 'ls -l /opt/mellanox/doca/tools/doca-kernel-support 2>&1; \
	rpm -q doca-extra 2>&1; \
	dnf -q list --available doca-extra 2>&1 | head -5'

echo
echo "================================================================"
echo "8. what install.pl actually produced last time"
echo "================================================================"
# dtkFinalizeDriverBuild globs RPMS/redhat-release-*/<arch>/*.rpm. Confirming the
# real layout tells us what the retarget has to replace, and the package NAMES
# tell us whether DTK is on the KMP or non-KMP side of the §11.6 split.
run_dtk "sd=${SHARED_DIR}; \
	echo \"--- every RPM install.pl left on the volume:\"; \
	find \"\$sd\" -name '*.rpm' -printf '%10s %P\n' 2>/dev/null | sort -k2 | head -40; \
	echo \"--- RPMS dir shape (what dtkFinalizeDriverBuild globs):\"; \
	find \"\$sd\" -type d -name RPMS -exec find {} -maxdepth 2 -type d \; 2>/dev/null | head -20"

echo
echo "--- and what actually reached the inventory (the KMP naming question):"
# install.pl here passes --disable-kmp, so this should show mlnx-ofa_kernel-modules.
# doca-kernel-support would produce kmod-mlnx-ofa_kernel instead (§11.6), which is a
# rename landing in OpenShift -- worth knowing before it does.
run_ofed 'inv="${NVIDIA_NIC_DRIVERS_INVENTORY_PATH:-/mnt/drivers-inventory}"; \
	echo "inventory root: $inv"; \
	find "$inv" -name "*.rpm" -printf "%10s %P\n" 2>/dev/null | sort -k2'

echo
echo "================================================================"
echo "9. is the DTK build path actually enabled on this pod?"
echo "================================================================"
# If section 6 found no shared directory, the sidecar is deployed but idle and
# the OFED container built in-container instead. That has to be resolved before
# any DTK change can be tested: we need a cluster that really takes this path.
# DTK_OCP_DRIVER_BUILD is what buildDriverDTK keys on (cfg.DtkOcpDriverBuild).
echo "--- env of both containers (DTK/driver/DKMS related):"
oc get pod -n "$NS" "$POD" -o jsonpath='{range .spec.containers[*]}{"container: "}{.name}{"\n"}{range .env[*]}{"    "}{.name}{"="}{.value}{"\n"}{end}{end}' \
	2>&1 | grep -iE "^container:|DTK|DRIVER|DKMS|NVIDIA_NIC|UNLOAD|RESTORE" || echo "(none matched)"

echo
echo "--- volumeMounts per container (does the sidecar even get the shared volume?):"
oc get pod -n "$NS" "$POD" -o jsonpath='{range .spec.containers[*]}{"container: "}{.name}{"\n"}{range .volumeMounts[*]}{"    "}{.mountPath}{"  <- "}{.name}{"\n"}{end}{end}'

echo
echo "--- how the OFED container decided to build:"
oc logs -n "$NS" "$POD" -c "$OFED_CTR" 2>&1 \
	| grep -iE "DTK|precompiled|Executing driver|build.*source|Skipping driver build|inventory" | head -20

echo
echo "--- what the sidecar has been doing:"
oc logs -n "$NS" "$POD" -c "$DTK_CTR" --tail=20 2>&1

echo
echo "### probe complete"
