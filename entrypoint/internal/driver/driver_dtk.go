/*
 Copyright 2025, NVIDIA CORPORATION & AFFILIATES

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
*/

package driver

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/go-logr/logr"

	"github.com/Mellanox/doca-driver-build/entrypoint/internal/constants"
	"github.com/Mellanox/doca-driver-build/entrypoint/internal/utils/doca"
	hostutils "github.com/Mellanox/doca-driver-build/entrypoint/internal/utils/host"
)

// dtkBuildDepsImageDir holds the RPMs the driver-toolkit cannot install for itself,
// downloaded into this image at build time on a subscription-entitled host. See the
// dtk-deps step in RHEL_Dockerfile. A variable only so tests can point it somewhere
// writable.
var dtkBuildDepsImageDir = "/opt/mellanox/dtk-deps"

// buildDriverDTK orchestrates the driver build using the OpenShift Driver Toolkit (DTK)
func (d *driverMgr) buildDriverDTK(ctx context.Context, kernelVersion, inventoryPath, osType string) error {
	log := logr.FromContextOrDiscard(ctx)
	log.Info("Starting DTK driver build")

	// Sanitize kernel version for DTK shared directory
	// Matches bash: DTK_KVER=$(echo "${FULL_KVER}" | sed 's/[^-A-Za-z0-9_.]/_/g' | sed 's/^[-_.]*//;s/[-_.]*$//')
	dtkKver := sanitizeKernelVersion(kernelVersion)
	dtkSharedDir := filepath.Join(d.cfg.DtkOcpNicSharedDir, dtkKver)

	// Construct done flag path
	// Matches bash: DTK_OCP_DONE_COMPILE_FLAG="${DTK_OCP_DONE_COMPILE_FLAG_PREFIX}$(echo ${NVIDIA_NIC_DRIVER_VER} | sed 's/[.-]/_/g')"
	verSanitized := strings.ReplaceAll(strings.ReplaceAll(d.cfg.NvidiaNicDriverVer, ".", "_"), "-", "_")
	doneFlagName := constants.DtkDoneCompileFlagPrefix + verSanitized
	doneFlagPath := filepath.Join(dtkSharedDir, doneFlagName)
	startFlagPath := filepath.Join(dtkSharedDir, constants.DtkStartCompileFlag)

	// Check if build is already done
	if _, err := d.os.Stat(doneFlagPath); os.IsNotExist(err) {
		log.Info("DTK build not done, setting up build")

		if err := d.dtkSetupDriverBuild(ctx, dtkSharedDir, startFlagPath, doneFlagPath,
			kernelVersion, osType); err != nil {
			return fmt.Errorf("failed to setup DTK build: %w", err)
		}

		if err := d.dtkWaitForBuild(ctx, doneFlagPath); err != nil {
			return fmt.Errorf("failed waiting for DTK build: %w", err)
		}
	} else {
		log.Info("DTK build already done", "flag", doneFlagPath)
	}

	// Finalize build (copy artifacts)
	if err := d.dtkFinalizeDriverBuild(ctx, dtkSharedDir, inventoryPath, osType); err != nil {
		return fmt.Errorf("failed to finalize DTK build: %w", err)
	}

	return nil
}

// sanitizeKernelVersion sanitizes the kernel version string for use in directory names
func sanitizeKernelVersion(version string) string {
	// Replace all non-alphanumeric characters (except -._) with underscore
	reg := regexp.MustCompile(`[^-A-Za-z0-9_.]`)
	sanitized := reg.ReplaceAllString(version, "_")
	// Trim leading/trailing -._
	return strings.Trim(sanitized, "-._")
}

