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

package dtk

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/Mellanox/doca-driver-build/entrypoint/internal/config"
	"github.com/Mellanox/doca-driver-build/entrypoint/internal/constants"
	"github.com/Mellanox/doca-driver-build/entrypoint/internal/utils/cmd"
	"github.com/Mellanox/doca-driver-build/entrypoint/internal/utils/doca"
	"github.com/go-logr/logr"
)

// RunBuild executes the DTK driver build logic
func RunBuild(ctx context.Context, log logr.Logger, cfg config.Config, cmdHelper cmd.Interface) error {
	log.Info("DTK driver build script start")

	if cfg.DtkOcpStartCompileFlag == "" || cfg.DtkOcpDoneCompileFlag == "" ||
		cfg.DtkOcpNicSharedDir == "" || cfg.DtkOcpCompiledDriverVer == "" ||
		cfg.DtkOcpKernelVer == "" || cfg.DtkOcpDistro == "" {
		err := fmt.Errorf("required DTK environment variables not set: %s, %s, %s, %s, %s, %s",
			cfg.DtkOcpStartCompileFlag, cfg.DtkOcpDoneCompileFlag, cfg.DtkOcpNicSharedDir,
			cfg.DtkOcpCompiledDriverVer, cfg.DtkOcpKernelVer, cfg.DtkOcpDistro)
		log.Error(err, "aborting")
		return err
	}

	// Nothing is installed from a repository here. The driver-toolkit sees only the three
	// UBI repos and has no entitlements, so anything not already in the image has to
	// arrive as a file on the shared volume. What install.pl needed and this path does not
	// -- perl, ethtool, pciutils, python3-devel -- is simply gone.

	// Wait for start flag
	retryDelay := 3 * time.Second
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		if _, err := os.Stat(cfg.DtkOcpStartCompileFlag); err == nil {
			break
		}
		log.Info("Awaiting driver container preparations prior compilation", "next_query_sec", retryDelay.Seconds())

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(retryDelay):
		}
	}

	log.Info("Starting compilation of driver", "version", cfg.DtkOcpCompiledDriverVer)

	if err := installBuildTooling(ctx, log, cfg, cmdHelper); err != nil {
		return err
	}

	if err := runDocaKernelSupport(ctx, log, cfg, cmdHelper); err != nil {
		return err
	}

	// Create done flag
	if _, err := os.Create(cfg.DtkOcpDoneCompileFlag); err != nil {
		return fmt.Errorf("failed to create done flag: %w", err)
	}

	// Remove start flag
	if err := os.Remove(cfg.DtkOcpStartCompileFlag); err != nil {
		log.Error(err, "failed to remove start flag")
		// Non-fatal
	}

	log.Info("DTK driver build script end")

	// Sleep infinity with context support
	log.Info("Build completed, sleeping indefinitely")
	<-ctx.Done()
	return ctx.Err()
}

