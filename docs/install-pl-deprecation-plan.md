# Planning: replacing `install.pl` before DOCA 3.6

**Status:** draft for discussion. **Deadline driver:** DOCA 3.6, expected October 2026.

DOCA 3.6 formally removes the `ofed_scripts` package from all DOCA-Host profiles and
packs. This repository builds NVIDIA NIC kernel modules exclusively by invoking
`install.pl --kernel-only --build-only` from the `MLNX_OFED_SRC-<version>.tgz` archive,
and `install.pl` is one of the removed components. We need a replacement build path.

This document scopes the impact, states what a replacement must do, evaluates the
candidates, and lists the questions we need NVIDIA to answer.

---

## 1. What is being removed

Per the DOCA-Host deprecation notice, removal of `ofed_scripts` affects:

| Component | Stated migration |
|---|---|
| `install.pl` | **none stated** |
| `ofed_info` / `ofed_rpm_info` | `apt info doca-networking` / `yum info doca-networking` |
| `ofed_uninstall.sh` | Preserved in older versions for backward compatibility on initial installs; not used for upgrades between DOCA-Host versions (2.6+) |
| `sysinfo-snapshot.py` | `doca-sosreport` |
| `vendor_pre_uninstall.sh` / `vendor_post_uninstall.sh` | none stated |

`openibd` is explicitly **not** part of `ofed_scripts` and is unaffected.

### Confirmed planning inputs

- **The `MLNX_OFED_SRC-<version>.tgz` source archive remains available.** Confirmed by the
  team. This is the load-bearing assumption for the whole plan: both viable options below
  consume that archive, so our download step, version pinning, image tags, and
  `release_manifests` all stay as they are. What we lose is the *orchestrator* inside the
  archive, not the sources.
- **`openibd`, `mod_load_funcs`, and `mlnxofedctl` all survive** (see §2), so the driver
  runtime path is unaffected.

---

## 2. Blast radius for this repository

Measured against the 83 tracked files:

| Component | Tracked files referencing it | Impact |
|---|---|---|
| `install.pl` | **9** | **Breaks.** This is the entire problem |
| `ofed_info` | 0 | none |
| `ofed_rpm_info` | 0 | none |
| `ofed_uninstall.sh` | 0 | none |
| `sysinfo-snapshot.py` | 0 | none |
| `vendor_*_uninstall.sh` | 0 | none |

We use exactly one of the six removed components, so the published migration advice
(`doca-networking` metadata queries, `doca-sosreport`) is irrelevant to us. The one
component we do use is the one with no stated migration path.

**What survives.** The runtime half of the container is untouched, because none of its
interfaces come from `ofed_scripts`:

| Interface | Ships in | Referenced by |
|---|---|---|
| `/etc/init.d/openibd` | `mlnx-ofa_kernel` (base RPM) / `mlnx-ofed-kernel-utils` (deb) | 7 files |
| `/usr/share/mlnx_ofed/mod_load_funcs` | same | 4 files |
| `/usr/sbin/mlnxofedctl` | `mlnx-tools` | 3 files |

Verified directly against the 26.07 tree. On the RPM side the owner is the **base
`mlnx-ofa_kernel` package itself**, not an `-utils` subpackage: the spec sets
`%global utils_pname %{_name}` with `%{_name}` defaulting to `mlnx-ofa_kernel`, so
`%files -n %{utils_pname}` *is* the base package. It owns `/etc/init.d/openibd`,
`openibd.service`, `/usr/share/mlnx_ofed/mod_load_funcs`, `/etc/infiniband/{openib.conf,
mlx5.conf,info}`, `/etc/modprobe.d/mlnx.conf`, the SF and auxdev udev renamers, and
`mlnx_interface_mgr.sh`; its `%post` is what enables the service. On debian the owner is
`mlnx-ofed-kernel-utils`, per `debian/mlnx-ofed-kernel-utils.install`. Both are built from
the **kernel driver source**, not from the tools package.

The `ofed-scripts` payload contains **neither file**. Its complete contents are
`install.pl`, `common.pl`, `install_deb.pl`, `mlnxofedinstall`, `mlnxofedinstall_deb.pl`,
`ofed_info`, `ofed_rpm_info`, `sysinfo-snapshot.py`, `uninstall.sh`, `uninstall_deb.sh`,
`vendor_pre_uninstall.sh`, `vendor_post_uninstall.sh`, `mlnx_add_kernel_support.sh`,
`is_kmp_compat.sh`, and `check_syntax` — essentially the §1 deprecation list and nothing
else. Neither `mlnx-ofa_kernel.spec` nor `debian/control` declares any dependency on it.

This is easy to get backwards because both files live under a directory named
`ofed_scripts/` *inside the kernel source tree* (`source/ofed_scripts/openibd`), which
reads like the package of the same name — the same trap flagged under Option B. So
"`openibd` is unaffected" is a structural fact about where it happens to be packaged, not
a commitment NVIDIA has undertaken to keep.

**Confirmed in the field.** A DOCA-Host 26.01-1.0.0 node (`orch-dev-a100-003`, DKMS
install) has no `ofed_info` at all — `command not found` — yet `/etc/init.d/openibd
restart` unloads and reloads the stack normally. The two are packaged independently on a
real host today, which is the situation DOCA 3.6 generalises.

**Conclusion: this is a build-time problem only.** Driver load, unload, restart, inbox
restore, SR-IOV preservation, and readiness all keep working unchanged. Scoping the work
to the build path is what makes this tractable.

---

## 3. Requirements a replacement must satisfy