// dtkSetupDriverBuild prepares the shared directory and script for DTK build
func (d *driverMgr) dtkSetupDriverBuild(ctx context.Context,
	sharedDir, startFlagPath, doneFlagPath, kernelVersion, osType string,
) error {
	log := logr.FromContextOrDiscard(ctx)
	log.Info("Setting up DTK driver build", "sharedDir", sharedDir)

	// Create shared directory
	if err := d.os.MkdirAll(sharedDir, 0o755); err != nil {
		return fmt.Errorf("failed to create shared directory: %w", err)
	}

	// Hand the sidecar a source archive rather than a source tree. doca-kernel-support
	// takes --tarfile, and since it has no --without-<pkg>, which components the archive
	// contains is how they are selected -- so it must be assembled here, where
	// ENABLE_NFSRDMA is known, and not in the sidecar.
	archivePath := filepath.Join(sharedDir, constants.DtkSourceArchiveName)
	if _, err := d.stageDriverArchive(ctx, d.cfg.NvidiaNicDriverPath, osType, archivePath); err != nil {
		return err
	}

	if err := d.dtkStageBuildTooling(ctx, sharedDir); err != nil {
		return err
	}

	// The sidecar harvests into this directory, so it has to exist before the start flag
	// goes up.
	if err := d.os.MkdirAll(filepath.Join(sharedDir, constants.DtkPackagesDirName), 0o755); err != nil {
		return fmt.Errorf("failed to create shared packages directory: %w", err)
	}

	// Copy entrypoint binary to shared directory
	entrypointPath := "/root/entrypoint" // Assumed location based on Dockerfile
	destEntrypointPath := filepath.Join(sharedDir, "entrypoint")
	log.Info("Copying entrypoint binary", "from", entrypointPath, "to", destEntrypointPath)
	// We use copyFile instead of copyDir for a single file
	if _, _, err := d.cmd.RunCommand(ctx, "cp", entrypointPath, destEntrypointPath); err != nil {
		return fmt.Errorf("failed to copy entrypoint binary: %w", err)
	}

	// Create dtk.env file. Both ends of this file are the same binary: the sidecar runs the
	// entrypoint copied above, so the field set can change freely without a compatibility window.
	distro, err := d.dtkDistro(ctx, kernelVersion)
	if err != nil {
		return err
	}
	appendFlagsStr := strings.Join(d.getAppendDriverBuildFlags(constants.OSTypeRedHat), " ")

	envContent := fmt.Sprintf(`export DTK_OCP_NIC_SHARED_DIR="%s"
export DTK_OCP_COMPILED_DRIVER_VER="%s"
export DTK_OCP_START_COMPILE_FLAG="%s"
export DTK_OCP_DONE_COMPILE_FLAG="%s"
export DTK_OCP_KERNEL_VER="%s"
export DTK_OCP_DISTRO="%s"
export APPEND_DRIVER_BUILD_FLAGS="%s"
export USE_NEW_ENTRYPOINT="true"
export NVIDIA_NIC_DRIVER_VER="%s"
export USE_DKMS="%v"
`, sharedDir, d.cfg.NvidiaNicDriverVer, startFlagPath, doneFlagPath,
		kernelVersion, distro, appendFlagsStr, d.cfg.NvidiaNicDriverVer, d.cfg.UseDKMS)

	envPath := filepath.Join(sharedDir, "dtk.env")
	if err := d.os.WriteFile(envPath, []byte(envContent), 0o644); err != nil {
		return fmt.Errorf("failed to write dtk.env: %w", err)
	}

	// Copy build script (loader)
	srcScriptPath := constants.DtkOcpBuildScriptPath
	destScriptPath := filepath.Join(sharedDir, filepath.Base(srcScriptPath))
	log.Info("Copying build script", "from", srcScriptPath, "to", destScriptPath)
	// We use copyFile equivalent (run command cp)
	if _, _, err := d.cmd.RunCommand(ctx, "cp", srcScriptPath, destScriptPath); err != nil {
		return fmt.Errorf("failed to copy build script: %w", err)
	}

	// Create start flag
	log.Info("Creating start compile flag", "path", startFlagPath)
	if _, err := d.os.Create(startFlagPath); err != nil {
		return fmt.Errorf("failed to create start flag: %w", err)
	}

	return nil
}

// dtkStageBuildTooling puts doca-kernel-support and the build dependencies the
// driver-toolkit lacks onto the shared volume.
//
// The sidecar cannot install doca-extra: it has no DOCA repo, and no entitlements for the
// RHEL repos either. Both halves of that gap are answered here with files. The tool's own
// three files come from this image, where doca-extra is installed; the RPMs were fetched
// at image build time on an entitled host.
func (d *driverMgr) dtkStageBuildTooling(ctx context.Context, sharedDir string) error {
	log := logr.FromContextOrDiscard(ctx)

	toolsDir := filepath.Join(sharedDir, constants.DtkToolsDirName)
	// The layout under toolsDir mirrors doca.ToolsDir exactly, because RES_FOLDER is an
	// absolute constant inside the script: the sidecar has to reconstruct that path, so
	// what it copies from has to have the same shape.
	if err := d.os.MkdirAll(filepath.Join(toolsDir, filepath.Base(doca.ResourcesDir)), 0o755); err != nil {
		return fmt.Errorf("failed to create shared tools directory: %w", err)
	}

	for _, src := range doca.StagedFiles {
		rel, err := filepath.Rel(doca.ToolsDir, src)
		if err != nil {
			return fmt.Errorf("failed to resolve staged tool path %s: %w", src, err)
		}
		dest := filepath.Join(toolsDir, rel)
		log.V(1).Info("Staging build tool", "from", src, "to", dest)
		if _, _, err := d.cmd.RunCommand(ctx, "cp", "-f", src, dest); err != nil {
			return fmt.Errorf("failed to stage %s: %w", src, err)
		}
	}

	depsDir := filepath.Join(sharedDir, constants.DtkBuildDepsDirName)
	if err := d.os.MkdirAll(depsDir, 0o755); err != nil {
		return fmt.Errorf("failed to create shared build dependency directory: %w", err)
	}

	entries, err := d.os.ReadDir(dtkBuildDepsImageDir)
	if err != nil {
		return fmt.Errorf("failed to read %s: %w", dtkBuildDepsImageDir, err)
	}

	staged := 0
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".rpm") {
			continue
		}
		if _, _, err := d.cmd.RunCommand(ctx, "cp", "-f",
			filepath.Join(dtkBuildDepsImageDir, entry.Name()),
			filepath.Join(depsDir, entry.Name())); err != nil {
			return fmt.Errorf("failed to stage build dependency %s: %w", entry.Name(), err)
		}
		staged++
	}

	if staged == 0 {
		return fmt.Errorf("no build dependency RPMs in %s: the image was built without them, "+
			"and the driver-toolkit cannot install them itself", dtkBuildDepsImageDir)
	}
	log.V(1).Info("Staged build dependencies for the DTK sidecar", "count", staged)

	return nil
}

