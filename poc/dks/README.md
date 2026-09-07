# `doca-kernel-support` POC and validation scripts

Scripts used to migrate this repository off `install.pl` (see
[`docs/install-pl-deprecation-plan.md`](../../docs/install-pl-deprecation-plan.md)). They fall
into three groups: measuring what `install.pl` produced, exercising the replacement, and
probing environments we do not control.

Everything writes to `poc/dks/out*/`, which is gitignored — it is hundreds of MB of packages
and build logs.

## Baselines — what `install.pl` produced

Run these first when a package set is in question. They establish the "before" that any
migration change has to match.

| Script | Purpose |
|---|---|
| `run-ubuntu-baseline.sh` | `install.pl --without-dkms` on Ubuntu; produces the reference deb set |
| `run-rhel-baseline.sh` | the same for RHEL; the reference RPM set |

`poc.sh` wraps both plus the migrated paths: `./poc/dks/poc.sh build <ubuntu|rhel|rhel-baseline>`.

## Exercising the migrated path

| Script | Where it runs |
|---|---|
| `run-ubuntu.sh` | Ubuntu container build via `doca-kernel-support` |
| `run-rhel.sh` | the same on RHEL |
| `build-rhel-image.sh` | builds the RHEL `driver-src` image. **Must run on a subscription-registered RHEL host** — UBI lacks `kernel-rpm-macros`, `bison`, `flex`, `createrepo_c` and `kernel-abi-stablelists` |
| `run-rhel-node.sh` | runs that image on the node it was built on, end to end: build, harvest, install, load |

`run-rhel-node.sh` deliberately does not pass `--rm`. `doca-kernel-support` writes per-component
build logs as files under a `mktemp` directory and only prints their names, so a failed run is
undiagnosable once the container is gone. Recover them with `podman cp <name>:/tmp/. ./dks-logs/`.

Two environment variables matter:

- `SKIP_KERNEL_PKGS=0` — decline the header-mount shortcut and exercise the real
  `installKernelPackages`. Needed once the host is a normal GA machine; see Appendix D of the
  plan doc for why the shortcut exists.
- `ENABLE_NFSRDMA=true` — selects `mlnx-nfsrdma` and `mlnx-nvme`, which changes the archive
  pruning and therefore the package set.

## Probes — environments we do not control

Read-only. Each answers questions that could not be settled by reading code.

| Script | Runs on | Answers |
|---|---|---|
| `probe-doca-tools.sh` | the RHEL VM, against the built image | what `doca-extra` installs, how the tool uses `RES_FOLDER`/`createrepo`/its work directory, and its dependency closure |
| `probe-dtk.sh` | a cluster with `oc` access | what the OpenShift driver-toolkit sidecar has preinstalled, whether `/opt` is writable, and where the operator actually mounts the shared volume |
| `probe-ubi-pkgs.sh` | anywhere with podman | which build dependencies UBI's public repos can supply |

`probe-dtk.sh` discovers the shared directory from the pod environment rather than assuming it.
The repo default (`/mnt/shared-nvidia-nic-driver-toolkit`) does not match what the operator sets
(`/mnt/shared-doca-driver-toolkit`), which cost real time before the probe was fixed.

## `get_mlnx_ofed_version`

A copy of the script `doca-ofed-source` installs. `doca-kernel-support` calls it
unconditionally under `set -e` and dies without it, so it is kept here for POC runs that stage
the tool by hand rather than installing the package.
