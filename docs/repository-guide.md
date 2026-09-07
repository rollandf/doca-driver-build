# DOCA Driver Build — Repository Guide

How the DOCA / MLNX_OFED sources, built driver binaries, container definitions, and
entrypoint programs in this repository fit together.

This repository (`Mellanox/doca-driver-build`) produces the **doca-driver container**
used by the [NVIDIA Network Operator](https://github.com/Mellanox/network-operator).
The container's job is to get the NVIDIA NIC (mlx5) driver stack — built from
MLNX_OFED sources shipped inside the DOCA package — compiled, installed, and loaded on
a Kubernetes worker node, replacing the inbox `mlx5_core` driver while preserving the
node's network configuration.

Repository state at time of writing: 83 tracked files, `README.md` covers the *build
instructions*; this guide covers *what each file is and how the pieces interact*.

---

## 1. The two container flavors

Everything in the repo exists to serve one of two runtime modes. The mode is chosen by
the container's `CMD` (the first argument passed to the entrypoint), not by an
environment variable.

| Mode | `CMD` | Driver origin | When used |
|---|---|---|---|
| **Precompiled** | `precompiled` | Driver `.rpm`/`.deb` packages already baked into the image at build time, for one exact kernel version | Fast pod startup; image is kernel-locked |
| **Sources (dynamic)** | `sources` | MLNX_OFED source tree baked in; `install.pl` compiles against the running node's kernel at pod startup | Kernel-agnostic image; slower startup |

A third mode, `dtk-build`, is not a driver container — it is the sidecar mode used on
OpenShift, described in [section 6](#6-openshift-dtk-driver-toolkit-flow).

Because the precompiled image is tied to a kernel, the Network Operator relies on the
image tag encoding all of it:

```
doca<doca_version>-<driver_ver>-<container_ver>-<kernel_ver>-<os>-<arch>
doca2.9.1-24.10-1.1.4.0-0-5.15.0-25-generic-ubuntu22.04-amd64
```

---

## 2. DOCA / MLNX_OFED artifacts: sources in, binaries out

### 2.1 Where the sources come from

NIC driver sources are not vendored in this repository. They are downloaded during the
image build from the DOCA publication site:

```
https://linux.mellanox.com/public/repo/doca/${D_DOCA_VERSION}/SOURCES/mlnx_ofed/MLNX_OFED_SRC-${D_OFED_SRC_TYPE}${D_OFED_VERSION}.tgz
```

Two versions must both be supplied, because the MLNX_OFED driver version is *bundled
inside* a DOCA release and the two numbering schemes are independent:

- `D_DOCA_VERSION` — e.g. `3.5.0`, selects the publication directory
- `D_OFED_VERSION` — e.g. `26.07-0.7.7.0`, selects the archive within it

`D_OFED_SRC_TYPE` selects the archive variant: `debian-` for Ubuntu, empty for
RHEL/RHCOS/SLES. Despite the name, `D_OFED_URL_PATH` may also point at a local `.tgz`
(the `ADD` instruction accepts both), which is how internal pre-release builds are done.

### 2.2 Layout of the extracted source tree

The archive extracts to `${D_OFED_SRC_DOWNLOAD_PATH}/MLNX_OFED_SRC-${D_OFED_VERSION}`
(default download path `/run/mellanox/src`). Its contents:

| Entry | Role |
|---|---|
| `install.pl` | The MLNX_OFED build/install driver script. **This is the single tool that compiles the driver**, in the image build and at container runtime alike |
| `common.pl` | Perl helpers used by `install.pl` |
| `SRPMS/` | Source RPMs for every OFED component (`mlnx-ofa_kernel`, `rdma-core`, `mlnx-nvme`, `mlnx-nfsrdma`, `mlnx-tools`, `ucx`, `openvswitch`, …) |
| `SOURCES/ofed_scripts` | `openibd` init script, udev rules, `mlnxofedctl`, and other runtime scripts |
| `RPMS/` , `DEBS/` | **Output** directories — populated by `install.pl` with the compiled packages |
| `BUILD_ID`, `LICENSE`, `uninstall.sh` | Metadata and uninstaller |

At runtime the container image exposes this path as `NVIDIA_NIC_DRIVER_PATH`. In a
precompiled image that variable is deliberately set to the empty string, which is how
the entrypoint knows there is nothing to build.

### 2.3 The built binaries

`install.pl` is always invoked with `--kernel-only --build-only`, so it produces
*packages*, never a live installation. Where they land is distro-dependent, and the
Dockerfiles/entrypoints must agree on these globs:

| Distro | Output glob |
|---|---|
| RHEL / RHCOS | `${OFED_SRC_LOCAL_DIR}/RPMS/redhat-release-*/${D_ARCH}/*.rpm` |
| SLES | `${OFED_SRC_LOCAL_DIR}/RPMS/sles-release-*/${D_ARCH}/*.rpm` |
| Ubuntu | `${OFED_SRC_LOCAL_DIR}/DEBS/${D_OS}/*/*.deb` |

The interesting packages are `mlnx-ofa_kernel` (the `mlx5_core`/`mlx5_ib`/`ib_*`
modules), `mlnx-nvme`, `mlnx-nfsrdma`, and `mlnx-tools`. The kernel modules install
under `/lib/modules/<kver>/extra/mlnx-ofa_kernel/`.

> **Warning**
> `D_OFED_SRC_DOWNLOAD_PATH` is hardcoded in the entrypoint logic as well. Changing the
> build arg without updating `entrypoint.sh` / `driver.go` will break the runtime build.

### 2.4 Static modules vs. DKMS

`D_ENABLE_DKMS` (default `false`) switches every Dockerfile's build invocation between
two shapes of output:

- **`false`** — `install.pl … --without-dkms` (plus `--disable-kmp` on Ubuntu). Produces
  static, prebuilt `.ko` packages only.
- **`true`** — omits those flags, so `install.pl` emits both the DKMS *source* package
  (source tree plus `dkms.conf` under `/usr/src/<module>-<version>/`) and precompiled
  kmod binary packages. The runtime `USE_DKMS=true` variable then drives
  `dkms add`/`build`/`install` inside the container.

Because DKMS work can happen at runtime, the `sources` images always install `dkms` and
a compiler toolchain, and the precompiled images install them conditionally.

---

## 3. Files in the repository

### 3.1 Container definitions

| File | Purpose |
|---|---|
| `RHEL_Dockerfile` | RHEL and RHCOS/OpenShift images. Only Dockerfile with a separate final base image and DTK support |
| `Ubuntu_Dockerfile` | Ubuntu images |
| `SLES_Dockerfile` | SUSE Linux Enterprise images |
| `stig-fixer.sh` | **Deliberate dummy file.** `COPY` cannot be conditional in a Dockerfile, so a placeholder must exist; real STIG-hardened builds substitute a genuine script and set `STIG_COMPLIANT=true` |

### 3.2 Runtime entrypoints

| File | Purpose |
|---|---|
| `loader.sh` | The image `ENTRYPOINT`. Nine lines of dispatch: `exec ./entrypoint "$@"` when `USE_NEW_ENTRYPOINT` is true (**the default**), otherwise `exec ./entrypoint.sh "$@"` |
| `entrypoint/` | The Go entrypoint (default implementation). Compiled to `/root/entrypoint` |
| `entrypoint.sh` | The legacy bash entrypoint (~2050 lines, 58 functions). Retained as an escape hatch via `USE_NEW_ENTRYPOINT=false` |
| `dtk_nic_driver_build.sh` | Runs in the OpenShift DriverToolKit sidecar. Sources `dtk.env`, then either `exec entrypoint dtk-build` (default) or runs its own bash build loop |

### 3.3 Metadata, tooling, governance

| File | Purpose |
|---|---|
| `release_manifests/*.yaml` | Per-release build matrix: `driver_version`, `doca_version`, and the exact `precompiled` (OS × arch × kernel) and `dynamically_compiled` (OS × arch) combinations to publish. Consumed by CI, updated by an automated job |
| `Makefile` | Four lines; forwards every target to `entrypoint/Makefile` |
| `.github/workflows/checks.yaml` | On push/PR: `make lint`, `make check-go-modules`, `make unit-test`, plus Coveralls upload |
| `.github/workflows/license-check.yml` | License header enforcement |
| `.github/dependabot.yml` | Go module updates |
| `THIRD_PARTY_NOTICES` | Generated by `make third-party-licenses` (go-licenses) |
| `README.md` | Build instructions and build-arg reference |
| `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE` | Apache 2.0 project governance |

---

## 4. Image build: the multistage pipeline

All three Dockerfiles follow the same four-plus-one stage shape. The staging exists to
keep the shipped image free of compilers, kernel headers, and source trees.

```
go_builder ──────────────────────────────┐  (golang:1.26, `make build`)
                                          │
base ──────► driver-src ──────► driver-builder ──────► precompiled
  │              │                    │                    │
  │              │                    │                    └─ final shipped image
  │              │                    └─ runs install.pl, produces RPMs/DEBs
  │              └─ downloads + extracts MLNX_OFED_SRC, installs build deps
  └─ distro update, runtime deps, entrypoint binaries copied in
```

### 4.1 `go_builder`

Identical in all three Dockerfiles: `golang:1.26`, copy `go.mod`/`go.sum`, `go mod
download`, copy `entrypoint/`, then `make build`. The result is copied into later stages
as `/root/entrypoint`. `GOPROXY` is a build arg for air-gapped/proxied builds.

### 4.2 `base`

Distro update plus the packages needed to *run* (not build): `jq`, `iproute2`/`iproute`,
`kmod`, `procps`, `udev`, `ethtool`, `perl`, `pciutils`, `lsof`, `python3`. Then
`loader.sh`, `entrypoint.sh`, and the Go binary are added and `ENTRYPOINT
["/root/loader.sh"]` is set.

RHEL-specific: `rhsm.conf` is rewritten to read entitlements from
`/etc/pki/entitlement-host`, EPEL is imported, and on UBI 10+ there is a two-step GPG
bootstrap — the shipped `rpm` is too old to parse the ML-DSA post-quantum release key,
so `rpm`/`rpm-libs`/`rpm-sequoia` and the crypto policy packages are upgraded first,
*then* the new key is imported.

### 4.3 `driver-src`

Installs the build toolchain and downloads the source archive. This stage is also a
shippable target: it sets `CMD ["sources"]`, `NVIDIA_NIC_DRIVER_PATH`, and the
`doca-version` / `ofed-version` labels. **This is the dynamically-compiled image.**

Notable distro handling:

- **RHEL** — needs a subscription for gated repos. `docker build` requires
  `--build-context rhsm=/etc/pki/entitlement`, bind-mounted at
  `/etc/pki/entitlement-host`; `buildah` inherits host entitlements automatically. Build
  tools that `install.pl` needs *at container runtime* (`gcc`, `make`, `bison`, `flex`,
  `rpm-build`, `kernel-rpm-macros`, `elfutils-libelf-devel`, …) are installed here
  specifically to avoid subscription-gated `dnf` calls at pod startup.
- **Ubuntu** — pins GCC 12 above 20.04 (`ln -fs gcc-12 /usr/bin/gcc`), and installs
  `dh-dkms` only on 24.04+, where the `dh_dkms` helper moved out of the `dkms` package
  and `mlnx-ofed-kernel`'s `Build-Depends` would otherwise fail.
- **SLES** — `dkms` is not in the default repos, so an openSUSE Backports repo for the
  matching service pack is added. Also sets `allow_unsupported_modules 1` in
  `/etc/modprobe.d/10-unsupported-modules.conf`.

### 4.4 `driver-builder`

Installs the kernel headers for `D_KERNEL_VER` and runs `install.pl`. Common flags
across distros: `--without-depcheck --kernel <ver> --kernel-only --build-only
--with-mlnx-tools --copy-ifnames-udev`, plus exclusions for components the container does
not ship (`--without-knem`, `--without-iser`, `--without-isert`, `--without-srp`,
`--without-xpmem`). `D_BUILD_EXTRA_ARGS` allows CI to append flags.

Distro deltas: RHEL passes `--distro ${D_OS}` and `--kernel-sources`; Ubuntu uses the
`-modules`-suffixed exclusions (`--without-knem-modules`, …) and `--disable-kmp`; SLES
passes `--kernel-sources` and `-vvv`.

### 4.5 `precompiled`

The shipped precompiled image. RHEL builds this `FROM $D_FINAL_BASE_IMAGE` (e.g.
`ubi9/ubi`) so the DTK toolchain is discarded; Ubuntu and SLES build `FROM base`.

Steps: copy the packages out of `driver-builder`, install them (`rpm -ivh --nodeps` /
`apt-get install /root/*.deb`), install MOFED runtime requirements, `touch
modules.order` and `modules.builtin` to silence a `modprobe` warning, then `depmod
${D_KERNEL_VER}`. `NVIDIA_NIC_DRIVER_PATH` is set to empty and `CMD` to `precompiled`.

The RHEL stage additionally patches `/usr/share/mlnx_ofed/mod_load_funcs`: MLNX_OFED
26.07's `openibd` `check_if_ok_to_stop()` added `nvme` to a list with an inbox-escape
check that consults *container* `modinfo`. Since the image ships `kmod-mlnx-nvme`, inbox
`nvme` looks like an OFED module and the first inbox→MOFED swap exits 1 on NVMe-rooted
nodes. The `sed` drops `nvme` from that list, restoring 26.04 behavior.

---

## 5. Runtime: what happens when the pod starts

`ENTRYPOINT` is always `loader.sh`, which execs the Go binary (default) or the bash
script, passing `sources` or `precompiled` through.

### 5.1 The Go entrypoint (`entrypoint/`)

A standard-library `flag` CLI — no cobra — taking exactly one positional argument
(`precompiled`, `sources`, or `dtk-build`). Logging is zap/logr to stderr, with debug
level and an optional log file when `ENTRYPOINT_DEBUG=true`. SIGINT/SIGTERM cancel
contexts rather than being trapped ad hoc.

#### Package map

| Package | Responsibility |
|---|---|
| `cmd/` | Config load, logger, signal wiring, dispatch by mode |
| `internal/config/` | Environment → `Config` struct (`caarlos0/env`), module-list defaults |
| `internal/constants/` | Mode names, OS types, DTK flag names, `mlx5_core`, default RHEL/OCP versions |
| `internal/entrypoint/` | Orchestration: file lock, `preStart` / `start` / `stop` lifecycle, kernel-module preflight |
| `internal/driver/` | `PreStart`, `Build`, `Load`, `Unload`, `Clear`; distro package management; DKMS; `driver_dtk.go` for the DTK path |
| `internal/dtk/` | The sidecar `dtk-build` loop |
| `internal/netconfig/` | Save/restore SR-IOV, switchdev, representors, MTU, admin state |
| `internal/netconfig/{netlink,sriovnet}/` | Thin mockable wrappers over the upstream libraries |
| `internal/utils/{cmd,host,ready,udev}/` | Command runner, OS/kernel detection and `lsmod`/`rmmod`, readiness marker, embedded udev rules |
| `internal/wrappers/` | `os.*` facade so filesystem I/O can be mocked |
| `internal/version/` | ldflags-injected version string |
| `pkg/mofedmodules/` | Canonical storage and third-party RDMA module lists, shared with the Network Operator (hence `pkg/`, not `internal/`) |

#### Lifecycle

```
flock(LOCK_FILE_PATH)                    single instance guard
  │
  ├─ preStart
  │    ├─ commonCleanup                  clear readiness file, remove udev rules
  │    ├─ driver.PreStart                CA certs, Ubuntu Pro FIPS, GCC match, path validation
  │    ├─ handleKernelModules            unload nvidia_peermem; refuse to continue if
  │    │                                 storage / third-party RDMA modules are loaded
  │    │                                 and the corresponding unload flag is false
  │    ├─ netconfig.Save                 snapshot SR-IOV/switchdev state in memory
  │    ├─ createUDEVRulesIfRequired      only when old (short) naming scheme detected
  │    └─ driver.Build                   sources mode only
  │
  ├─ start
  │    ├─ driver.Load                    blacklist, DKMS, srcversion compare,
  │    │                                 `openibd restart`, bind-mount headers
  │    ├─ netconfig.Restore              when the driver was actually reloaded
  │    └─ readiness.Set                  touch the ready file
  │
  ├─ block until SIGTERM
  │
  └─ stop
       ├─ commonCleanup
       ├─ driver.Unload                  only if RESTORE_DRIVER_ON_POD_TERMINATION
       └─ driver.Clear                   unmount, drop temp inventory
```

Two contexts are used: the first signal cancels `startCtx` (unblocking the wait and
proceeding to `stop`), a second cancels the stop path so a wedged teardown can be
escaped.

#### Driver load mechanics

`Load` does not blindly reload. It compares the `srcversion` of the loaded `mlx5_core`
(from `/sys/module/mlx5_core/srcversion`) against `modinfo` for the packaged module and
skips the restart when they already match. When a restart *is* needed:

1. Write the modprobe blacklist to `OFED_BLACKLIST_MODULES_FILE` on the host, so the
   kernel cannot auto-reload OFED modules mid-swap. Removal is deferred.
2. Preload inbox dependencies from the host tree with `modprobe -d /host`, so plain
   `modprobe` calls inside `openibd` resolve.
3. Unload the mlx5 auxiliary modules (`mlx5_vdpa`, `mlx5_fwctl`, `mlx5_dpll`), which are
   alias-loaded and would otherwise race the restart. Reload them explicitly afterward.
4. Optionally `sed`-inject storage and third-party RDMA modules into `openibd`'s
   `UNLOAD_MODULES` list.
5. `/etc/init.d/openibd restart`.
6. Recursively bind-mount `/usr/src/` under `/run/mellanox/drivers/usr/src/` so other
   pods (e.g. GPU driver builds) can consume the kernel headers.

`Unload` (teardown, gated on `RESTORE_DRIVER_ON_POD_TERMINATION`) restores the inbox
driver with `mlnxofedctl --alt-mods force-restart`, preceded by `dkms remove` + `depmod`
when DKMS is in play — otherwise the `updates/dkms` module priority would defeat
`--alt-mods`.

#### Network configuration preservation

Replacing `mlx5_core` destroys and recreates every netdev, so `netconfig` snapshots and
replays: PF PCI address, admin state, MTU, IB GUID, eswitch mode, VF count; per-VF MAC,
administrative MAC, GUID, MTU, admin state; and per-representor switch id, port number,
VF id, name, MTU, admin state. **IP addresses, routes, VLANs, and tc rules are not
saved** — those are the CNI's responsibility.

Two mechanisms are worth knowing about:

- **Switchdev restore** is a four-step dance for older kernels: set eswitch mode to
  `legacy`, create the VFs, unbind them all, set mode back to `switchdev`, rebind.
- **Representor renaming** is two-phase. Names are first moved to temporary names of the
  form `t<switch_hash>p<port>v<vf>` (kept within the 15-character `IFNAMSIZ` limit),
  then to their original names, because a direct rename would collide when names swap.

#### Interface naming and the udev rule

DOCA-era drivers append an `np0`/`np1` port suffix to interface names, which breaks nodes
configured against pre-DOCA names. With `CREATE_IFNAMES_UDEV=true`, an embedded rule file
(`internal/utils/udev/70-mlnx-ofed-naming.rules`) is written to
`/host/etc/udev/rules.d/77-mlnx-net-names.rules`. For `mlx5_core` devices it rewrites
`ID_NET_NAME_PATH` and `ID_NET_NAME_SLOT`, handling both physical ports and VFs:

```
enp8s0f0np0    -> enp8s0f0
enp8s0f0np1v12 -> enp8s0f0v12
```

The rule is installed only when the node is detected as still using the short scheme, and
is removed on teardown.

#### Build caching

Runtime builds are expensive, so `sources` mode can cache packages in
`NVIDIA_NIC_DRIVERS_INVENTORY_PATH`, keyed
`<inventory>/<kernel-version>/<driver-version>/`. Validity is checked with an MD5
checksum and a `.buildconfig` fingerprint over `ENABLE_NFSRDMA`, `USE_DKMS`, and
`APPEND_DRIVER_BUILD_FLAGS`, so a configuration change invalidates the cache. With the
variable unset, an ephemeral `/tmp/nvidia_nic_driver_<timestamp>` directory is used and
removed on teardown.

### 5.2 The bash entrypoint (`entrypoint.sh`)

Functionally the same job, reachable with `USE_NEW_ENTRYPOINT=false`. Structural
differences worth knowing when comparing behavior or reading old logs:

- No `set -e`; failures propagate through an `exec_cmd` wrapper that exits on non-zero.
- One `trap terminate_event SIGSTOP SIGINT SIGTERM EXIT` instead of a lifecycle.
- Mode dispatch is a `case "$@"` near the bottom of the file, after ~1800 lines of
  function definitions.
- Ends with `sleep infinity & wait` to keep the pod alive.
- Uses `touch /tmp/entrypoint_done` as an idempotency guard: a container *restart*
  (as opposed to a new pod) exits 0 immediately. The Go version has no equivalent.
- State lives in global bash arrays rather than in memory structs, and there is no file
  lock.
- Logs via `timestamp_print` to stdout and `DEBUG_LOG_FILE`, not structured logging.

Two behaviors differ in ways that matter:

- The bash version restores SR-IOV configuration **only** when the driver was actually
  restarted. In Go, `Load` currently always reports `true` (`driver.go:349`), so
  `netconfig.Restore` runs unconditionally after load.
- If storage RDMA modules are loaded and `UNLOAD_STORAGE_MODULES` is not true, bash
  exits **0** early without attempting a reload; Go treats the same situation as a
  preflight failure.

`internal/entrypoint/module_deps.go` contains a more careful replacement for bash's
`unload_blocking_modules` — `/proc/modules` parsing, refcount and
`/sys/module/<m>/holders/` validation, and leaf-first topological unload ordering — but
it is currently exercised only by its tests and is not yet wired into the runtime path.

---

## 6. OpenShift: DTK (DriverToolKit) flow

On OpenShift the kernel-devel packages are not redistributable, so compilation must
happen inside Red Hat's DriverToolKit image, which ships matching headers. The driver
container therefore cannot build its own driver; it delegates to a DTK sidecar and the
two coordinate over a shared volume using flag files.

Enabled with `DTK_OCP_DRIVER_BUILD=true`. The shared directory is
`DTK_OCP_NIC_SHARED_DIR` (default `/mnt/shared-nvidia-nic-driver-toolkit`) suffixed with
a sanitized kernel version — non-alphanumeric characters replaced with `_`, matching the
NFD label format the Network Operator uses for volume paths.

```
main container                              DTK sidecar
──────────────                              ───────────
copy MLNX_OFED_SRC-<ver>/ ──────────► shared dir
copy entrypoint binary   ──────────►
write dtk.env            ──────────►
copy dtk_nic_driver_build.sh ──────►
touch dtk_start_compile  ──────────►        (polling every 3s)
                                            ├─ source dtk.env
                                            ├─ exec entrypoint dtk-build
                                            ├─ dnf install perl + build deps
                                            ├─ run install.pl in shared dir
        ◄────────────── touch dtk_done_compile_<ver>
                                            ├─ rm dtk_start_compile
(polling every 30s, up to 40 min)           └─ sleep until SIGTERM
copy RPMS/redhat-release-*/<arch>/*.rpm → inventory
install, load
```

The done flag is named `dtk_done_compile_<version-with-underscores>` so a stale flag from
a different driver version cannot be mistaken for a fresh build. `dtk.env` carries the
flag paths, shared dir, compiled driver version, `APPEND_DRIVER_BUILD_FLAGS`, and
`USE_DKMS` from the main container to the sidecar.

When both DKMS and DTK are active, the main container skips `dkms build`/`dkms install` —
the kmod RPMs from the sidecar already place the `.ko` files, so no headers are needed
locally.

`dtk_nic_driver_build.sh` retains a complete bash implementation of the sidecar for
`USE_NEW_ENTRYPOINT=false`. Both versions install a SIGTERM trap, since PID 1 ignores
SIGTERM without one and kubelet would otherwise have to wait out the grace period and
SIGKILL the sidecar.

---

## 7. Reference tables

### 7.1 Build arguments

Mandatory for every distro:

| Arg | Meaning | Example |
|---|---|---|
| `D_OS` | Target distribution | `ubuntu22.04`, `rhel9.2`, `rhcos4.16`, `sles15.5` |
| `D_ARCH` | Architecture | `x86_64` |
| `D_BASE_IMAGE` | Build base image (the DTK image on RHEL/RHCOS) | `ubuntu:22.04` |
| `D_KERNEL_VER` | Target kernel | `5.15.0-25-generic` |
| `D_DOCA_VERSION` | DOCA release | `2.9.1` |
| `D_OFED_VERSION` | MLNX_OFED driver version | `24.10-1.1.4.0` |

RHEL/RHCOS additionally require `D_FINAL_BASE_IMAGE` (the clean image the driver is
installed into). Obtain the DTK image for an OpenShift release with:

```bash
oc adm release info <OCP_VERSION> --image-for=driver-toolkit
```

Optional:

| Arg | Default | Meaning |
|---|---|---|
| `D_CONTAINER_VER` | `0` | Container build revision, surfaced as `NVIDIA_NIC_CONTAINER_VER` |
| `D_OFED_SRC_DOWNLOAD_PATH` | `/run/mellanox/src` | Where sources are extracted. Coupled to entrypoint logic |
| `D_OFED_SRC_TYPE` | `debian-` (Ubuntu), empty otherwise | Archive variant |
| `D_OFED_URL_PATH` | derived | Full archive URL, or a local `.tgz` |
| `D_ENABLE_DKMS` | `false` | Produce DKMS-enabled packages |
| `D_BUILD_EXTRA_ARGS` | — | Extra `install.pl` flags |
| `STIG_COMPLIANT` | `false` | Run `stig-fixer.sh` (RHEL/Ubuntu) |
| `GOPROXY` | — | Go module proxy for the `go_builder` stage |
| `D_APT_REMOVE` | — | apt source lists to drop (Ubuntu) |

The Dockerfiles carry defaults for all of these, and those defaults will very likely
fail on your system — override them.

### 7.2 Runtime environment variables

Set by the image; normally not overridden:

| Variable | Meaning |
|---|---|
| `NVIDIA_NIC_DRIVER_VER` | **Required, non-empty.** Driver version, from `D_OFED_VERSION` |
| `NVIDIA_NIC_DRIVER_PATH` | Source tree path; empty in precompiled images |
| `NVIDIA_NIC_CONTAINER_VER` | Container revision (logged only) |

Operational behavior:

| Variable | Default | Meaning |
|---|---|---|
| `USE_NEW_ENTRYPOINT` | `true` | Go entrypoint vs. `entrypoint.sh` (read by `loader.sh`) |
| `OFED_BLACKLIST_MODULES` | `mlx5_core:mlx5_ib:ib_umad:ib_uverbs:ib_ipoib:rdma_cm:rdma_ucm:ib_core:ib_cm` | Colon-separated modules to blacklist on the host during reload |
| `MLX5_AUXILIARY_MODULES` | `mlx5_vdpa mlx5_fwctl mlx5_dpll` | Space-separated aux modules to blacklist/unload before restart and reload after. Set explicitly empty to disable |
| `UNLOAD_THIRD_PARTY_RDMA_MODULES` | `false` | Blacklist and unload rdma-core provider modules (`qedr`, `efa`, `siw`, …) before reload. **The unload half is broken on 26.07 — see [9.3](#93-mod_load_funcs--the-unload-policy-api)** |
| `THIRD_PARTY_RDMA_MODULES` | `pkg/mofedmodules` list | Override that list |
| `UNLOAD_STORAGE_MODULES` | `false` | Unload storage modules (`ib_iser`, `nvme_rdma`, …) during restart. **Silently no-ops on 26.07 — see [9.3](#93-mod_load_funcs--the-unload-policy-api)** |
| `STORAGE_MODULES` | `pkg/mofedmodules` list | Override that list |
| `RESTORE_DRIVER_ON_POD_TERMINATION` | `false` | Restore the inbox driver on teardown |
| `CREATE_IFNAMES_UDEV` | `false` | Install the host udev rule stripping `np0`/`np1` suffixes |
| `ENABLE_NFSRDMA` | `false` | Build with NFS-RDMA/NVMe support and `modprobe rpcrdma` after load |
| `USE_DKMS` | `false` | Runtime DKMS registration and build |
| `UBUNTU_PRO_TOKEN` | — | Attach Ubuntu Pro and enable FIPS userspace |
| `APPEND_DRIVER_BUILD_FLAGS` | — | Extra `install.pl` flags at runtime |
| `NVIDIA_NIC_DRIVERS_INVENTORY_PATH` | — | Persistent build cache directory |
| `BIND_DELAY_SEC` | `4` | Sleep after VF creation/rebind |

Paths (rarely changed):

| Variable | Default |
|---|---|
| `DRIVER_READY_PATH` | `/run/mellanox/drivers/.driver-ready` |
| `LOCK_FILE_PATH` | `/run/mellanox/drivers/.lock` |
| `MLX_DRIVERS_MOUNT` | `/run/mellanox/drivers` |
| `SHARED_KERNEL_HEADERS_DIR` | `/usr/src/` |
| `MLX_UDEV_RULES_FILE` | `/host/etc/udev/rules.d/77-mlnx-net-names.rules` |
| `OFED_BLACKLIST_MODULES_FILE` | `/host/etc/modprobe.d/blacklist-ofed-modules.conf` |

DTK:

| Variable | Default |
|---|---|
| `DTK_OCP_DRIVER_BUILD` | `false` |
| `DTK_OCP_NIC_SHARED_DIR` | `/mnt/shared-nvidia-nic-driver-toolkit` |
| `DTK_OCP_COMPILED_DRIVER_VER`, `DTK_OCP_START_COMPILE_FLAG`, `DTK_OCP_DONE_COMPILE_FLAG` | set via `dtk.env` |

Debug:

| Variable | Default |
|---|---|
| `ENTRYPOINT_DEBUG` | `false` |
| `DEBUG_LOG_FILE` | `/tmp/entrypoint_debug_cmds.log` |
| `DEBUG_SLEEP_SEC_ON_EXIT` | `300` |

### 7.3 Host paths touched

The node root filesystem is mounted at `/host`. There is no `chroot`; host operations
use the `/host` prefix or tool flags such as `modprobe -d /host` and `depmod -b /host`.

| Path | Access | Purpose |
|---|---|---|
| `/host/etc/os-release` | read | Distro, RHEL vs RHCOS, version detection |
| `/host/etc/modprobe.d/blacklist-ofed-modules.conf` | write (temporary) | Blacklist during driver swap |
| `/host/etc/udev/rules.d/77-mlnx-net-names.rules` | write | Interface naming compatibility |
| `/host/lib/modules/<kver>/` | read/write | Host module tree; on RHEL, OFED modules are copied to `extra/mlnx-ofa_kernel`, labeled with `chcon … modules_object_t` for SELinux, `depmod -b /host`, and symlinked back |
| `/host/etc/apt/*`, `/host/etc/yum.repos.d/redhat.repo` | read | Copied into the container for RT and 64k-page kernels, whose packages live in extra repos |
| `/sys/bus/pci/drivers/mlx5_core/{bind,unbind}` | write | VF rebinding |
| `/sys/bus/pci/devices/<addr>/sriov_numvfs` | write | VF count restore |
| `/sys/class/net/*` | read | Netdev enumeration, MTU, `phys_port_name`, `phys_switch_id` |
| `/run/mellanox/drivers/` | write | Readiness file, lock file, bind-mounted headers |

### 7.4 External tools invoked

`install.pl` (build) · `/etc/init.d/openibd restart` (driver stack reload) ·
`mlnxofedctl --alt-mods force-restart` (inbox restore) · `modprobe`, `rmmod`, `lsmod`,
`modinfo`, `depmod` · `devlink dev eswitch show/set` · `ip link set`, `ip -j link show`
· `jq` · `udevadm info` · `ethtool --driver` · `dkms add|build|install|remove|status` ·
`apt-get` / `dnf` / `zypper` / `rpm` · `chcon` · `update-ca-certificates` /
`update-ca-trust` · `pro attach|enable`.

When `USE_DKMS=true`, a no-op `systemctl` stub (`#!/bin/sh` / `exit 0`) is written to
`/usr/local/bin/systemctl` and that directory is prepended to `PATH`. DKMS and the OFED
package scriptlets call `systemctl`, which fails noisily in a container with no systemd as
PID 1. Those calls are non-essential, so the stub is purely cosmetic log-noise removal and
failing to create it is non-fatal.

---

## 8. Development workflow

All Go targets run from `entrypoint/` (or from the root, which forwards them):

| Target | Action |
|---|---|
| `make build` | `CGO_ENABLED=0 go build -ldflags <version> -o build/entrypoint cmd/main.go` |
| `make unit-test` | `go test -cover`, excluding mocks and test helpers |
| `make lint` / `lint-fix` | golangci-lint |
| `make test` | `lint` + `unit-test` |
| `make generate-mocks` | mockery, per `.mockery.yaml` |
| `make check-go-modules` | `go mod tidy` then fail on a dirty diff |
| `make third-party-licenses` | Regenerate `THIRD_PARTY_NOTICES` |
| `make copyright-check` | License header check |

Version information is injected via ldflags from `Makefile.version`: version (from
`VERSION` or the latest git tag), commit, tree state (`clean`/`dirty`), release status,
and a UTC build timestamp.

Tests use Ginkgo/Gomega with mockery-generated mocks in `<package>/mocks/`. Every
side-effecting boundary is behind an interface for this reason — `cmd.Interface` for
process execution, `wrappers.OSWrapper` for filesystem access, `netlink.Lib` and
`sriovnet.Lib` for the network libraries. `internal/internal.go` is an empty package
that exists solely as an anchor for mockery's recursive configuration.

---

## 9. The DOCA OFED API surface

This repository is a *consumer* of MLNX_OFED. There is no library or RPC boundary — the
contract is a set of scripts, command-line flags, filesystem paths, and naming
conventions. That makes the contract easy to break silently on an OFED version bump, so
this section enumerates every touchpoint.

Literals below were verified against both 26.07-0.7.7.0 source archives — the RPM tree
(`MLNX_OFED_SRC-26.07-0.7.7.0.tgz`) and the debian tree
(`MLNX_OFED_SRC-debian-26.07-0.7.7.0.tgz`). Unqualified line references point into the
RPM tree; debian differences are called out with their own line numbers.

> **Note** Both archives extract to the *same* directory name,
> `MLNX_OFED_SRC-26.07-0.7.7.0/`, with no `debian` marker. Unpacking them into one parent
> directory silently merges them, and the second `install.pl` wins. Extract them into
> separate parents when comparing.

| Interface | Kind | Used by | Consumed at |
|---|---|---|---|
| `install.pl` | CLI (Perl) | Dockerfiles, `driver.go`, `entrypoint.sh`, DTK sidecar | Image build and pod startup |
| `/etc/init.d/openibd` | SysV init script | `driver.go`, `entrypoint.sh` | Pod startup |
| `/usr/share/mlnx_ofed/mod_load_funcs` | Sourced shell library | Patched by `RHEL_Dockerfile`, `sed`-injected at runtime | Both |
| `/usr/sbin/mlnxofedctl` | CLI (from `mlnx-tools`) | `driver.go`, `entrypoint.sh` | Pod teardown |
| `ofed_info` | CLI (from `ofed-scripts`) | not used by this repo | — |
| `ofed_uninstall.sh` | CLI | not used by this repo | — |
| Package output paths | Filesystem convention | Dockerfile `COPY` globs, `driver.go` | Image build |
| Module install paths | Filesystem convention | RHEL host module tree sync | Pod startup |
| `srcversion` / `modinfo` | Kernel metadata | Reload-decision logic | Pod startup |

### 9.1 `install.pl` — the build API

The only tool that ever compiles the driver. Always invoked as
`<src>/install.pl --kernel-only --build-only …`, which makes it a pure package builder
that installs nothing.

**There are two different `install.pl` scripts.** The RPM archive
(`MLNX_OFED_SRC-<ver>.tgz`, used by RHEL/RHCOS/SLES) and the debian archive
(`MLNX_OFED_SRC-debian-<ver>.tgz`, selected by `D_OFED_SRC_TYPE=debian-` for Ubuntu) ship
scripts that share a command-line vocabulary but not an implementation. The RPM script
has no DEB support at all, and the two track DKMS state in different variables:

| | RPM `install.pl` | debian `install.pl` |
|---|---|---|
| Output directory | `$CWD/RPMS/$dist_rpm/$arch` (`:584`) | `$CWD/DEBS/$distro/$arch` (`:836`) |
| DEB support | none | yes |
| Distro guard | accepts any detected distro | **exits `1`** unless the distro matches `debian`, `ubuntu`, `uos`, or `velinux` (`:492-495`) |
| DKMS state variable | `$build_dkms_packages`, init `1` (`:96`) | `$with_dkms`, init `1` (`:92`) |
| `--without-dkms` | `$build_dkms_packages = 0` | `$with_dkms = 0`, `$force_dkms = 0` (`:288-291`) |
| `--copy-ifnames-udev` | `$do_copy_udev = 1` **and** `$build_dkms_packages = 0` (`:316-318`) | `$do_copy_udev = 1` only (`:348-349`) |
| `--force-dkms` | not present | present (`:300`), bypasses the auto-disable below |
| DKMS auto-disable | — | `$with_dkms = 0` if the kernel sources are not owned by a `.deb` (`:456-468`), or on UOS (`:497-499`) |

The distro guard makes the two scripts strictly non-interchangeable: pointing an Ubuntu
build at the RPM archive, or a RHEL build at the debian archive, fails rather than
degrading. Flag descriptions below are common to both unless noted.

The debian DKMS auto-disable is narrower than it first appears. The condition is
ownership, not presence:

```perl
# disable DKMS if given kernel was not installed from deb package
if (not $force_dkms and $with_dkms and -d "$kernel_sources/scripts") {
	...
	system("$DPKG -S '$src_path' >/dev/null 2>&1");
	...
	if ($sig or $res) {
		print_and_log("DKMS is not supported for kernels which were not installed as DEB.\n", ...);
		$with_dkms = 0;
```
— debian `install.pl:455-468`

Since the Ubuntu Dockerfile installs `linux-headers-${D_KERNEL_VER}` with `apt`, and the
runtime path does the same, `dpkg -S` succeeds and DKMS survives. The check exists to
catch custom or self-compiled kernels, where it will silently downgrade a
`D_ENABLE_DKMS=true` build to static modules unless `--force-dkms` is passed.

**Contract:**

| Aspect | Value |
|---|---|
| Output directory | `$CWD/RPMS/$dist_rpm/$arch` — `install.pl:584`. `$dist_rpm` is the *literal RPM name* of the distro release package, e.g. `redhat-release-9.4-0.4.el9`, `sles-release-15.6-55.1`. This is why the Dockerfiles must glob `RPMS/redhat-release-*/${D_ARCH}/` rather than name a fixed directory |
| Debian output | `$CWD/DEBS/$distro/$arch`, globbed as `DEBS/${D_OS}/*/*.deb` |
| Source input | `$CWD/SRPMS/` — `install.pl:582` |
| Logs | `$TMPDIR/OFED.<pid>.logs/`, with `general.log` and per-package `*.rpmbuild.log` |
| Kernel sources | `--kernel-sources`, default `/lib/modules/<kver>/build` |
| Rebuild skip | An already-matching RPM in `RPMS/` is not rebuilt |
| Requires root | Yes, *except* under `--build-only`, `--print-available`, `--print-distro` |

**Exit codes** (`install.pl:45-53`):

| Code | Meaning |
|---|---|
| `0` | Success; also `--help`, `--script-version`, `--print-distro` |
| `1` | General failure, unsupported option, incompatible flag combination, build failure |
| `172` | Missing prerequisites, or not root |
| `174` | Non-OFED packages depend on OFED (uninstall blocked) |

**Flags this repository actually passes:**

| Flag | Purpose |
|---|---|
| `--build-only` | Build packages, do not install. **Requires** `--kernel-only` or `--eth-only` |
| `--kernel-only` | Kernel-space packages only. Incompatible with `--user-space-only` |
| `--kernel <kver>` | Target kernel; defaults to `uname -r` |
| `--kernel-sources <path>` | Kernel build tree (RHEL and SLES pass it explicitly) |
| `--distro <name>` | Override distro autodetection, e.g. `rhel9.4` |
| `--without-depcheck` | Skip distro dependency verification |
| `--with-mlnx-tools` | Include `mlnx-tools`, which provides `mlnxofedctl` |
| `--with-ofed-scripts` | Include `ofed-scripts`, which provides `openibd` and `ofed_info` |
| `--copy-ifnames-udev` | Copy legacy interface-naming udev rules. **See the caveat below** |
| `--without-dkms` | Build static/binary modules instead of DKMS packages |
| `--disable-kmp` | Build non-KMP kernel RPMs (Ubuntu, and the DTK non-DKMS path) |
| `--without-<pkg>` | Exclude a component: `iser`, `isert`, `srp`, `knem`, `xpmem`, `kernel-mft`, `mlnx-rdma-rxe`, and NFS-RDMA/NVMe when `ENABLE_NFSRDMA=false` |
| `-vvv` | Verbosity (SLES build only) |

**Package-name suffixes.** The same component has up to three package names, and which
one to exclude depends on the build mode. Getting this wrong means the exclusion is
silently ignored:

| Form | Meaning | Example |
|---|---|---|
| base name | KMP package (RHEL default) | `--without-iser` |
| `-modules` | Non-KMP per-kernel binary module package | `--without-iser-modules` |
| `-dkms` | DKMS source package installed under `/usr/src/<name>-<version>/` | `--without-xpmem-dkms` |

This is why the RHEL Dockerfile uses `--without-iser` while Ubuntu and SLES use
`--without-iser-modules`, and why the bash entrypoint builds the suffix dynamically into
a `pkg_suffix` variable (`-modules` on Ubuntu, empty elsewhere).

> **Warning — on RPM builds, `--copy-ifnames-udev` also disables DKMS packages**
>
> In the RPM `install.pl` (verified on 26.07), `--copy-ifnames-udev` does two things:
>
> ```perl
> } elsif ( $cmd_flag eq "--copy-ifnames-udev" ) {
>     $do_copy_udev = 1;
>     $build_dkms_packages = 0; # abuse --copy-ifnames-udev option
> ```
> — `install.pl:316-318`
>
> `$build_dkms_packages` is initialized to `1` at `install.pl:96` and is only ever
> assigned `0` (lines 318 and 320); nothing restores it. So on RPM builds, passing
> `--copy-ifnames-udev` has the same effect on package selection as `--without-dkms`.
>
> This affects the paths that pass the flag *and* intend to build DKMS packages:
> `RHEL_Dockerfile` and `SLES_Dockerfile` pass it in both `D_ENABLE_DKMS` branches, and
> `internal/dtk/build.go:98` passes it unconditionally while the DKMS path at line 104
> deliberately omits `--without-dkms`. Those combinations cannot emit DKMS packages: they
> build ordinary binary module packages while reporting a DKMS build. Do not rely on
> `D_ENABLE_DKMS=true` for RHEL or SLES images, or on the DTK sidecar's DKMS mode.
>
> Note that `--disable-kmp` is unrelated and does *not* suppress DKMS: the
> `$build_dkms_packages` block at `install.pl:1483` runs after the `$kmp` block at `:1462`
> and overwrites `$kernel_rpm` regardless of KMP mode.
>
> **Not affected:** Ubuntu, which uses the debian `install.pl` and its separate
> `$with_dkms` variable (see below); and the non-DTK *runtime* build path (`driver.go`,
> `entrypoint.sh:481`), which does not pass the flag at all.

### 9.2 `openibd` — the driver lifecycle API

Installed at `/etc/init.d/openibd`. This is the interface used to swap the running driver
stack; the container never loads the OFED modules by hand.

A naming trap worth internalizing: `openibd` and `mod_load_funcs` ship in the
**`mlnx-ofa_kernel`** family — specifically the **`mlnx-ofed-kernel-utils`** binary
package on debian — built from the `ofed_scripts/` *directory* of the `mlnx-ofed-kernel`
source tree. They are **not** in the similarly named **`ofed-scripts`** package, which
provides only `ofed_info`. Verified in the 26.07 debian archive:
`mlnx-ofed-kernel_2607.0.100.orig.tar.xz` contains
`ofed_scripts/{openibd,openibd.service,mod_load_funcs}`, and
`debian/mlnx-ofed-kernel-utils.install` is the only packaging manifest that references
`openibd`, while `ofed-scripts_26.07.OFED.26.07.0.7.7.orig.tar.gz` contains just
`ofed_info`.

This distinction decides how much of the pipeline survives the DOCA 3.6 removal of the
`ofed_scripts` package: the driver *load* interfaces (`openibd`, `mod_load_funcs`) and
`mlnxofedctl` (from `mlnx-tools`) all live outside `ofed_scripts` and are unaffected.
Only `install.pl`, the *build* interface, is lost.

**Verbs** (`SOURCES/ofed_scripts/openibd:52-77`):

```
start | force-start | stop | force-stop | restart | force-restart | status
```

The `force-` variants set `FORCE=1` and strip the prefix before dispatch. This repo uses
only `restart`.

**Exit codes:** `0` on success (including `status` when `mlx5_core` is loaded); `1` on
usage error, start failure, active VFs, a `check_if_ok_to_stop` refusal, or a `stop`
request when `ALLOW_STOP` is not `yes` and `force` was not used.

**Configuration and extension points**, none of which this repo currently uses, but all
of which are available if the `sed`-based patching becomes untenable:

| Mechanism | Detail |
|---|---|
| `/etc/infiniband/openib.conf` | Overridable via `OPENIBD_CONFIG`. Supplies `ONBOOT`, `ALLOW_STOP`, `FORCE_MODE`, the per-module `*_LOAD` switches, `RUN_MLNX_TUNE`, `RUN_SYSCTL`, `ENABLE_FW_TRACER` |
| Hook scripts | `OPENIBD_PRE_START` (default `/etc/infiniband/pre-start-hook.sh`), `OPENIBD_POST_START`, `OPENIBD_PRE_STOP`, `OPENIBD_POST_STOP` |
| `/etc/profile.d/ofed.sh` | Sourced if present |

`openibd` dot-sources `mod_load_funcs` and exits `1` if it is missing, which is why the
RHEL Dockerfile's patch step hard-fails when the file is absent.

### 9.3 `mod_load_funcs` — the unload policy API

Installed at `/usr/share/mlnx_ofed/mod_load_funcs`. A sourced shell library holding the
module load order and, more importantly for this repo, the unload policy. It is the most
version-fragile interface in use, because this repo modifies it with `sed`.

Two independent modifications happen:

1. **At image build (RHEL only)** — the `nvme` workaround described in
   [section 4.5](#45-precompiled). The target is a literal module list:

   ```sh
   for mod in ib_isert nvme_rdma nvmet_rdma nvme rpcrdma xprtrdma ib_srpt; do
   ```
   — `SOURCES/ofed_scripts/mod_load_funcs:1342`

   `check_if_ok_to_stop()` blocks the unload if any module in that list is loaded with a
   non-zero refcount. `nvme` carries an inbox escape: the block is skipped if the module
   is not an OFED module, or if the loaded `mlx_compat` has the same `srcversion` as the
   one on disk. Since the precompiled image ships `kmod-mlnx-nvme`, the OFED check
   consults *container* `modinfo` and inbox `nvme` looks like an OFED module — so on an
   NVMe-rooted node the first inbox→MOFED swap fails. The Dockerfile drops `nvme` from
   the list, restoring 26.04 behavior. Unloading still begins from `ib_core`/`mlx5_core`
   and never `rmmod`s the local-disk `nvme` driver.

2. **At runtime** — `UNLOAD_STORAGE_MODULES=true` appends its module list to the
   `UNLOAD_MODULES` shell variable with `sed`, targeting
   `/usr/share/mlnx_ofed/mod_load_funcs` and falling back to `/etc/init.d/openibd`.
   Success is then confirmed by grepping for a marker module. **On 26.07 this no longer
   works** — see the warning below.

**`check_mlnx_ofed_module()`** is the OFED-versus-inbox discriminator used throughout:
a module counts as OFED if `modinfo -Fdepends <mod>` lists `mlx_compat`.

> **Warning — the 26.07 unload rewrite breaks the runtime module injection**
>
> Through 25.07, `mod_load_funcs` exposed a flat `UNLOAD_MODULES` variable listing every
> module to remove. In 26.07 that variable is **gone** (zero occurrences), replaced by a
> recursive `unload_modules_rec()` walk seeded from `ib_core`, `mlxfw`, `mlx5_core`,
> `mlx_compat`, and `memtrack`. The RPM and debian copies of `mod_load_funcs` are
> byte-identical in 26.07, so this applies to every distro.
>
> Both entrypoints inject with a `sed` address of
> `/^[[:space:]]*UNLOAD_MODULES="[a-z]/`, which matches **0 lines** in 26.07. The
> injection silently does nothing, and the verification step does not reliably catch it:
>
> | Path | Verification | Result on 26.07 |
> |---|---|---|
> | `UNLOAD_STORAGE_MODULES`, bash (`entrypoint.sh:566`) | `grep ib_isert <script> -c` | **Passes** — `ib_isert` appears on the unrelated line 1342, so the storage unload silently no-ops |
> | `UNLOAD_STORAGE_MODULES`, Go (`driver.go:2178`) | `grep <StorageModules[0]> <script> -c` | **Passes** — the default first element `ib_iser` substring-matches `ib_isert` on line 1342; same silent no-op |
> | `UNLOAD_THIRD_PARTY_RDMA_MODULES`, bash (`entrypoint.sh:586`) | `grep -q "UNLOAD_MODULES=.*<first_mod>"` | **Fails** → `exit_entryp 1`, so the container aborts rather than starting degraded |
>
> Net effect on 26.07: `UNLOAD_STORAGE_MODULES=true` appears to succeed but unloads
> nothing extra, and `UNLOAD_THIRD_PARTY_RDMA_MODULES=true` hard-fails the bash
> entrypoint. Adapting the injection to `unload_modules_rec()` — or driving it through
> `openib.conf` instead of `sed` — is the real fix.
>
> The Go entrypoint does not implement the injection half of
> `UNLOAD_THIRD_PARTY_RDMA_MODULES` at all: it only writes the modules to the modprobe
> blacklist (`driver.go:864-868`). That makes it immune to the hard failure, but it also
> means step 2 of the two-step behavior documented in `config.go:68-71` is missing.

### 9.4 `mlnxofedctl` — the inbox restore API

Shipped in the `mlnx-tools` package at `/usr/sbin/mlnxofedctl`, which is why every build
passes `--with-mlnx-tools`. It is a wrapper around `openibd` accepting the same verbs.

This repo invokes exactly one form, on pod teardown when
`RESTORE_DRIVER_ON_POD_TERMINATION=true`:

```
/usr/sbin/mlnxofedctl --alt-mods force-restart
```

`--alt-mods` (documented as `-a|--altmods`) is the container-oriented feature that makes
inbox restore possible: it loads modules from **`/host/lib/modules`** instead of
`/lib/modules`, in a separate mount namespace. Without it there would be no way to bring
back the node's inbox driver from inside the container.

Presence is probed with `Stat("/usr/sbin/mlnxofedctl")` before use, and the restore is
skipped with a log message if the binary is absent.

The DKMS interaction is worth noting: DKMS installs modules into
`/lib/modules/<kver>/updates/dkms/`, which has *higher* modprobe priority than the inbox
path, so `--alt-mods` cannot reach the inbox modules. Both entrypoints therefore run
`dkms remove` plus `depmod` before calling `mlnxofedctl`.

### 9.5 Versioning conventions

Four different version formats appear, and they are not interchangeable.

**The MLNX_OFED release string** — `26.07-0.7.7.0`, supplied as `D_OFED_VERSION` and
surfaced at runtime as `NVIDIA_NIC_DRIVER_VER`. `26.07` is the release train (year 2026,
month 07); `0.7.7.0` is the internal build sequence. It appears verbatim in the source
directory name (`MLNX_OFED_SRC-26.07-0.7.7.0`), the archive name, the image tag, and the
build-cache key, so it must match exactly across all of them.

**`BUILD_ID`** — at the root of the source tree. First line identifies the build, followed
by per-component source URLs:

```
OFED-internal-26.07-0.7.7:
```

**Package version strings** — three patterns coexist in `SRPMS/`:

| Pattern | Example | Reading |
|---|---|---|
| Compressed train | `mlnx-ofa_kernel-2607.0.100-1` | `2607` = the 26.07 train, then component build sequence |
| `OFED.` release tag | `ofed-scripts-26.07-OFED.26.07.0.7.7` | Full OFED release in the RPM Release field |
| Independent upstream | `kernel-mft-4.37.0-154`, `ucx-1.22.0.2608140153` | Component's own versioning, sometimes with a datestamp |

The `2607`-style compressed form also shows up in DKMS paths, e.g.
`/usr/src/mlnx-ofa_kernel-2607.0.100-1/`.

**Runtime version reporting** — what to query on a live node:

| Source | Output |
|---|---|
| `ofed_info -s` | `OFED-internal-26.07-0.7.7:` |
| `ofed_info -n` | `26.07-0.7.7` |
| `modinfo mlx5_core` → `version:` | The driver's declared version string |
| `modinfo -F srcversion mlx5_core` | Module ABI fingerprint |
| `/sys/module/mlx5_core/srcversion` | Same fingerprint, for the *loaded* module |
| `ethtool -i <dev>` | `driver`, `version`, `firmware-version` |

The `srcversion` pair is load-bearing rather than informational. Both entrypoints compare
`modinfo -F srcversion` (packaged) against `/sys/module/<mod>/srcversion` (loaded) for
`mlx5_core`, `mlx5_ib`, and `ib_core`, and skip the `openibd restart` entirely when they
match. That is what makes a pod restart idempotent instead of disruptive.

### 9.6 Package and path conventions

**Components in 26.07** (27 source RPMs). Kernel-module producers are the ones that
matter here:

| Package | Ships | This repo |
|---|---|---|
| `mlnx-ofa_kernel` | Core mlx5 / IB stack, `mlx_compat` | **built** |
| `mlnx-nvme` | NVMe-oF over RDMA | **built** (excluded when `ENABLE_NFSRDMA=false`) |
| `mlnx-nfsrdma` | NFS over RDMA | **built** (same) |
| `mlnx-tools` | `mlnxofedctl` | **built** |
| `ofed-scripts` | `openibd`, `mod_load_funcs`, `ofed_info` | **built** |
| `iser`, `isert`, `srp` | Storage ULP initiators/targets | excluded |
| `xpmem`, `kernel-mft`, `virtiofs`, `rshim` | Cross-process memory, MFT, virtio-fs, BlueField | excluded |

Userspace components present but irrelevant to a kernel-only build: `rdma-core`,
`mlnx-ethtool`, `mlnx-iproute2`, `libvma`, `libxlio`, `ucx`, `perftest`, `sockperf`,
`multiperf`, `dpcp`, `ibdump`, `ibsim`, `ibarr`, `mlx-steering-dump`, `opensm`,
`openvswitch`, `openmpi`.

Three notes on exclusion flags. The `-modules` names the Ubuntu build passes
(`--without-knem-modules`, `--without-srp-modules`, `--without-kernel-mft-modules`,
`--without-iser-modules`, `--without-isert-modules`) are all still recognized by the
debian `install.pl` in 26.07, so those exclusions do take effect. `knem` and
`mlnx-rdma-rxe` are excluded by the Dockerfiles and `entrypoint.sh` but ship no sources in
either 26.07 archive, making those particular flags harmless no-ops. And because
`--kernel-only` is always in effect, most userspace packages are never candidates
regardless of `--without-*` flags.

**Module install paths**, which the RHEL host-module-tree sync depends on:

| Mode | Path |
|---|---|
| Static / kmod, RHEL | `/lib/modules/<kver>/extra/mlnx-ofa_kernel/…` |
| Static / kmod, SLES and Fedora | `/lib/modules/<kver>/updates/…` |
| DKMS | `/lib/modules/<kver>/updates/dkms/` |
| DKMS source tree | `/usr/src/ofa_kernel-<ver>/source/`, with `/usr/src/mlnx-ofa_kernel-<ver>` symlinked to it |
| Per-ULP DKMS source | `/usr/src/<component>-<ver>/` |

On RHEL the container copies its module tree to
`/host/lib/modules/<kver>/extra/mlnx-ofa_kernel`, applies
`chcon -R -t modules_object_t`, runs `depmod -b /host`, and symlinks the container path
back at the host copy — so that host-context `modprobe` can find the modules under
SELinux enforcement.

`/usr/src/ofa_kernel/default` is a symlink the container rewrites to a relative target
(`<arch>/<kver>`) when it finds it pointing at an absolute path, because the absolute
form does not resolve once the tree is bind-mounted elsewhere.