// dtkDistro resolves the distro tag the sidecar builds against, e.g. "rhel9.8".
func (d *driverMgr) dtkDistro(ctx context.Context, kernelVersion string) (string, error) {
	versionInfo, err := d.host.GetRedHatVersionInfo(ctx)
	if err != nil {
		return "", fmt.Errorf("failed to get RedHat version info for DTK driver build: %w", err)
	}

	distroVersion := redHatDistroVersion(versionInfo, kernelVersion)
	if distroVersion == "" {
		return "", fmt.Errorf("failed to determine RHEL distro version for DTK driver build")
	}

	return "rhel" + distroVersion, nil
}

func redHatDistroVersion(versionInfo *hostutils.RedhatVersionInfo, kernelVersion string) string {
	if versionInfo != nil {
		if versionInfo.RHELVersion != "" {
			return versionInfo.RHELVersion
		}
		if versionInfo.OpenShiftVersion == "" && versionInfo.FullVersion != "" {
			return versionInfo.FullVersion
		}
	}

	if matches := regexp.MustCompile(`\.el([0-9]+)_([0-9]+)`).FindStringSubmatch(kernelVersion); len(matches) == 3 {
		return matches[1] + "." + matches[2]
	}
	if matches := regexp.MustCompile(`\.el([0-9]+)`).FindStringSubmatch(kernelVersion); len(matches) == 2 {
		return matches[1]
	}
	return ""
}

// dtkWaitForBuild waits for the DTK build to complete
func (d *driverMgr) dtkWaitForBuild(ctx context.Context, doneFlagPath string) error {
	log := logr.FromContextOrDiscard(ctx)
	log.Info("Waiting for DTK build to complete", "doneFlag", doneFlagPath)

	// Poll every 30s. Air-gapped builds from local RPM repos typically finish in ~180s,
	// but full first-time DTK compilations on slower nodes can exceed 15 min.
	// Max total timeout: sleepSec * totalRetries = 30 * 80 = 2400s (40 min).
	sleepSec := 30
	totalRetries := 80
	totalSleepSec := 0

	for totalRetries > 0 {
		if _, err := d.os.Stat(doneFlagPath); err == nil {
			log.Info("DTK build completed")
			return nil
		}

		log.Info("Awaiting DTK compilation", "next_query_sec", sleepSec)

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(sleepSec) * time.Second):
		}

		totalSleepSec += sleepSec
		totalRetries--
	}

	return fmt.Errorf("timeout (%d sec) awaiting DTK compilation, %s not found", totalSleepSec, doneFlagPath)
}

// dtkFinalizeDriverBuild copies the built artifacts back to the inventory.
//
// The sidecar leaves its packages in a fixed directory on the shared volume rather than
// in the build tree: doca-kernel-support builds under a mktemp directory of its own
// choosing that only it can name, so harvesting is its job, and this end just collects.
func (d *driverMgr) dtkFinalizeDriverBuild(ctx context.Context, sharedDir, inventoryPath, osType string) error {
	log := logr.FromContextOrDiscard(ctx)
	log.Info("Finalizing DTK driver build", "inventoryPath", inventoryPath)

	if err := d.createInventoryDirectory(ctx, inventoryPath); err != nil {
		return err
	}

	packagesDir := filepath.Join(sharedDir, constants.DtkPackagesDirName)
	files, err := filepath.Glob(filepath.Join(packagesDir, "*."+docaPackageFormat(osType)))
	if err != nil {
		return fmt.Errorf("failed to glob package files: %w", err)
	}
	if len(files) == 0 {
		return fmt.Errorf("no packages found in %s", packagesDir)
	}

	log.Info("Copying packages built by the DTK sidecar",
		"from", packagesDir, "to", inventoryPath, "count", len(files))

	for _, file := range files {
		dest := filepath.Join(inventoryPath, filepath.Base(file))
		if _, _, err := d.cmd.RunCommand(ctx, "cp", "-f", file, dest); err != nil {
			return fmt.Errorf("failed to copy %s: %w", file, err)
		}
	}

	// mlnx-tools is built here rather than in the sidecar. doca-kernel-support does not
	// build it at all, and it is userspace-only, so it needs neither the target kernel's
	// headers nor anything else the sidecar exists to provide.
	if err := d.buildMlnxTools(ctx, d.cfg.NvidiaNicDriverPath, osType, inventoryPath); err != nil {
		return fmt.Errorf("failed to build mlnx-tools: %w", err)
	}

	return nil
}