// installBuildTooling makes doca-kernel-support runnable in a container that never
// installed doca-extra.
//
// Two separate gaps are closed. The tool's own files are copied to the absolute path it
// expects, because RES_FOLDER is a constant inside the script and it reads
// find-provides.ksyms from underneath it -- it cannot be run from the shared volume. And
// createrepo_c and kernel-abi-stablelists are installed from staged RPMs, because the
// tool's dependency check would otherwise try to dnf-install them and fail: they are
// absent from the UBI repos the driver-toolkit can see.
func installBuildTooling(ctx context.Context, log logr.Logger, cfg config.Config, cmdHelper cmd.Interface) error {
	// Guarded so a restarted sidecar skips the work, and so this becomes a no-op if a
	// future driver-toolkit ships the packages itself.
	if _, _, err := cmdHelper.RunCommand(ctx, "rpm", "-q", "--whatprovides", "createrepo"); err != nil {
		depsGlob := filepath.Join(cfg.DtkOcpNicSharedDir, constants.DtkBuildDepsDirName, "*.rpm")
		deps, globErr := filepath.Glob(depsGlob)
		if globErr != nil {
			return fmt.Errorf("failed to list staged build dependencies: %w", globErr)
		}
		if len(deps) == 0 {
			return fmt.Errorf("no build dependency RPMs staged at %s", depsGlob)
		}

		log.Info("Installing staged build dependencies", "count", len(deps))
		args := append([]string{"-Uvh", "--replacepkgs"}, deps...)
		if _, _, err := cmdHelper.RunCommand(ctx, "rpm", args...); err != nil {
			return fmt.Errorf("failed to install staged build dependencies: %w", err)
		}
	}

	if _, _, err := cmdHelper.RunCommand(ctx, "mkdir", "-p", doca.ResourcesDir); err != nil {
		return fmt.Errorf("failed to create %s: %w", doca.ResourcesDir, err)
	}

	stagedTools := filepath.Join(cfg.DtkOcpNicSharedDir, constants.DtkToolsDirName)
	for _, dest := range doca.StagedFiles {
		rel, err := filepath.Rel(doca.ToolsDir, dest)
		if err != nil {
			return fmt.Errorf("failed to resolve staged tool path %s: %w", dest, err)
		}
		src := filepath.Join(stagedTools, rel)
		log.V(1).Info("Installing build tool", "from", src, "to", dest)
		if _, _, err := cmdHelper.RunCommand(ctx, "install", "-m", "0755", src, dest); err != nil {
			return fmt.Errorf("failed to install %s: %w", dest, err)
		}
	}

	return nil
}

// runDocaKernelSupport builds the modules and leaves the results where the driver
// container can find them.
//
// The tool builds under a mktemp directory it chooses itself and reports only on stdout,
// so locating and harvesting the output has to happen here rather than on the other side
// of the shared volume.
func runDocaKernelSupport(ctx context.Context, log logr.Logger, cfg config.Config, cmdHelper cmd.Interface) error {
	archive := filepath.Join(cfg.DtkOcpNicSharedDir, constants.DtkSourceArchiveName)

	// -s rather than -k: it names the source tree directly, which disambiguates the
	// standard kernel from an RT one, and avoids depending on the /lib/modules/<ver>/build
	// symlink that -k resolves through.
	//
	// --dirty preserves packages/<kver>/<component>/; without it the loose packages are
	// deleted in favour of the doca-kernel-repo wrapper, which would then have to be
	// unpacked again.
	//
	// No --distro: unlike the driver container, whose image base is pinned independently
	// of the node, the driver-toolkit is built for the exact RHCOS it runs on, so its own
	// /etc/os-release is the authority the tool should read.
	args := []string{
		"--verbose", "--dirty",
		"-s", filepath.Join("/usr/src/kernels", cfg.DtkOcpKernelVer),
		"--tarfile", archive,
	}

	log.Info("Executing build command", "command", doca.KernelSupportBin, "args", args)
	stdout, _, err := cmdHelper.RunCommand(ctx, doca.KernelSupportBin, args...)
	if err != nil {
		if ctx.Err() != nil {
			log.Info("Build canceled by context")
			return ctx.Err()
		}
		return fmt.Errorf("driver build failed: %w", err)
	}

	topDir := doca.ParseTopDir(stdout)
	if topDir == "" {
		return fmt.Errorf("could not determine doca-kernel-support work directory from its output")
	}

	destDir := filepath.Join(cfg.DtkOcpNicSharedDir, constants.DtkPackagesDirName)
	harvest := doca.HarvestScript(doca.PackagesDir(topDir, cfg.DtkOcpKernelVer), "rpm", destDir)
	if _, _, err := cmdHelper.RunCommand(ctx, "sh", "-c", harvest); err != nil {
		return fmt.Errorf("failed to collect packages built by doca-kernel-support: %w", err)
	}

	log.Info("Published packages to the shared volume", "dir", destDir)
	return nil
}