Derived from how we actually invoke `install.pl` today — the complete flag-by-flag
inventory is in [Appendix A](#appendix-a--complete-installpl-flag-inventory); see also
[`repository-guide.md` §9.1](./repository-guide.md).

| ID | Requirement | Why |
|---|---|---|
| **R1** | Compile against an **explicitly named kernel headers tree**, never against whatever `uname -r` reports | See the note below the table; this is what `--kernel` and `--kernel-sources` buy us today |
| **R2** | Build only, never install | Packages are copied into a separate clean final stage |
| **R3** | Output consumable as **loose packages** | Dockerfile `COPY` globs, `copyBuildArtifacts`, and the inventory cache all assume individual files |
| **R4** | Exclude components | We drop `iser`, `isert`, `srp`, `knem`, `xpmem`, `kernel-mft`, and conditionally NFS-RDMA/NVMe |
| **R5** | Cover RHEL, RHCOS, SLES, Ubuntu, plus **RT and 64k-page** kernel variants | Current support matrix in `release_manifests/` |
| **R6** | Work with **no network / no subscription-gated package installs at container run time** | `sources` mode builds at pod startup on customer nodes; RHEL entitlements are a build-host-only luxury |
| **R7** | Pin an **exact** OFED version reproducibly | Image tags and `release_manifests` encode `driver_version`; the build cache fingerprints it |
| **R8** | Support both **DKMS and static** module output | `D_ENABLE_DKMS` / `USE_DKMS` |
| **R9** | Work when the build runs in a **separate container** from the consumer | The OpenShift DTK sidecar handshake |

**On R1.** A container has no kernel of its own; it shares the kernel of whatever host it
runs on. Inside the CI builder, `uname -r` therefore reports the *build machine's* kernel,
which has nothing to do with the node the image targets. What we compile against is not a
kernel at all but a **headers tree in the builder's own filesystem** — `kernel-devel` on
RHEL and SLES, `linux-headers-<ver>` on Ubuntu — installed for the version named by
`D_KERNEL_VER` and reachable at `/lib/modules/<ver>/build`. That is an ordinary filesystem
artifact and can be any version, which is precisely what makes a "cross-kernel" build
possible; nothing is being cross-compiled in the usual sense.

So the requirement on a replacement is narrower than it first sounds: the target version
and its headers path must both be **explicit inputs, never inferred**. `install.pl` gives
us `--kernel` and `--kernel-sources`, `doca-kernel-support` has `-k`, and `dkms build` has
`-k`. The failure mode to watch for is a tool that quietly falls back to `uname -r`, which
the underlying build recipes themselves do — see `KVERSION` and `kernelver` in the Option B
table below. That default is correct on a host and wrong in CI.

Note the asymmetry with run time: when the driver container starts on a node it *does*
share that node's kernel, so `uname -r` is the right answer there, and the entrypoint uses
it via `host.GetKernelVersion`. **R1 constrains build time only.**

---

## 4. Options

### Option A — `doca-kernel-support` from the `doca-extra` package (recommended)

NVIDIA's own rebuild tool, shipped as a 22 KB `noarch` package
(`doca-extra-2607.0.10-1.el9`) containing one script:

```
/opt/mellanox/doca/tools/doca-kernel-support
/opt/mellanox/doca/tools/resources/find-provides.ksyms
/usr/share/doc/doca-extra/doca-kernel-support.adoc
```

Mechanically it is a wrapper over the same parameters the component spec files already
expose:

```sh
rpmbuild --rebuild --define "KVERSION $KVERS" --define "K_SRC $KSRC" \
         --define "KMP $KMP" --with building-kmods ... "$srpm"
```
— `doca-kernel-support:431`; the deb path runs `dpkg-buildpackage` against
`SOURCES/<pkg>_*.orig.tar*`.

**Flag mapping from our current invocation:**

| Today | Replacement |
|---|---|
| `--kernel <kver>` | `-k <kver>` / `--kernel`, or `KERNEL_VERSION=` |
| `--kernel-sources <path>` | `-s <path>` / `--kernel-source`, or `KERNEL_SOURCE=` (overrides `-k`) |
| `--build-only --kernel-only` | implicit; build-only is all the tool does |
| `--distro <name>` | auto-detected; no override flag |
| `--disable-kmp` | `--define KMP` chosen internally per distro |
| `--without-<pkg>` | **no equivalent** |
| module signing | `WITH_MOD_SIGN=1` + `MODULE_SIGN_PUB_KEY` / `MODULE_SIGN_PRIV_KEY` |

Other options: `-t TARFILE` (custom source archive), `-K`/`--keep-going`, `-d`/`--dry-run`,
`--dirty`, `--no-kver`, `--sign-rpm`, `-v`, `-h`.

**Satisfies:**

- **R1** — met, and verified by build on both paths (Appendix B). Use `-s <ksrc>`, not
  `-k <kver>`: on EL9 `-k` cannot work in a build container at all. See B.3.
- **R7** — the script's *default* source is `${RES_FOLDER}/MLNX_OFED_*.tgz`
  (`doca-kernel-support:97`), the same archive our Dockerfiles already download, and `-t`
  points it at ours. Download step, version pinning, and manifests all stay as they are.
- **R2**, **R8**, and R5 for mainstream kernels.
- **R6** — met. It installs missing build dependencies via `dnf`/`apt` but skips anything
  already present (`:305-315` for RPM, `:321-325` for deb). Both dependency lists
  pre-install cleanly, so the step becomes a no-op; see B.4. Still to be proven under
  `--network=none`.
- **R4** — met, but *not* the way the documentation suggests. See B.2: pruning the source
  archive works, so the script needs no patching.

**Gaps:**

- **R3 not met by default.** Output is a single `doca-kernel-repo-<ver>.kver.<kernel>.<arch>`
  package that *contains* a dnf/apt repository, not loose packages. `--dirty` preserves
  `$TOP_DIR/packages/<kver>/<component>/`, which is where the POC harvests loose packages
  from, so this is workable — but our `COPY` globs, `copyBuildArtifacts`, and inventory
  cache still need rework to either unwrap the repo package or install through it.
- `mlnx-nvme`, `mlnx-nfsrdma`, and `fwctl` are built but deliberately not pulled by the
  meta-packages, so they need explicit installation. Interacts with `ENABLE_NFSRDMA` and
  the 26.07 NVMe handling.
- ~~Missing dependency on `get_mlnx_ofed_version`.~~ **Not a gap** — it ships in
  `doca-ofed-source`, which `doca-extra` depends on (B.1). Install `doca-extra` through the
  package manager and the whole set resolves, including a version-matched source archive
  at the tool's default path (B.1.1).
- **No `--distro` override.** `DISTRO` is derived from `/etc/os-release`, and it changes
  real build behaviour: `rhel:*` gets `--with-gds`, and the KMP `dist` tag is built from it.
  Rewriting `/etc/os-release` is the only lever, which matters for RHCOS/DTK. See B.5.
- Documented as not supporting "customized or unofficial kernels" — unclear whether our
  RT and 64k variants qualify (**R5** risk).
- New build-time dependency on the DOCA repo being reachable and on `doca-extra` itself.

### Option B — drive the component build recipes directly (recommended fallback)

Skip the orchestrator and invoke `rpmbuild --rebuild` / `dpkg-buildpackage` on the
component sources ourselves. This is viable because **the build recipes live inside the
component source tarballs, not in `ofed_scripts`**, so they survive the removal:

```
mlnx-ofed-kernel-2607.0.100/ofed_scripts/mlnx-ofa_kernel.spec
mlnx-ofed-kernel-2607.0.100/debian/rules
mlnx-ofed-kernel-2607.0.100/debian/control
mlnx-ofed-kernel-2607.0.100/dkms.conf
mlnx-ofed-kernel-2607.0.100/ofed_scripts/{configure,generate_dkms_conf.sh,pre_build.sh}
```

Note the trap: that `ofed_scripts/` **directory** inside the kernel source is unrelated to
the `ofed_scripts` **package** being removed.

Both recipes are fully parameterized:

| RPM spec (`mlnx-ofa_kernel.spec`) | debian (`debian/rules`) |
|---|---|
| `KMP` (default `0`) | `WITH_DKMS`, from `modules` in `DEB_BUILD_PROFILES` |
| `KVERSION` (default `uname -r`) | `kernelver ?= $(shell uname -r)` |
| `K_SRC` (default `/lib/modules/%{KVERSION}/build`) | — |
| `configure_options` | `WITH_MOD_SIGN`, `NJOBS` |
| `LIB_MOD_DIR`, `KERNEL_SOURCES`, `_name`, `_version`, `_release` | `INSTALL_MOD_DIR=updates` |

**Satisfies R1–R4 and R7–R9**, and R6 outright since nothing installs dependencies for
us. Meets **R4** where Option A cannot: excluding a component simply means not building
its SRPM.

> **Build the utils output, not only the modules.** `openibd` and `mod_load_funcs` ship in
> the `mlnx-ofa_kernel` base package (RPM) and `mlnx-ofed-kernel-utils` (deb), **not** in
> the `-modules` / kmod subpackage — see §2. A build that emits only the module packages
> drops both silently, and the entrypoint's whole load, unload, restart, and inbox-restore
> path depends on them. From the `mlnx-ofa_kernel` SRPM that means producing the base
> package *and* modules. This is the most likely way to get Option B subtly wrong, since
> the result installs cleanly and only fails once `openibd restart` is invoked.

**Cost:** we own the orchestration — build order, per-distro configure options, release
string construction, and dependency handling. That is real but bounded work, and much of
it is already encoded in our Dockerfiles.

**Key synergy with Option A:** the two are the *same mechanism*. Option A is a supported
wrapper around the parameters Option B sets by hand. Whichever we pick, knowledge and
debugging transfer, which substantially de-risks the decision.

### Option C — DKMS at install time

NVIDIA's stated strategic direction: "The DOCA repository no longer contains prebuilt
kernel drivers; instead, modules are compiled during installation via DKMS," with
repositories now published per *major* OS release only.

**Rejected as the primary path.** It defeats the purpose of a precompiled, kernel-pinned
image: compilation moves to pod startup on the customer node, requiring a toolchain and
matching headers there, with a large startup-latency cost and a new failure surface on
nodes that cannot compile. It stays relevant as the `sources`-mode story and is already
partially supported via `USE_DKMS`.

### Option D — consume NVIDIA prebuilt kernel packages

**Rejected.** NVIDIA documents that the DOCA repos no longer ship prebuilt kernel drivers,
and per-kernel coverage would never match the matrix in `release_manifests/` (which spans
specific kernels such as `6.8.0-138-generic` and `7.0.0-1016-nvidia`).

### Option E — freeze on DOCA ≤ 3.5, or vendor `install.pl`

**Stopgap only.** Pinning to 3.5 caps us out of newer NIC and kernel support. Vendoring
`install.pl` means maintaining a 7,000-line Perl script with no upstream — acceptable as a
few-month bridge, not a destination.

### Summary

| | R1 cross-kernel | R2 build-only | R3 loose pkgs | R4 exclude | R5 distro/RT | R6 offline | R7 pinned ver | R8 DKMS+static | R9 DTK |
|---|---|---|---|---|---|---|---|---|---|
| **A** `doca-kernel-support` | yes | yes | partial | yes | risk | yes | yes | yes | likely |
| **B** direct rpmbuild/dpkg | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| **C** DKMS at install | n/a | n/a | n/a | partial | yes | **no** | yes | DKMS only | n/a |
| **D** prebuilt packages | n/a | n/a | yes | n/a | **no** | yes | **no** | n/a | n/a |

Option A's row is updated from POC results (Appendix B). R4 moved to yes because exclusion
turned out to be achievable by pruning the source archive rather than patching the script;
R3 is partial because `--dirty` exposes loose packages but our artifact plumbing still
needs rework.

---

## 5. Recommendation

**Primary: Option A**, with **Option B as the designed fallback.**

Rationale: Option A is NVIDIA-supported, consumes the same source archive we already
download, and meets the requirement most likely to have been disqualifying — cross-kernel
builds (**R1**). With the source archive now confirmed to survive (§1), **R7** is settled
too, so the two requirements that could have made this an architectural problem are both
answered. Option A's remaining gap is the repo-shaped output (**R3**), which is mechanical
work inside our own tooling rather than a blocker. That is a meaningfully lower-risk
position than when this document was started.

**The POC (Appendix B) strengthens this further.** Builds succeeded on both packaging
families, and the gap that looked most awkward — no component exclusion (**R4**) — turned
out to be solvable by pruning the source archive, leaving `doca-kernel-support` itself
unmodified. The genuine surprises were smaller than expected and all have workarounds: a
missing `get_mlnx_ofed_version`, `-k` being unusable on EL9 containers, and two size bugs
confined to the deb path.

Because A and B are the same underlying mechanism, we should build the abstraction so the
orchestrator is swappable. Concretely: put the build behind one seam in
`internal/driver` and keep the Dockerfile stages thin, so switching from
`doca-kernel-support` to direct `rpmbuild` does not ripple.

Suggested phasing:

1. ~~**Prove R1 and R7.**~~ **Done** — cross-kernel builds succeed on both RHEL and Ubuntu
   targets against our own archive, with only the target's headers installed (B.3, B.6).
2. ~~**Measure the R4 cost.**~~ **Superseded** — exclusion is free via archive pruning
   (B.2), so there is no build-everything cost to measure and no script to patch.
3. **Design the R3 adaptation.** Decide between unwrapping `doca-kernel-repo` into loose
   packages and installing through the embedded repo; the latter may simplify the
   inventory cache. `--dirty` plus `packages/<kver>/<component>/` is the third option and
   is what the POC uses. **This is now the largest piece of remaining design work.**
4. **Confirm R6** with the network actually disabled. Dependency lists are known complete
   (B.4); only the `--network=none` run is outstanding.
5. **Close the deb size gap** (B.7): strip is fixed, LTO bytecode is not.
6. **Escalate the open questions in §6** in parallel — some answers could change the
   recommendation.
7. Keep the `install.pl` path working while DOCA ≤ 3.5 is supported, selected the same
   way `USE_NEW_ENTRYPOINT` selects the entrypoint.

---

## 6. Open questions for NVIDIA

Ordered by how much they could change the plan.

> **Resolved:** whether `MLNX_OFED_SRC-<version>.tgz` survives 3.6. It does — see
> §1. That was the question that could have invalidated both viable options, so the
> remaining list is about picking between them, not about whether a path exists.

1. **What is the supported replacement for `install.pl`** for consumers who build kernel
   modules for a *foreign* target kernel? Is `doca-kernel-support` it, officially?
2. **Will `doca-kernel-support` remain supported** for precompiled and container
   consumers, given the documentation states it is "no longer required" now that DKMS
   handles non-default kernels? Our use case depends on it continuing to exist. If the
   answer is lukewarm, Option B becomes the primary rather than the fallback.
3. **Can component exclusion be added** to `doca-kernel-support` (an `install.pl`-style
   `--without-<pkg>`)? *Lowered in priority:* we have a working answer via archive pruning
   (B.2), which contradicts the documentation's claim that a custom tarball cannot disable
   anything. Worth asking whether pruning is **supported behaviour** or an accident we
   should not depend on.
4. **Are RT and 64k-page kernels** in scope for `doca-kernel-support`, given the
   "no customized or unofficial kernels" caveat?
5. ~~**What provides `get_mlnx_ofed_version`?**~~ **Answered by inspection, not a bug.**
   `doca-ofed-source`, which `doca-extra` depends on (B.1). No question for NVIDIA here.
6. **Is there a supported offline mode**, or is pre-installing the build dependencies the
   sanctioned approach? *Pre-installing works* (B.4); we want confirmation it is sanctioned.
7. **What is the OpenShift/DTK story?** DTK images will not have the DOCA repo configured;
   can `doca-extra` be vendored into the sidecar?
8. **What is the last DOCA version shipping `install.pl`**, and what is the support window?
9. **Will the archive keep shipping `SRPMS/` and `SOURCES/*.orig.tar*` unchanged?** Now
   that the tarball is confirmed to survive, this is the follow-on detail both options
   depend on — Option B reads `SRPMS/` directly, and `doca-kernel-support` expects that
   exact layout.
10. **Is `-k` expected to work in a build container on EL9?** It cannot (B.3), because
    `kernel-devel` does not create the `/lib/modules/<ver>/build` symlink that
    `set_kernel_vars()` requires. If `-s` is the intended path for containers, the
    documentation should say so.
11. **Why does `deb_build()` force `MLNX_KO_NO_STRIP=1`?** It inflates the modules package
    2.5x and silently disables the `WITH_MOD_SIGN` hook, since both live in
    `override_dh_strip` (B.7). Is this deliberate, and is the signing side effect known?
12. **Should out-of-tree modules be built with `-flto` on Ubuntu?** The resulting `.ko`
    files carry ~31 MB of LTO bytecode each (B.7). If not intended, `debian/rules` should
    set `-fno-lto` rather than leaving it to `dpkg-buildflags`.

---

## 7. Code touchpoints

Where the work lands, for estimation:

| Area | Change |
|---|---|
| `RHEL_Dockerfile`, `Ubuntu_Dockerfile`, `SLES_Dockerfile` | `driver-builder` stage: replace the `install.pl` invocation; add `doca-extra` to `driver-src` if Option A |
| Dockerfile `precompiled` stages | `COPY --from=driver-builder` globs, if the output shape changes |
| `entrypoint/internal/driver/driver.go` | `buildDriverFromSource` (`:1122-1179`), `copyBuildArtifacts`, `installDriver` |
| `entrypoint/internal/dtk/build.go` | `:89-99` install args, and the DTK sidecar's toolchain |
| `dtk_nic_driver_build.sh` | bash DTK path, same change |
| `entrypoint.sh` | `:481` invocation, `set_append_driver_build_flags` (`:383-389`) |
| Build cache | `.buildconfig` fingerprint must cover the new build tool and flags |
| `docs/repository-guide.md` | §9.1 rewrite once the path is chosen |

Two concrete items from the POC land here. `RHEL_Dockerfile` passes
`--kernel-sources /lib/modules/${D_KERNEL_VER}/build`, and that **path** has to change to
`/usr/src/kernels/${D_KERNEL_VER}` alongside the flag rename, per B.3. And whichever
component-exclusion mechanism replaces the `--without-*` flags in A.4 becomes an archive
pruning step (B.2), which is new tooling rather than a translated flag — so it needs a home
of its own, most naturally next to where the source archive is already staged.

Note that `APPEND_DRIVER_BUILD_FLAGS` and `D_BUILD_EXTRA_ARGS` are public knobs whose
accepted values are `install.pl` flags. Changing the builder is a **breaking change** to
that interface and needs a deprecation story of its own.

---

## 8. Timeline

| When | What |
|---|---|
| Done | §5 step 1: cross-kernel builds proven on both packaging families (Appendix B) |
| Now | Escalate the §6 questions that gate the A-vs-B choice — the official replacement, whether `doca-kernel-support` stays supported, and whether the archive keeps its `SRPMS/` layout — plus the deb strip/sign coupling (Q11) |
| Next quarter | Decide A vs B on the experiment's evidence; land the swappable build seam |
| Quarter after | Implement and validate across the `release_manifests` matrix |
| Before Oct 2026 | Ship with both paths selectable; default to the new one once the matrix is green |

---

## 9. Implementation status

**Ubuntu, sources variant, non-DKMS has been migrated to `doca-kernel-support`.** Everything
else still runs `install.pl`. The migration is a straight replacement on that one path with
no feature flag, so the baseline diff in B.8 is the safety net rather than a rollback.

| Area | State |
|---|---|
| Ubuntu sources, non-DKMS | migrated |
| RHEL sources, non-DKMS | migrated, not yet validated on hardware — see §11.5 |
| Ubuntu sources, `USE_DKMS=true` | still `install.pl` — see below |
| Ubuntu and RHEL precompiled (`driver-builder` stage) | still `install.pl` |
| SLES / OpenShift-DTK | still `install.pl` |

What changed:

- `Ubuntu_Dockerfile`, `driver-src`: installs `doca-extra` from the DOCA apt repo (which
  pulls `doca-ofed-source`, hence `get_mlnx_ofed_version`), deletes the duplicate source
  archive that comes with it, and clears `MLNX_KO_NO_STRIP` with `grep` assertions either
  side of the `sed` so a vendor change fails the image build rather than a node.
- `buildDriverFromSource` dispatches on OS and `USE_DKMS`; the old body is preserved as
  `buildDriverWithInstallPl`, marked deprecated.
- `buildDriverWithDocaKernelSupport` runs the tool with `--dirty`, recovers its mktemp work
  directory by parsing `Building under <dir>` from stdout, and collects the loose packages.
- `stageDriverArchive` / `selectedDriverComponents` assemble the per-build source archive.
- `buildMlnxTools` covers the one package `doca-kernel-support` cannot build.
- `copyBuildArtifacts` reads the staging directory instead of `DEBS/`. Its old debug block
  logged `RunCommand`'s second return value, which is stderr, not stdout — removed.
- `APPEND_DRIVER_BUILD_FLAGS` values are dropped with a warning naming each flag. This is a
  **breaking change to a public knob** (§7) and still needs a deprecation note for users.
- `Build` defers the prerequisite install until a build is known to be needed, on the Ubuntu
  non-DKMS path only, so a cache hit no longer requires a reachable apt repo (§10.3).

### 9.1 Known gaps in what has been implemented

- **`USE_DKMS=true` on Ubuntu still routes to `install.pl`.** `doca-kernel-support` forces
  `WITH_DKMS=0`, so sending DKMS builds through it would quietly produce non-DKMS packages
  instead of failing. That is a deliberate placeholder: the fallback disappears in DOCA 3.6,
  so this combination needs a real answer — see §9.2, which argues the answer should be
  removal.
- **Validated on a real node: build, install and module load** — see B.9. The first run
  there found an incomplete component list (`virtiofs` and `kernel-mft` were being built);
  after fixing it, the rerun produced exactly the B.8 package set. What remains unproven on
  hardware is restore-on-termination, since that node carries its own OFED install.
- **`--dirty` leaves the work directory behind** if the process dies between the build and
  the deferred cleanup. Harmless in a container, but it is `/tmp` growth on a long-lived one.

### 9.2 The case for retiring `USE_DKMS` rather than reimplementing it

This is a separate decision from the migration, sharing only its deadline. It is recorded
here because DOCA 3.6 forces it to be made, not because the migration depends on the outcome.

**The requirement is self-justifying.** R8 asks for "both DKMS and static module output" and
cites `D_ENABLE_DKMS` / `USE_DKMS` as the evidence — the flag that implements it. No user need
is recorded anywhere in this repository.

**A container gets neither of DKMS's two benefits.** DKMS exists to rebuild out-of-tree modules
when a long-lived machine's kernel changes, from one source package rather than one package per
kernel.

The rebuild-on-kernel-change half is already implemented, better, by the entrypoint: every start
reads `uname -r`, keys the cache on it, and rebuilds on a miss. That is DKMS's job done with a
host-persistent cache. DKMS's own trigger is a postinst hook that fires when a *kernel package is
installed inside the container filesystem*, which is unrelated to the host kernel changing —
visible misfiring in B.10.1's log, where installing `linux-headers` produced `dkms: running auto
installation service for kernel 6.8.0-31-generic`. Anything it did build would die with the
container anyway.

The one-package-many-kernels half is moot: the build is pinned to a single kernel either way.

**And it costs.** The inventory cache stops working, because what it caches is a source package
while the compile happens again on every start — which is why §10.3's prerequisite deferral had
to exclude DKMS, leaving it dependent on a reachable apt repo at every restart. Signing is
theatre: DKMS can self-sign, but with an ephemeral key never enrolled in MOK, worth nothing under
Secure Boot. It also drags `dkms` into every sources image, the no-op `systemctl` stub, the
`dkmsRemove` branch in `Unload`, and special-casing in the DTK handshake.

**In a container the non-DKMS path is strictly better at DKMS's own job.** Both compile for the
running kernel; one keeps the result and reuses it, the other discards it and recompiles. There
is no kernel-upgrade scenario where DKMS wins, because a kernel upgrade means a new pod, and a
new pod re-runs the same logic regardless.

**It is already broken outside Ubuntu at image build time.** The RPM `install.pl` treats
`--copy-ifnames-udev` as a second spelling of `--without-dkms`:

```
} elsif ( $cmd_flag eq "--copy-ifnames-udev" ) {
    $do_copy_udev = 1;
    $build_dkms_packages = 0; # abuse --copy-ifnames-udev option
```
— `install.pl:317-319` (26.07-0.3.2.0)

`$build_dkms_packages` starts at `1` (`:96`) and is only ever assigned `0`, so nothing restores
it. Both `RHEL_Dockerfile:173` and `SLES_Dockerfile:156` — the `D_ENABLE_DKMS=true` branches —
pass `--copy-ifnames-udev`, as does `internal/dtk/build.go:98` unconditionally. Those three
paths therefore produce ordinary binary module packages while believing they built DKMS ones.
Ubuntu is unaffected: the debian variant's `--copy-ifnames-udev` only sets `$do_copy_udev` and
leaves its separate `$with_dkms` alone.

The *runtime* path is not affected — `getBuildFlagsForOS` never passes `--copy-ifnames-udev`,
so `USE_DKMS=true` on RHEL and SLES does reach the DKMS package set. Two clarifications worth
recording, since both are easy to get wrong:

- `--disable-kmp` is **not** the culprit and does not conflict with DKMS. The
  `$build_dkms_packages` block at `:1483` runs after the `$kmp` block at `:1462` and overwrites
  `$kernel_rpm` either way, so `--disable-kmp` alone still yields `mlnx-ofa_kernel-dkms`.
- A separate, unverified concern: the runtime exclusion flags use the unsuffixed names on
  RHEL and SLES (`getPackageSuffix` returns `""`), but under DKMS the RPM names become
  `iser-dkms`, `srp-dkms` and so on. `disable_package` (`:3289`) matches exact keys and
  cascades only through `ofa_req_inst`/`ofa_req_build`, and the KMP name translations at
  `:3344-3369` have no DKMS equivalent. So `--without-iser` likely does not reach `iser-dkms`,
  meaning runtime DKMS builds on RHEL and SLES may build components the non-DKMS path excludes.

So "we support DKMS" today means: Ubuntu properly, RHEL and SLES at runtime only, and never in
the prebuilt images or under OpenShift DTK.

**What would have to be true to keep it.** Someone must actually set `USE_DKMS=true`, and want
one of:

1. *DKMS source packages as an artifact*, for installing on hosts later. That is a build-time
   deliverable, and Option B could emit it without a runtime DKMS mode at all.
2. *Runtime DKMS on the node.* They are already paying a recompile per restart for an outcome
   the non-DKMS path reaches faster.

If neither holds, deprecate the flag and the last caller of `install.pl` leaves with it.

---

## 10. Inventory cache under the new build path

The build cache lives at `<NVIDIA_NIC_DRIVERS_INVENTORY_PATH>/<uname -r>/<NVIDIA_NIC_DRIVER_VER>`,
guarded by a sibling `<ver>.checksum` (md5 over the cached files) and a `<ver>.buildconfig`
fingerprint of `ENABLE_NFSRDMA`, `USE_DKMS` and `APPEND_DRIVER_BUILD_FLAGS`. It is on a host
mount and survives container image upgrades, which is what makes its key worth scrutinising
after swapping out the builder.

### 10.1 What the migration does not break

`ENABLE_NFSRDMA` is the load-bearing case and it is correct. It now changes the produced
package set, because `selectedDriverComponents` includes or omits `mlnx-nfsrdma` and
`mlnx-nvme`, and it is in the fingerprint — so toggling it across a restart invalidates the
cache and rebuilds, rather than reinstalling a package set that no longer matches the
request. The build branch also wipes the inventory directory before rebuilding, and
`buildDriverWithDocaKernelSupport` wipes its staging directory before each run, so neither
stale packages nor a previous failed build can leak into the inventory through the `*.deb`
glob. A crash between `copyBuildArtifacts` and `storeBuildChecksum` leaves packages with no
checksum file, which reads as a cache miss and rebuilds. `cleanupDriverInventory` preserves
`.buildconfig` alongside `.checksum`; deleting it would produce a permanent rebuild loop.

### 10.2 Builder identity is not in the cache key — closed by version policy

Nothing in the key identifies the builder. Under `install.pl` that was harmless, because the
builder *was* the source tree that `NVIDIA_NIC_DRIVER_VER` names. `doca-kernel-support`
arrives from `doca-extra`, versioned independently, and we mutate it with `sed`. So in
principle a node could cache packages built by an old image and keep serving them after an
image upgrade that fixes the builder — the `MLNX_KO_NO_STRIP` patch being the concrete
example, where a node would keep installing unstripped packages forever.

**This is closed by not shipping the migration on an already-published OFED version.** A new
`NVIDIA_NIC_DRIVER_VER` is a new cache directory, so every node rebuilds with the new
image's builder and no stale packages can be served.

The residual case is a `doca-extra` respin *inside* an already-shipped OFED version — a DOCA
patch release moving past `2607.0.10-1` while OFED stays at `26.07-0.7.7.0`. If that ever
happens, fold the builder's identity into `currentBuildConfigFingerprint`; hashing the script
file is preferable to using the package version because it also captures whether our `sed`
landed. Note this is the same class of gap that already existed — the key never covered image
content, including the source tarball itself.

### 10.3 A cache hit no longer needs a reachable package repo

Prerequisites used to be installed before the cache check, unconditionally for non-DTK. On
the new Ubuntu non-DKMS path a cache hit compiles nothing, so that ordering made a warm cache
useless on a node that could not reach its apt repo. The failure is specifically
`apt-get -yq install pkg-config linux-headers-<kernel>` exiting 100; `apt-get update` merely
warns and exits 0 with no network.

This was masked in testing because the image already carries
`linux-headers-6.8.0-139-generic`: `dkms` has `Recommends: linux-headers-generic`, which
resolved to noble's default kernel at image build time. A node running exactly that kernel
therefore succeeded by coincidence, and any other kernel failed.

`Build` now defers the prerequisite install into the build branch when the OS is Ubuntu and
`USE_DKMS` is false. DKMS keeps the eager install because it still compiles on a cache hit,
and DTK still installs nothing.

**This does not make a cache hit offline-capable, and R6 stays open.** `installUbuntuDriver`
still fetches `linux-modules-extra-<kernel>` on every start — 153 MB with its dependencies —
because the image ships no inbox kernel modules while `mlx5_core` depends on several of them
(`pci-hyperv-intf`, `psample`, `tls`). That install is best-effort (`|| true`, and the
`apt-get update` error is only logged), so offline the run *reports success* while silently
skipping them; whether the load then works depends on whether those modules happen to be
live already in the shared kernel, since `modprobe` skips loaded dependencies. Passing-but-
fragile, so `--net=host` remains required in practice.

What the deferral therefore buys is narrower than "offline works": it removes a hard failure
(`apt-get install linux-headers-<kernel>` exiting 100) on a cache hit, and skips a 17.5 MB
download. Closing R6 for real means sourcing the inbox modules from `/host/lib/modules`
instead of apt.

**Confirmed on the node.** A third run against a warm cache went from `uname -r` straight
into the checksum with no prerequisite install in between, which is exactly the behaviour
this change was for:

```
driver.go:1547  Executing checksum calculation  find /host/cache/drivers/6.8.0-136-generic/26.07-0.7.7.0 -type f -exec md5sum {} + | md5sum
driver.go:1053  Checksums and build config match, skipping build  {"checksum": "2f72846242c6e60c7e32b0bdba0cd691"}
driver.go:241   Skipping driver build, reusing previously built packages  {"kernel": "6.8.0-136-generic"}
driver.go:1640  Installing driver packages  {"path": "/host/cache/drivers/6.8.0-136-generic/26.07-0.7.7.0", ...}
```

The checksum over the inventory took 115 ms, `doca-kernel-support` was never invoked, and
the whole run reached `Driver loaded successfully` in about 50 s against roughly five minutes
for a build. The first apt traffic of the run is the `linux-modules-extra` fetch inside
`installUbuntuDriver`, which is the remaining network dependency described above.

### 10.4 Pre-existing issues, not from this migration

- **`Clear()` cleans a path that never existed when caching is disabled.** With no inventory
  path, `checkDriverInventory` mints `/tmp/nvidia_nic_driver_<timestamp>`; `Clear` recomputes
  it seconds later and gets a different name, so `RemoveAll` is a no-op and the real build
  directory leaks. It also means the `driverBuildIncomplete` cleanup does nothing in that
  mode. Container-local, so low impact.
- **The checksum depends on `find` traversal order** and embeds absolute paths
  (`find … -exec md5sum {} + | md5sum`). Stable for an untouched directory in practice, but
  a `sort` would make it deterministic, and the embedded paths mean relocating the inventory
  mount silently invalidates every cache on the node.
- **`APPEND_DRIVER_BUILD_FLAGS` now forces rebuilds that change nothing** on Ubuntu
  non-DKMS, since the flags are discarded. Leaving it is deliberate: the fingerprint is
  shared across distros and the field is still load-bearing for RHEL and SLES, so making it
  conditional would buy a little CPU at the cost of a subtle correctness trap.

---

## 11. RHEL migration — the two variants and what each needs

RHEL is two build paths, not one, and they fail in different places.

**Regular RHEL.** The build runs in *this* container, exactly like Ubuntu: `doca-extra` can be
installed into the image, and `buildDriverWithDocaKernelSupport` needs only an RPM-flavoured
component list and archive-pruning pattern.

**OpenShift DTK.** The build runs in a *different* container — the Red Hat Driver Toolkit image,
which carries the kernel headers matching the node's RHCOS. Today the driver container copies
the whole source tree (and so `install.pl` with it) plus the entrypoint binary and a `dtk.env`
onto a shared volume, sets a start flag, and waits for a done flag while the DTK sidecar
compiles. `install.pl` travels for free because it lives *inside* the source tree.
`doca-kernel-support` does not — it comes from `doca-extra`, which the DTK image has never
heard of. That single fact is the whole difficulty of this variant.

### 11.1 The RPM component list is the deb list with one rename

Taken verbatim from `rpm_rebuild_modules` (`:585-596`), in build order: `mlnx-ofa_kernel`,
`iser`, `isert`, `srp`, `mlnx-nfsrdma`, `mlnx-nvme`, `virtiofs`, `fwctl`, `knem`, `xpmem`,
`kernel-mft`.

That is the same eleven components as `deb_rebuild_modules`, differing only in the base
package name — `mlnx-ofa_kernel` where the Debian archive says `mlnx-ofed-kernel`. So
`docaBuildableComponents` is reusable across both families if the base component becomes
per-family rather than a single constant.

The exclusion pattern differs. `rpm_build` looks for `SRPMS/$base_name-[0-9]*.src.rpm`
(`:573`), not `SOURCES/<name>_*`, so the archive excludes must target the SRPMS glob. Note the
tool's own `-[0-9]` anchor already prevents `iser` from matching `isert`; mirroring it keeps
our excludes equally unambiguous, where the deb side needed an explicit `_` anchor instead.

### 11.2 `DISTRO` decides *which components get built*, not just the dist tag

This raises the stakes on B.5 considerably. `is_rpm_built` (`:613-656`) gates components on
`$DISTRO`, which is derived from `/etc/os-release` with no override:

- `iser`, `isert` and `srp` are built only when `is_storage_mods_distro` matches, a list of
  `rhel:*`, `almalinux:*`, `rocky:*`, `sles:*` and others.
- `mlnx-nvme` is skipped when the target kernel has `CONFIG_NVME_CORE=y`, and on
  `azurelinux`/`mariner`.
- `knem` is skipped on `alinux`, `anolis`, `uos20`; `virtiofs` only on kernels 6.6+.
- `dist` — the `.rhel9u8` style KMP release tag — is `${DISTRO}` with punctuation rewritten
  (`rpm_build`, `:597-606`).

We exclude the storage components anyway, so the gating mostly works in our favour. What does
not is the `dist` tag and `--with-gds`: B.5 saw AlmaLinux produce `.almalinux9u8` and skip GDS
where `rhel:*` gets it. A wrong `DISTRO` therefore yields differently-named packages built with
different configure options — quietly.

Under DTK this is not hypothetical. The driver container deliberately computes
`--distro rhel<version>` for `install.pl` today (`getDTKAppendDriverBuildFlags`), precisely
because auto-detection in the sidecar is not trustworthy. `doca-kernel-support` offers no such
flag, so rewriting `/etc/os-release` inside the build container is the only lever available.

### 11.3 DTK needs the tool staged, and `RES_FOLDER` is an absolute path

`setup_rpm_dep_scripts` (`:337-361`) is the blocker. On `redhat` vendor — which DTK is — it
writes a `find-provides` wrapper and passes `--define __provided_ksyms_provides`, both
referencing `$RES_FOLDER/find-provides.ksyms`:

```
echo "\$files" | "$RES_FOLDER/find-provides.ksyms"
```

`RES_FOLDER` is assigned unconditionally at `:17` (`/opt/mellanox/doca/tools/resources`), not
via `${RES_FOLDER:-…}`, so there is no environment override. The RPM path cannot run in a
container that lacks that exact absolute path. Options, in order of preference:

1. Stage `doca-kernel-support`, `get_mlnx_ofed_version` and `resources/find-provides.ksyms`
   onto the shared volume, and have the DTK-side loader copy them into
   `/opt/mellanox/doca/tools/` before invoking. Keeps the vendor script unpatched.
2. `sed` `RES_FOLDER` to a shared-volume path at stage time. Fewer moving parts, but now we
   are patching two things in the vendor script instead of one.
3. Get `doca-extra` installed in the DTK container. Not ours to arrange, and offline-hostile.

### 11.4 The rest of the DTK delta

- **`--kernel` and `--distro` reach the sidecar smuggled inside `APPEND_DRIVER_BUILD_FLAGS`**,
  via `dtk.env`. `doca-kernel-support` takes `--kernel` natively and rejects everything else,
  so that transport has to be restructured into explicit fields — and it cannot simply be
  dropped the way the Ubuntu path dropped append flags, because the kernel target lives in it.
- **Output shape.** `dtkFinalizeDriverBuild` globs
  `MLNX_OFED_SRC-<ver>/RPMS/redhat-release-*/<arch>/*.rpm`, which is `install.pl`'s layout.
  `doca-kernel-support` writes `packages/<kver>/<component>/`, so this needs the same
  retargeting `copyBuildArtifacts` got, including the `--dirty` requirement to keep loose
  RPMs rather than only the `doca-kernel-repo` wrapper (B.6).
- **`dnf install perl`** in `dtk.RunBuild` exists for `install.pl`. The replacement is bash,
  so that dependency goes away, while `rpm-build` and `createrepo` become required instead.
- **The DKMS branch here is already dead.** `build.go:98` passes `--copy-ifnames-udev`
  unconditionally, which zeroes `$build_dkms_packages` — see §9.2. Whatever DTK's DKMS mode
  was meant to do, it has not been doing it.

### 11.5 What has been implemented for regular RHEL

Not yet validated on hardware — this is the code, not a result.

- `docaBuildableComponents` became `docaExcludableComponents`, with the always-selected
  base component pulled out into `docaBaseComponent(osType)`. The excludable set is shared
  between families because the two `rebuild_modules` functions list the same ten.
- `docaSourceExcludeArg` emits the family's pattern: `*/SOURCES/<c>_*` for deb,
  `*/SRPMS/<c>-[0-9]*.src.rpm` for RPM.
- `docaKernelTargetArgs` passes `--kernel <ver>` on Ubuntu and `-s /usr/src/kernels/<ver>`
  on RPM, per B.3. The short `-s` is required, not stylistic: the tool's getopt spec
  declares `kernel-source` without a trailing colon, so the long form takes no argument.
- `alignOsReleaseWithHost` rewrites `VERSION_ID` from the host's version info before the
  build and restores the file afterwards, reproducing what `--distro rhel<version>` did.
  `ID` is left alone — every base image here is RHEL-derived and already says `rhel`,
  whereas the host may say `rhcos`, which matches nothing in the tool's distro cases.
- `buildMlnxTools` grew an RPM branch: `rpmbuild --rebuild` on
  `SRPMS/mlnx-tools-[0-9]*.src.rpm`, with `_rpmdir` pointed at the scratch directory so the
  package lands flat rather than under an arch subdirectory.
- `usesDocaKernelSupport` is now the single predicate deciding builder choice, and
  `copyBuildArtifacts` consults it instead of switching on OS alone. This closes a real bug
  introduced with the Ubuntu migration: that switch sent *all* Ubuntu builds to the staging
  directory, including `USE_DKMS=true` ones that still run `install.pl` and still write to
  `DEBS/`. The `install.pl` deb path is restored as `DEBS/*/<arch>/*.deb`.
- `RHEL_Dockerfile` installs `doca-extra` from the DOCA yum repo and deletes the bundled
  duplicate archive. The repo is published per *major* (`rhel8`, `rhel9`, `rhel10`) with a
  standard `repodata/` and an `RPM-GPG-KEY-doca`, so the URL is built from the major rather
  than from `D_OS`; `rhel9.4` and `rhel9.8` have no directory of their own.
- `createrepo_c`, `binutils` and `kernel-abi-stablelists` were added to `driver-src`. These
  are what `rpm_install_build_deps` probes for, and it installs whatever is missing itself —
  which is precisely the subscription-gated network access that package list exists to
  avoid.
- **No `MLNX_KO_NO_STRIP` patch on RHEL.** That assignment appears once in the tool, inside
  `deb_build`. The RPM path strips normally and splits symbols into `-debuginfo`, which B.6
  already observed as a 3 MB `kmod` beside a 47 MB debuginfo package.

### 11.6 KMP — the one delta that changes package *names*, and it is not optional

Found while writing the baseline runner, before any node run. The runtime RHEL path passes
`--disable-kmp` to `install.pl`, so today's RHEL sources build is **non-KMP** and produces
`mlnx-ofa_kernel-modules`. `doca-kernel-support` sets `KMP=1` at `:23` and `set_kmp`
(`:474-500`) only clears it for other distros — `ol:9.*`, `fedora:*`, `mariner:*`,
`azurelinux:*`, and non-default SLES kernels — never for `rhel:*`. There is no flag to turn
it off. So the migrated path produces `kmod-mlnx-ofa_kernel` instead, exactly as B.6
observed.

This is a bigger deal than the Ubuntu deltas, which were all sizes. Things to establish
before calling RHEL done:

1. **Where the modules land.** The KMP subpackage and the non-KMP `-modules` subpackage may
   not use the same directory under `/lib/modules/<kver>/`. `installDriver` checks
   `extra/mlnx-ofa_kernel` explicitly, so if KMP differs, that check and `depmod` need
   revisiting.
2. **KMP scriptlets.** KMP packages carry `weak-modules` postinst hooks and
   `kernel(symbol) = hash` requires. `installDriverPackages` uses
   `rpm -ivh --replacepkgs --nodeps`, which sidesteps the requires, but the scriptlets still
   run and `weak-modules` expects a more complete system than a container is.
3. **Debug packages are now in the harvest.** B.6 produced a 47 MB
   `kmod-mlnx-ofa_kernel-debuginfo` and a 2 MB `mlnx-ofa_kernel-debugsource` beside the 3 MB
   `kmod`. `copyBuildArtifacts` copies `*.rpm` wholesale and `installDriverPackages`
   installs whatever it finds, so roughly 49 MB of symbols would be cached per kernel and
   installed for nothing. This wants an explicit exclusion, and it is cheap to add.
4. **The release tag now depends on `DISTRO`.** With `KMP=1`, `rpm_build` derives
   `dist` from `$DISTRO` (`.rhel9u8`), which is what makes §11.2's os-release alignment
   load-bearing rather than cosmetic — under `--disable-kmp` the tag was `%{nil}`.

Two ways out if KMP turns out to be a problem: accept it and adjust the install path, or
patch `KMP=0` in the image the way Ubuntu patches `MLNX_KO_NO_STRIP` — with `grep`
assertions either side, so a vendor change breaks the image build rather than a node. The
first is preferable if it works, since it stops fighting the tool's defaults.

`poc/dks/run-rhel-baseline.sh` exists to measure this: it runs `install.pl` with exactly the
flags `buildDriverWithInstallPl` assembles for `osType=redhat`, so the two package lists can
be put side by side. Note it has to create the `/lib/modules/<ver>/build` symlink that
`kernel-devel` omits on EL9, because `install.pl` resolves `--kernel` through it — the same
B.3 gap, seen from the other side.

### 11.7 Suggested order

Regular RHEL first: it shares the component list, the SRPMS pruning and the `DISTRO` question
with DTK but has none of the staging problem, so it de-risks the shared parts against a target
we can actually iterate on. DTK second, where the only genuinely new work is getting the tool
and its resources into a container we do not build.

---

## Appendix A — Complete `install.pl` flag inventory

Every flag the repository passes today, collected from all six invocation sites. This is
the migration checklist: whatever replaces `install.pl` must either cover each of these or
have a documented reason not to.

| Site | Lines |
|---|---|
| `RHEL_Dockerfile` | `:173` (DKMS), `:175` (static) |
| `Ubuntu_Dockerfile` | `:156` (DKMS), `:158` (static) |
| `SLES_Dockerfile` | `:156` (DKMS), `:158` (static) |
| `dtk_nic_driver_build.sh` | `:87` (DKMS), `:91` (static) |
| `entrypoint.sh` | `:481` |
| `entrypoint/internal/driver/driver.go` | `:1139-1170` (`buildDriverFromSource`) |

### A.1 Invariant core — passed by every site

| Flag | Purpose |
|---|---|
| `--without-depcheck` | Skip dependency resolution; build deps are pre-installed by the image |
| `--kernel <ver>` | Target kernel version (see **R1**) |
| `--kernel-only` | Kernel modules only, no userspace stack |
| `--build-only` | Build packages, do not install (see **R2**) |
| `--with-mlnx-tools` | Include `mlnx-tools` |

### A.2 Distro and source location

| Flag | Where |
|---|---|
| `--distro <id>` | All three Dockerfiles (`${D_OS}`). At run time RHEL only, as `--distro rhel<full-version>`, and suppressed when `OPENSHIFT_VERSION` is set |
| `--kernel-sources /lib/modules/<ver>/build` | RHEL and SLES Dockerfiles; at run time SLES only |

### A.3 DKMS and KMP control

| Flag | Where |
|---|---|
| `--without-dkms` | The `else` branch at every site, i.e. whenever `D_ENABLE_DKMS` / `USE_DKMS` is false |
| `--disable-kmp` | All run-time builds (Ubuntu, SLES, RHEL). Deliberately **omitted** by the DTK sidecar in DKMS mode so that kmod binary packages are produced; not passed by `RHEL_Dockerfile` |

### A.4 Component exclusions

Suffixed flags take `{sfx}` per the rule in A.6.

| Flag | Where |
|---|---|
| `--without-knem{sfx}` | all |
| `--without-iser{sfx}` | all |
| `--without-isert{sfx}` | all |
| `--without-srp{sfx}` | all |
| `--without-kernel-mft{sfx}` | Ubuntu and SLES Dockerfiles, plus all run-time builds |
| `--without-mlnx-rdma-rxe{sfx}` | run time only |
| `--without-xpmem`, `--without-xpmem-modules` | all |
| `--without-xpmem-dkms` | only when DKMS is enabled |
| `--without-mlnx-nfsrdma{sfx}`, `--without-mlnx-nvme{sfx}` | conditional on `ENABLE_NFSRDMA=false` |

This block is the concrete content of **R4**, and the reason Option A cannot satisfy it
without patching: `doca-kernel-support` has no equivalent of `--without-<pkg>`.

### A.5 Image-build only

| Flag | Where |
|---|---|
| `--copy-ifnames-udev` | All three Dockerfiles and the DTK sidecar |
| `--with-ofed-scripts` | `RHEL_Dockerfile` and the DTK sidecar |
| `-vvv` | `SLES_Dockerfile` only |

`--with-ofed-scripts` builds the very package being removed in 3.6. Nothing in this
repository consumes anything from it — there are no references to `ofed_info`,
`ofed_rpm_info`, `sysinfo-snapshot.py`, `ofed_uninstall.sh`, `mlnx_add_kernel_support.sh`,
or `is_kmp_compat.sh` outside vendored trees and logs, and neither `mlnx-ofa_kernel.spec`
nor `debian/control` declares a dependency on it. `install.pl` itself is invoked from the
extracted tarball, not from the installed package. **This flag can be dropped today**,
independently of the rest of the migration.

### A.6 Notes and known quirks

- **Suffix rule.** `{sfx}` is `-dkms` or `-modules` on Ubuntu depending on `USE_DKMS`, and
  empty on RHEL, SLES, and OpenShift — see `getPackageSuffix` in `driver.go`. It exists
  because Ubuntu's `install.pl` variant uses distinct package names per build mode. The
  Ubuntu and SLES Dockerfiles hardcode `-modules` rather than computing it.
- **Duplicate flag.** `entrypoint.sh` appends `--disable-kmp` unconditionally at `:450`
  and again for SLES at `:472`, so SLES receives it twice. Harmless, but do not carry the
  duplication into a replacement.
- **Public interface.** `APPEND_DRIVER_BUILD_FLAGS` and `D_BUILD_EXTRA_ARGS` append
  arbitrary flags from this vocabulary, which is why changing the builder is a breaking
  change to a public knob (see §7).

## Appendix B — POC results

Harness lives in `poc/dks/` (`poc.sh` on the host, `run-ubuntu.sh` / `run-rhel.sh` inside
the container). Nothing is copied into the repo: the vendor script and the OFED tarballs
are bind-mounted read-only. Both paths were driven against `doca-extra-2607.0.10` and the
26.07-0.7.7.0 source archives.

Both builds completed with exit code 0, so **Option A is viable on both packaging
families**. The findings below are the caveats, not blockers.

**R1 is proven by the artifact, not just by the exit code.** The deb build's `mlx5_core.ko`
reports `vermagic: 6.8.0-139-generic SMP preempt mod_unload modversions` while the build
host ran Fedora 6.17 — the module is built for the named target kernel, not for whatever
`uname -r` says. The modules install under `/lib/modules/<target>/updates/`, and the utils
package places the two critical scripts at `/etc/init.d/openibd` and
`/usr/share/mlnx_ofed/mod_load_funcs`.

### B.1 `get_mlnx_ofed_version` is not missing — `doca-extra` has a dependency

**Correcting an earlier conclusion in this document.** `doca-kernel-support:5` runs
`get_mlnx_ofed_version` unconditionally under `set -e` and the `doca-extra` payload does
not contain it, which initially looked like a packaging bug worth reporting. It is not.
`doca-extra` declares `Depends: pciutils, doca-ofed-source (>= 26.07)`, and
**`doca-ofed-source` ships it**. The script only appeared missing because the POC extracted
`doca-extra` standalone from an RPM rather than installing it through a package manager.

The shipped implementation is a generated stub with the version baked in at package build
time — it does **not** shell out to `ofed_info`, so it carries no dependency on the
`ofed-scripts` package being removed:

```sh
ver_minor_len=$(echo "26.07-0.7.7" | cut -d- -f2 | wc -c)
if [ "$ver_minor_len" = 6 ]; then echo "26.07-0.7.7.0"; else echo "26.07-0.7.7"; fi
```

The POC's `poc/dks/get_mlnx_ofed_version` remains only because the harness deliberately
bypasses package installation; production must not carry a stub.

### B.1.1 `doca-ofed-source` is how the source archive is delivered

Found while resolving the above, and it simplifies the Dockerfile work considerably.
`doca-ofed-source_26.07.0.7.7-1_all.deb` (~42 MB) installs:

```
/opt/mellanox/doca/tools/get_mlnx_ofed_version
/opt/mellanox/doca/tools/resources/MLNX_OFED_SRC-debian-26.07-0.7.7.0.tgz
/opt/mellanox/doca/tools/doca-info
```

That tarball path is exactly `doca-kernel-support`'s **default** source location
(`${RES_FOLDER}/MLNX_OFED_*.tgz`, `:97`), so `apt-get install doca-extra` yields the tool,
a version-matched source archive, and the version helper as one consistent set — no
`ADD <url>`, no stub, and `-t` needed only when overriding with our own archive.

DOCA 3.5.0 ships `doca-extra` 2607.0.10-1 for `ubuntu24.04`, the same build tested here.
Note the older DOCA 3.1.0 deb (`0.1.8.3.0.0`) instead bundled the tarball inside
`doca-extra` itself and hardcoded `DOCA_VERSION`; the split into `doca-ofed-source` is
recent, which is worth knowing when pinning versions.

That NVIDIA packages a source-only deb whose sole consumer is `doca-kernel-support` is also
indirect evidence for **§6 Q1/Q2** — this looks like the intended supported path, not a
leftover.

### B.2 Component exclusion works by pruning the archive, not patching the script

This resolves the R4 gap. Both `rpm_build()` and `deb_build()` skip any component whose
source file is absent, printing `Missing package <x>, skipping`. So deleting the unwanted
sources from the tarball is enough, and **`doca-kernel-support` stays unmodified**:

- RPM path: remove `SRPMS/<component>-[0-9]*.src.rpm`
- deb path: remove `SOURCES/<component>_*.orig.t*`

Exclusion becomes a data operation on an archive we already stage. This is strictly
preferable to the `sed`-the-vendor-script approach the documentation suggests, and it is
how the `--without-*` flags in A.4 should be reimplemented.

**The pruning must happen at build time inside the container, not at image build time.**
`ENABLE_NFSRDMA` is a public runtime knob that selects `mlnx-nfsrdma` and `mlnx-nvme`, and
it can differ between restarts of the *same* image — the inventory fingerprint already
includes it precisely so that flipping it forces a rebuild. Baking a pruned archive into
the image would make `ENABLE_NFSRDMA=true` impossible to honour, because the sources would
no longer be there, and would do so silently. Only exclusions that are hardcoded in our
own source (`iser`, `isert`, `srp`, `kernel-mft`, `mlnx-rdma-rxe`, `xpmem`) are static, and
keeping even those in one place at runtime avoids a Dockerfile keep-list drifting out of
sync with the code.

One trap worth recording: `tar --exclude` is **positional**. It only affects operands that
follow it, so the excludes must precede `-C` and the directory being archived. Placed after
them, tar prints `--exclude ... has no effect` and exits non-zero.

### B.3 On RHEL use `-s`, never `-k`

`set_kernel_vars()` hardcodes `kernel_source="/lib/modules/$kernel_version/build"` for
`-k`. On EL9 that symlink is **not** owned by `kernel-devel` — verified with `rpm -ql` —
it comes from the kernel package itself, which a build container never installs.
`kernel-devel` provides only `/usr/src/kernels/<ver>`. So `-k` fails with
`Could not determine kernel version from source directory` in any container that has
headers but no running kernel, which is every container we build in.

`-s /usr/src/kernels/<ver>` resolves the version correctly and the build proceeds.

This is a live migration detail: `RHEL_Dockerfile` currently passes
`--kernel-sources /lib/modules/${D_KERNEL_VER}/build` to `install.pl`, so the path
argument has to change, not just the command name.

### B.4 Build dependencies all pre-install, so R6 holds

Neither dependency list needs the network once the image is prepared. On the RPM side the
only surprise is benign: EL9 has no package *named* `createrepo`, but `createrepo_c`
declares `Provides: createrepo`, so the script's `rpm -q --whatprovides createrepo` probe
is satisfied. All 11 RPM probes and the deb list report satisfied after a plain install.

### B.5 `DISTRO` is derived from `/etc/os-release` with no override

Building on AlmaLinux produced a `.almalinux9u8` KMP `dist` tag and **skipped
`--with-gds`**, which `rhel:*` receives. Rewriting `/etc/os-release` is the only available
lever (`SPOOF_DISTRO` in the harness). This is the mechanism we will need for RHCOS/DTK,
where os-release will not report what the build requires.

### B.6 Output package set — RPM path

`KEEP=mlnx-ofa_kernel`, target `5.14.0-687.42.1.el9_8.x86_64`, host kernel 6.17 Fedora, so
this is also a cross-kernel proof:

| Package | Size |
|---|---|
| `kmod-mlnx-ofa_kernel` | 3 MB |
| `kmod-mlnx-ofa_kernel-debuginfo` | 47 MB |
| `mlnx-ofa_kernel` | 1 MB |
| `mlnx-ofa_kernel-devel` | 1 MB |
| `mlnx-ofa_kernel-source` | 4 MB |
| `mlnx-ofa_kernel-debugsource` | 2 MB |
| `doca-kernel-repo` (wrapper) | 53 MB |

This is the shape a precompiled image wants: modules stripped into a 3 MB `kmod` with
debug symbols split into a separate package we simply do not ship.

### B.7 Deb path size: one real bug, one pre-existing inefficiency

**Fixed — `MLNX_KO_NO_STRIP`.** `deb_build()` hardcodes `MLNX_KO_NO_STRIP="1"`, opting out
of the stripping `debian/rules` does by default. Flipping it to `"0"` took the modules
package from 131 MB to 52.7 MB and installed size from 571 MB to 85 MB. One character, via
a `sed` that verifies its own pattern matched and fails loudly otherwise.

> A silently-no-op `sed` against a vendor script is precisely the bug already living in
> `entrypoint.sh`, where the `UNLOAD_MODULES` injection matches nothing in 26.07 and no
> one noticed. Any vendor-script patch we ship must assert it applied.

**Coupled side effect — module signing.** The same `override_dh_strip` target hosts the
`WITH_MOD_SIGN` hook, so opting out of stripping *silently disables module signing too*.
Confirmed reachable: with stripping restored and `WITH_MOD_SIGN=1`, `sign-modules` ran and
verified every `.ko`. **We do not sign today** — there is no `WITH_MOD_SIGN` or
`MODULE_SIGN_*` anywhere in the tracked sources — so this is recorded rather than acted
on. It matters only as a constraint: whoever enables signing must not re-enable no-strip.
The RPM spec derives `WITH_MOD_SIGN` from whether the key files exist, so it needs no
equivalent injection.

**Pre-existing, not a regression — LTO bytecode.** Stripping is not the whole story.
Comparing the same component across both paths, neither module retains any DWARF, yet:

| | deb `mlx5_core.ko` | RPM `mlx5_core.ko` |
|---|---|---|
| uncompressed | 40.3 MB | 7.2 MB |
| total sections | 33.6 MB | 2.7 MB |
| `.debug_*` sections | 0 | 0 |

The deb module carries `.gnu.lto_.opts` plus thousands of `.gnu.lto_.decls.*` sections —
GCC LTO intermediate bytecode, roughly 31 MB of that 33.6 MB. Ubuntu's default
`dpkg-buildflags` inject `-flto=auto`, and `strip --strip-debug` does not remove these
sections. The modules load fine; it is pure dead weight.

**The `install.pl` baseline has exactly the same bloat** (B.8): 40,288,360 bytes and 15,413
`.gnu.lto_` sections, against `doca-kernel-support`'s 40,326,946. So this is how the deb
path has always built, not something the migration introduces. It is a standing
inefficiency worth fixing with `-fno-lto` or an `objcopy -R '.gnu.lto_*'` pass, but it
**does not gate the migration** and should not be bundled into it.

### B.8 Baseline diff — Ubuntu, sources variant, non-DKMS

The reference build is `install.pl` invoked exactly as `buildDriverFromSource()` assembles
it at runtime for `osType=ubuntu`, `UseDKMS=false`, `EnableNfsRdma=false` (both defaults),
same container and same target kernel as the `doca-kernel-support` run. Harness:
`poc/dks/run-ubuntu-baseline.sh`. Exit code 0.

| Package | `install.pl` | `doca-kernel-support` |
|---|---|---|
| `mlnx-ofed-kernel-modules` | 55,287,416 B | 52.7 MB |
| `mlnx-ofed-kernel-utils` | 27,912 B | 27,912 B |
| `mlnx-tools` | 76,440 B | **not built** |

**The entire delta is `mlnx-tools`.** The utils package is reproduced exactly — identical
byte size and identical file list, `openibd` and `mod_load_funcs` included, which settles
the Option B warning in §2 for this path. The modules package matches once the strip fix
from B.7 is applied; without it `doca-kernel-support` produces 131 MB, so that fix is what
buys *parity*, not an optimisation beyond it.

`mlnx-tools` is in the archive as `SOURCES/mlnx-tools_2607.0.6.orig.tar.xz` but is absent
from `doca-kernel-support`'s hardcoded component list, while `buildDriverFromSource()`
explicitly passes `--with-mlnx-tools`. It is a userspace package (no kernel modules), so a
plain `dpkg-buildpackage` alongside `doca-kernel-support` covers it — a small, bounded
slice of Option B used to fill Option A's gap.

`buildMlnxTools` reproduces it at the same 76,440 B, 55 files, `/usr/sbin/mlnxofedctl`
included — which matters because the restore-on-termination path in C.5 depends on that one
binary. Both builds consume the same orig tarball and the same `debian/` directory from it,
so `install.pl` was adding nothing here.

Two environment notes that cost a build each to learn. The sources image is `driver-src`
**`FROM base`**, so the build environment is the union of both stages' package lists —
`dh-python` and `python3` come from `base` (`Ubuntu_Dockerfile:56`) and `mlnx-tools`
Build-Depends on `dh-python`, so reproducing only `driver-src` fails in a way unrelated to
`install.pl`. And Ubuntu's `install.pl` rejects `--disable-kmp` with
`Unsupported package: kmp` — the flag is meaningless on this path and is being passed by
`getBuildFlagsForOS` regardless (see A.6).

### B.9 First real-node run — end to end, and the bug it found

Ubuntu 24.04 node, kernel `6.8.0-136-generic`, sources image with
`NVIDIA_NIC_DRIVERS_INVENTORY_PATH` bind-mounted. **The build path worked:**
`doca-kernel-support` took 3m14s and exited 0, packages were harvested and copied to the
inventory, checksum and `.buildconfig` were written, and all packages installed cleanly.
No errors anywhere in the log.

**The first run did not exercise the module load.** The node was not clean, and a module
with srcversion `396D71CC…` — identical to the one just built — was already loaded in the
kernel. `srcversion` hashes the module sources rather than a particular build, so a previous
install from the same 26.07-0.7.7.0 sources produces the same value.
`checkLoadedKmodSrcverVsModinfo` therefore found all three modules already correct, skipped
`restartDriver`, and left `newDriverLoaded` false — which is why the stop sequence logged
`Keeping currently loaded Mellanox OFED Driver...` rather than restoring.

**Second run, with the fix and a genuine load.** After `/etc/init.d/openibd restart` put the
node back on its own DKMS-installed OFED 26.01-1.0.0, the loaded srcversion no longer matched,
so the entrypoint had to unload 26.01 and load the freshly built modules — `ethtool -i` then
reported `version: 2607.0.100` and `Driver loaded successfully`. Build, install and load are
therefore all validated on a real node. The corrected component list also produced exactly
the baseline package set:

| Package | This run | B.8 `install.pl` |
|---|---|---|
| `mlnx-ofed-kernel-modules` | 55,277,878 B | 53 MB |
| `mlnx-ofed-kernel-utils` | 27,912 B | 27,912 B |
| `mlnx-tools` | 76,440 B | 1 MB |

No `kernel-mft-modules`, no `virtiofs-modules`. The utils package is byte-identical for the
third time. Note the cache had to be cleared by hand between runs: the component list lives
in the entrypoint binary and is not part of the fingerprint, so the corrected build would
otherwise have been skipped as a cache hit — the §10.2 gap, harmless in shipping but a real
trap when testing entrypoint changes.

Two things this confirmed that only a real node could. The strip fix holds outside the POC:
`mlnx-ofed-kernel-modules` came out at 52.7 MB, matching B.8. And `mlnx-ofed-kernel-utils`
was again byte-identical at 27,912 B. The node's kernel was `-136` while the image happens
to carry `-139` headers, so this also exercised the header install for real.

**The bug: two packages install.pl never produced.**

| Package | Size | In B.8 baseline? |
|---|---|---|
| `mlnx-ofed-kernel-modules` | 52.7 MB | yes |
| `mlnx-ofed-kernel-utils` | 27,912 B | yes |
| `mlnx-tools` | 76,440 B | yes |
| `kernel-mft-modules` | 465,278 B | **no** |
| `virtiofs-modules` | 86,550 B | **no** |

`docaBuildableComponents` was incomplete — it omitted `virtiofs` and `kernel-mft`, so
neither was excluded from the archive and the tool built both. `install.pl` excluded
`kernel-mft` explicitly (`--without-kernel-mft`, A.4) and never built `virtiofs` at all.

The POCs could not have caught this: they pruned with an explicit `KEEP` list (B.6 used
`KEEP=mlnx-ofa_kernel`), which is exclusion by allow-list, whereas the Go implementation
excludes by deny-list and so depends on the list being complete. Fixed by taking the list
verbatim from the tool's `deb_rebuild_modules`, in its order, with a comment recording why
completeness matters. Both extras installed cleanly, so this was package bloat and
unrequested host modules rather than a failure.

> The general lesson for the rest of the migration: a deny-list against a vendor script is
> only as good as our reading of that script, and it fails silently by *adding* output. The
> RPM path has its own sequence in `rpm_rebuild_modules` and needs the same treatment.

**Still open from this run.** The tool logged `Kernel build option GDS enabled
(ubuntu:24.04)` and passed `--with-gds` to `mlnx-ofed-kernel`'s configure; the near-identical
modules package size suggests `install.pl` did the same, but it has not been verified.

### B.10 `ENABLE_NFSRDMA=true` — the other branch of component selection

Run on a second node (kernel `6.8.0-31-generic`), which exercised `selectedDriverComponents`
in the configuration every previous run had skipped:

```
driver.go:1328  Assembling driver source archive  {"components": ["mlnx-ofed-kernel", "mlnx-nfsrdma", "mlnx-nvme"]}
tar czf … --exclude=*/SOURCES/iser_*   --exclude=*/SOURCES/isert_*     --exclude=*/SOURCES/srp_*
          --exclude=*/SOURCES/virtiofs_* --exclude=*/SOURCES/fwctl_*   --exclude=*/SOURCES/knem_*
          --exclude=*/SOURCES/xpmem_*  --exclude=*/SOURCES/kernel-mft_*
```

Eight exclusions rather than the default run's ten — the eleven entries of
`docaBuildableComponents` minus the three selected. Five packages resulted, the baseline three
plus the two the flag asks for:

| Package | Size |
| --- | --- |
| `mlnx-ofed-kernel-modules` | 55,105,782 B |
| `mlnx-nvme-modules` | 376,072 B |
| `mlnx-tools` | 76,440 B |
| `mlnx-nfsrdma-modules` | 49,878 B |
| `mlnx-ofed-kernel-utils` | 27,910 B |

All five installed, `openibd restart` returned OK in 6.9 s, `mlx5_core` came up at 2607.0.100
driving `eth2`, and the entrypoint reached `configuration done, sleep`. Build time was 3 m 19 s.

**This node has no OFED on the host**, unlike B.9's. That shows up as repeated
`modprobe: FATAL: Module mlx_compat not found in directory /host/lib/modules/6.8.0-31-generic`
from the `-d /host` dependency preload in `restartDriver`, for `mlx_compat`, `mlxdevm` and the
other OFED-supplied names — they exist only inside the container. The errors are deliberately
discarded (`_, _, _ =`) and openibd then loaded everything from the container tree, so the run
is unaffected. Worth knowing that `FATAL` in these logs is expected on a clean node rather than
a symptom.

The cache missed here for an uninteresting reason — the kernel differed from every earlier run,
so the inventory path did too. Flipping the flag back on the same node isolated the part that
matters, below.

### B.10.1 Flipping `ENABLE_NFSRDMA` back off — the fingerprint is what catches it

Rerun on the same node with `ENABLE_NFSRDMA=false`: same kernel, same inventory directory, only
the build config differing. **The checksum matched** — `e900eec3913a2cbb70abf7232c852cde`, byte
for byte what the previous run stored — so on checksum alone the stale five-package inventory
would have been served for a three-package configuration. The fingerprint is the only thing
that caught it:

```
driver.go:1553  Checksum calculation output  {"output": "e900eec3913a2cbb70abf7232c852cde  -\n"}
driver.go:1047  Build config has changed since last build, invalidating cache and rebuilding
                {"stored":  "ENABLE_NFSRDMA=true\nUSE_DKMS=false\nAPPEND_DRIVER_BUILD_FLAGS=",
                 "current": "ENABLE_NFSRDMA=false\nUSE_DKMS=false\nAPPEND_DRIVER_BUILD_FLAGS="}
```

Everything downstream followed correctly: prerequisites installed (a build was genuinely
needed, so the deferral let them through), ten exclusions this time, `["mlnx-ofed-kernel"]`
selected, and the stale inventory wiped rather than merged — the directory ends with exactly the
three baseline packages and no `mlnx-nfsrdma-modules` or `mlnx-nvme-modules` left behind from the
run before. Build took 2 m 14 s, `openibd restart` returned OK, `mlx5_core` came up at
2607.0.100.

This is the case §10.2 worried about in the abstract — a cache whose contents are valid but
whose *configuration* is stale — and the two mechanisms divide the work exactly as intended:
the checksum guards the files, the fingerprint guards the inputs.

### B.11 Still to verify

- ~~Cache hit skips the build and the deferred prerequisites~~ — done, see §10.3.
- ~~`ENABLE_NFSRDMA=true` builds the two extra components~~ — done, see B.10.
- ~~Fingerprint invalidation when a flag flips~~ — done, see B.10.1.
- ~~Restore-on-termination~~ — attempted on B.10's node and it fails, for reasons that predate
  this work and affect any inbox host. See C.5.
- `USE_DKMS=true` on Ubuntu must still reach `install.pl` after the dispatch change in
  `buildDriverFromSource`. Untested since that change landed.
- ~~Compare `mlnx-tools` file lists between the two paths~~ — there was no gap. B.8 originally
  recorded the `install.pl` build as "1 MB"; the artifact is 76,440 B, the same as
  `buildMlnxTools` produces. The figure was a transcription error, not a finding.
- Complete the RPM component list from `rpm_rebuild_modules` before migrating that path,
  for the same reason B.9 found on the deb side.
- Decide what `USE_DKMS=true` means on Ubuntu once `install.pl` is gone (§9.1).
- Rerun both paths with `--network=none` to close out R6 properly.
- `SPOOF_DISTRO=rhel:9.8` to see what `--with-gds` and the real `dist` tag change.
- RT and 64k kernel variants (R5), given the "no customized kernels" disclaimer.
- The same baseline diff for the RPM path, which has not been done.
- Optional, not gating: strip the pre-existing LTO bytecode from deb modules (B.7).

---

## Appendix C — Pre-existing bugs, unrelated to this work

> **Not caused by the `install.pl` migration and not fixed by it.** These were noticed while
> reading logs from the B.9 runs and are recorded here only so they are not lost. They
> reproduce equally on an unmodified `install.pl` build of the same OFED version, and they
> should be fixed on their own schedule, not as part of this change.

### C.1 `UNLOAD_STORAGE_MODULES` injects nothing on 26.07, and claims success

Both entrypoints extend openibd's module unload list by appending a line to
`/usr/share/mlnx_ofed/mod_load_funcs` with `sed`, addressed at
`/^[[:space:]]*UNLOAD_MODULES="[a-z]/`. That variable no longer exists in 26.07:

| Release | `UNLOAD_MODULES` lines | `grep ib_iser -c` |
| --- | --- | --- |
| 25.07 | 13 | 4 |
| 26.07 | 0 | 2 |

With no line to match, `sed` appends nothing and exits 0. The run then logs
`Successfully added storage modules to unload script`.

It reports success because both layers of the check are defeated. The Go guard reads the
wrong return value — `RunCommand` yields stdout then stderr, and this call binds the second
one to a variable named `stdout`:

```2419:2429:entrypoint/internal/driver/driver.go
	grepCmd := fmt.Sprintf("grep %s %s -c", d.cfg.StorageModules[0], unloadStorageScript)
	_, stdout, err := d.cmd.RunCommand(ctx, "sh", "-c", grepCmd)
	if err != nil {
		return fmt.Errorf("failed to verify storage modules injection: %w", err)
	}

	count := strings.TrimSpace(stdout)
	log.V(1).Info("Verification result", "grepCmd", grepCmd, "count", count)

	if count == "0" {
```

`count` is therefore always empty and the `count == "0"` branch is unreachable — visible in
the field log as `"count": ""` on the same line where the command printed `2`. This is an
isolated slip rather than a pattern: every other `RunCommand` call in the tree names the
second value `stderr` correctly.

The fallback would normally still catch it, since `grep -c` exits 1 on zero matches, but the
pattern is the first configured module — `ib_iser` — which matches `ib_isert` as a substring.
26.07 contains `ib_iser` and `ib_isert` on two unrelated lines, so the count is 2 and the
command exits 0. `entrypoint.sh` has the same defect at a different line, checking
`grep ib_isert … -c -lt 1`, which likewise passes on a pre-existing line.

**The right fix is probably deletion, not repair.** 26.07 replaced the static list with a
recursive dependency walk that discovers dependents at runtime:

```1232:1238:ofed/MLNX_OFED_SRC-26.07-0.7.7.0/SOURCES/ofed_scripts/mod_load_funcs
unload_modules() {
    local m
    reset_unload_globals
    for m in ib_core mlxfw mlx5_core mlx_compat memtrack; do
        unload_modules_rec "$m"
    done
}
```

`ib_iser` and the rest are dependents of `ib_core`, so `unload_modules_rec` reaches them
without being told to. The injection appears to be obsolete rather than broken-and-needed,
but that should be confirmed against a case where storage modules are genuinely in use
before the code is removed.

### C.2 The bash entrypoint hard-fails on third-party RDMA modules under 26.07

`unload_third_party_rdma_modules` in `entrypoint.sh` performs the same `sed` against the same
missing variable, but verifies it correctly with
`grep -q "UNLOAD_MODULES=.*${first_mod}"`. On 26.07 that grep finds nothing and the function
calls `exit_entryp 1`. So setting `THIRD_PARTY_RDMA_MODULES` aborts the legacy entrypoint
outright on this OFED version.

The Go entrypoint is unaffected: it handles third-party modules through the blacklist file
rather than by patching `mod_load_funcs`, so it has no equivalent call site.

### C.3 GCC is installed on every start, before the cache is consulted

`prepareGCC` runs from the sources branch of `Prepare` (`driver.go:164`), which is upstream of
`Build` and therefore upstream of `checkDriverInventory`. It reads `/proc/version`, derives the
major version of the compiler the running kernel was built with, and installs it:

```760:772:entrypoint/internal/driver/driver.go
func (d *driverMgr) installGCCUbuntu(ctx context.Context, majorVersion int) (string, string, error) {
	log := logr.FromContextOrDiscard(ctx)
	kernelGCCVer := fmt.Sprintf("gcc-%d", majorVersion)

	log.V(1).Info("Installing GCC for Ubuntu", "package", kernelGCCVer)
	_, _, err := d.cmd.RunCommand(ctx, "apt-get", "-yq", "update")
	if err != nil {
		return "", "", fmt.Errorf("failed to update apt packages: %w", err)
	}
	_, _, err = d.cmd.RunCommand(ctx, "apt-get", "-yq", "install", kernelGCCVer)
	if err != nil {
		return "", "", fmt.Errorf("failed to install %s: %w", kernelGCCVer, err)
	}
```

A cache hit compiles nothing, so on that path the work is pure overhead — about 6 s of it in
the field run (19:33:47.744 to 19:33:53.784), nearly all in `apt-get update`, ending in
`gcc-13 is already the newest version`.

It was already installed because noble's `build-essential` pulls `gcc-13` in transitively; the
Dockerfile only asks for `gcc-12` (`GCC_VER="-12"`). So it is a no-op *for this kernel*. A
kernel built with a compiler the image does not happen to carry would make it a real download,
which is the case the code exists for.

Note both calls are fatal on error, and this runs before the cache check, so it is a second
offline blocker independent of §10.3 — and an earlier one. Whether `apt-get install` of an
already-installed package succeeds with empty package lists (the image clears
`/var/lib/apt/lists/*`) has not been tested.

The ordering question is the same one §10.3 answered for prerequisites: a step that exists to
support compilation should sit on the branch that compiles.

### C.4 `linux-modules-extra` is refetched on every start — worth caching, or possibly dropping

The 153 MB fetch described in §10.3 happens on every container start, cache hit or not, because
the container filesystem is fresh each time while the inventory cache only covers OFED packages.

Two directions, neither investigated:

**Cache it.** The inventory mount is already host-persistent and already keyed by kernel
version, which is exactly the key this needs. The trap is that it must *not* be written into
the inventory directory itself: the cache checksum is
`find <dir> -type f -exec md5sum {} + | md5sum` over that directory, so any extra file changes
the checksum and would force a rebuild on every start — the opposite of the intent. A sibling
directory such as `<inventory>/<kernel>/inbox-modules/` avoids that.

**Why it is needed — the container's own tree is the real load path.** The cache-hit log
settles this. The OFED packages install into the *container* at
`/lib/modules/<kernel>/updates/dkms/`, `depmod <kernel>` then runs over that tree, and the
actual load is `/etc/init.d/openibd restart` executing inside the container, followed by plain
`modprobe mlx5_vdpa`, `mlx5_fwctl` and `mlx5_dpll` — none of which pass `-d`, so all of them
resolve against the container's tree:

```
driver.go:2062  Checking module {"module": "mlx5_core"}
  modinfo mlx5_core → filename: /lib/modules/6.8.0-136-generic/updates/dkms/mlx5_core.ko
                      version:  2607.0.100
                      depends:  mlxdevm,pci-hyperv-intf,tls,psample,mlx_compat,mlxfw
  /etc/init.d/openibd restart → Unloading HCA driver: [ OK ] / Loading HCA driver: [ OK ]
```

Of those six dependencies, OFED supplies `mlxdevm`, `mlx_compat` and `mlxfw`; `pci-hyperv-intf`,
`tls` and `psample` are inbox. Without `linux-modules`/`linux-modules-extra` unpacked in the
container there is nothing for `depmod` to resolve those three names against, so `modules.dep`
comes out incomplete and openibd's `modprobe` fails on a missing dependency. The package is
load-bearing, not decorative.

The `modprobe -d /host` calls in `restartDriver` do *not* remove that need — they are a
separate step that seeds the host's copies of those modules into the running kernel before the
restart, and they read the host tree rather than the container's.

**So the useful version of "cache it" is: stop downloading what is already mounted.** The host
tree is bind-mounted at `/host/lib/modules` and, on any node capable of running these modules
at all, already contains `pci-hyperv-intf`, `tls` and `psample` — the host's own driver needs
them too. Populating the container's tree from `/host/lib/modules/<kernel>/` before `depmod`,
rather than fetching 153 MB from `archive.ubuntu.com`, would cost nothing, work offline, and
need no new cache directory. The open question is whether a partial copy is enough or the whole
`kernel/` subtree has to come across for `depmod` to be happy.

### C.5 Restore-on-termination cannot restore a genuinely inbox host

`RESTORE_DRIVER_ON_POD_TERMINATION=true` ends in `Unload` running
`/usr/sbin/mlnxofedctl --alt-mods force-restart`, with no fallback — any non-zero exit fails
the shutdown. On B.10's node, whose host carries no OFED, it exits 1:

```
Unloading HCA driver:                                      [  OK  ]
No HCA kernel modules loaded:                              [FAILED]
Loading HCA driver and Access Layer:                       [FAILED]
```

`--alt-mods` re-execs under `unshare --mount` and bind-mounts the host tree over the
container's, so openibd then runs against `/host/lib/modules`:

```43:46:/tmp/mtx/mlnx-tools-2607.0.6/sbin/mlnxofedctl
run_with_host_modules() {
	if ! $USE_ALT_MODS_DIR; then return; fi
	mount -r -o bind "$ALT_MODS_DIR" /lib/modules
}
```

The unload half works. The load half does nothing, because openibd decides what to load by
asking whether each module is an OFED module, and its test for that is whether the module's
`depends:` line mentions `mlx_compat`:

```257:277:ofed/MLNX_OFED_SRC-26.07-0.7.7.0/SOURCES/ofed_scripts/mod_load_funcs
check_mlnx_ofed_module() {
    local modinfo_output
    modinfo_output=`modinfo -Fdepends "$1" 2>/dev/null`
    if [ $? = 0 ]; then
        if echo "$modinfo_output" | grep -q mlx_compat; then
            echo "yes"
            return 0
        fi
    fi
    echo "no"
    return 1
}

set_module_load_defaults() {
    MLX5_LOAD=${MLX5_LOAD:-`check_mlnx_ofed_module mlx5_core || :`}
```

`mlx_compat` is an OFED-only shim, so no inbox module ever mentions it. On an inbox host
`MLX5_LOAD` comes out `no` — as do `UMAD_LOAD`, `UVERBS_LOAD`, `IPOIB_LOAD`, `RDMA_CM_LOAD` and
`RDMA_UCM_LOAD` — and `load_mlx5` returns at its first line without loading anything.
`MODULES_LOADED_STATUS` keeps the `"1"` it is initialised to, which produces both `[FAILED]`
lines and `exit 1`. The absence of any per-module failure message in the output is the tell:
nothing was attempted, rather than attempted and failed.

`force-restart` does not help. It sets `FORCE=1`, but that is only read inside `load_module`,
to relax the "Avoid loading inbox module" gate. The short-circuit happens earlier, in
`set_module_load_defaults`, which never consults `FORCE`.

**Consequence: the node is left with no driver at all** — unloaded, not reloaded. Recovery is
`modprobe mlx5_ib mlx5_core` on the host. The entrypoint removes its blacklist file before
this point, so nothing obstructs the reload.

So the restore path can only restore a host that *also* has OFED installed, which is why B.9's
node was never going to prove anything either — a restore there lands on its DKMS OFED 26.01.
Unrelated to this migration: `mlnxofedctl` comes from `mlnx-tools` and `openibd` from
`mlnx-ofed-kernel-utils`, both of which the new path builds, and the outcome is decided purely
by the contents of the host tree.
