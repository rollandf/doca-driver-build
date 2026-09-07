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
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/go-logr/logr"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"

	"github.com/Mellanox/doca-driver-build/entrypoint/internal/config"
	"github.com/Mellanox/doca-driver-build/entrypoint/internal/constants"
	cmdMockPkg "github.com/Mellanox/doca-driver-build/entrypoint/internal/utils/cmd/mocks"
	"github.com/Mellanox/doca-driver-build/entrypoint/internal/utils/doca"
)

const testKernelVer = "5.14.0-687.13.1.el9_8.x86_64"

func testConfig(t *testing.T, sharedDir string) config.Config {
	t.Helper()
	return config.Config{
		DtkOcpStartCompileFlag:  filepath.Join(sharedDir, "dtk_start_compile"),
		DtkOcpDoneCompileFlag:   filepath.Join(sharedDir, "dtk_done_compile"),
		DtkOcpCompiledDriverVer: "1.0.0",
		DtkOcpNicSharedDir:      sharedDir,
		DtkOcpKernelVer:         testKernelVer,
		DtkOcpDistro:            "rhel9.8",
	}
}

// stageStubTooling writes the files the driver container would have put on the shared
// volume, so the sidecar has something to install.
func stageStubTooling(t *testing.T, sharedDir string) {
	t.Helper()

	depsDir := filepath.Join(sharedDir, constants.DtkBuildDepsDirName)
	assert.NoError(t, os.MkdirAll(depsDir, 0o755))
	assert.NoError(t, os.WriteFile(filepath.Join(depsDir, "createrepo_c-0.20.1.x86_64.rpm"), nil, 0o644))

	toolsDir := filepath.Join(sharedDir, constants.DtkToolsDirName)
	assert.NoError(t, os.MkdirAll(filepath.Join(toolsDir, "resources"), 0o755))
}

// expectToolingInstall mocks the staging step. createrepoErr controls whether the sidecar
// already has createrepo, which is what decides if the staged RPMs get installed.
func expectToolingInstall(cmdMock *cmdMockPkg.Interface, sharedDir string, createrepoErr error) {
	cmdMock.EXPECT().RunCommand(mock.Anything, "rpm", "-q", "--whatprovides", "createrepo").
		Return("", "", createrepoErr)

	if createrepoErr != nil {
		cmdMock.EXPECT().RunCommand(mock.Anything, "rpm", "-Uvh", "--replacepkgs",
			filepath.Join(sharedDir, constants.DtkBuildDepsDirName, "createrepo_c-0.20.1.x86_64.rpm")).
			Return("", "", nil)
	}

	cmdMock.EXPECT().RunCommand(mock.Anything, "mkdir", "-p", doca.ResourcesDir).Return("", "", nil)

	stagedTools := filepath.Join(sharedDir, constants.DtkToolsDirName)
	for _, dest := range doca.StagedFiles {
		rel, err := filepath.Rel(doca.ToolsDir, dest)
		if err != nil {
			panic(err)
		}
		cmdMock.EXPECT().RunCommand(mock.Anything, "install", "-m", "0755",
			filepath.Join(stagedTools, rel), dest).Return("", "", nil)
	}
}

func TestRunBuild(t *testing.T) {
	log := logr.Discard()

	t.Run("should fail if flags are not set", func(t *testing.T) {
		err := RunBuild(context.Background(), log, config.Config{}, nil)
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "required DTK environment variables not set")
	})

	t.Run("should reject a dtk.env without the kernel version", func(t *testing.T) {
		cfg := testConfig(t, t.TempDir())
		cfg.DtkOcpKernelVer = ""

		err := RunBuild(context.Background(), log, cfg, nil)
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "required DTK environment variables not set")
	})

	t.Run("should fail if the staged build dependencies are missing", func(t *testing.T) {
		sharedDir := t.TempDir()
		cfg := testConfig(t, sharedDir)

		cmdMock := cmdMockPkg.NewInterface(t)
		cmdMock.EXPECT().RunCommand(mock.Anything, "rpm", "-q", "--whatprovides", "createrepo").
			Return("", "", errors.New("not installed"))

		assert.NoError(t, os.WriteFile(cfg.DtkOcpStartCompileFlag, nil, 0o644))

		err := RunBuild(context.Background(), log, cfg, cmdMock)
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "no build dependency RPMs staged")
	})

	t.Run("should build with doca-kernel-support and publish packages to the shared volume",
		func(t *testing.T) {
			sharedDir := t.TempDir()
			cfg := testConfig(t, sharedDir)
			stageStubTooling(t, sharedDir)

			cmdMock := cmdMockPkg.NewInterface(t)
			expectToolingInstall(cmdMock, sharedDir, errors.New("not installed"))

			// Create start flag after a short delay
			go func() {
				time.Sleep(100 * time.Millisecond)
				f, err := os.Create(cfg.DtkOcpStartCompileFlag)
				assert.NoError(t, err)
				f.Close()
			}()

			topDir := "/tmp/DOCA.abc123"
			cmdMock.EXPECT().RunCommand(mock.Anything, doca.KernelSupportBin,
				"--verbose", "--dirty",
				"-s", "/usr/src/kernels/"+testKernelVer,
				"--tarfile", filepath.Join(sharedDir, constants.DtkSourceArchiveName)).
				Return("Building under "+topDir+"\n", "", nil)

			cmdMock.EXPECT().RunCommand(mock.Anything, "sh", "-c",
				doca.HarvestScript(doca.PackagesDir(topDir, testKernelVer), "rpm",
					filepath.Join(sharedDir, constants.DtkPackagesDirName))).
				Return("", "", nil)

			ctx, cancel := context.WithCancel(context.Background())
			errCh := make(chan error)
			go func() {
				errCh <- RunBuild(ctx, log, cfg, cmdMock)
			}()

			assert.Eventually(t, func() bool {
				_, err := os.Stat(cfg.DtkOcpDoneCompileFlag)
				return err == nil
			}, 5*time.Second, 100*time.Millisecond)

			assert.Eventually(t, func() bool {
				_, err := os.Stat(cfg.DtkOcpStartCompileFlag)
				return os.IsNotExist(err)
			}, 5*time.Second, 100*time.Millisecond)

			cancel()
			err := <-errCh
			assert.ErrorIs(t, err, context.Canceled)
		})

	t.Run("should skip installing staged RPMs when createrepo is already present",
		func(t *testing.T) {
			sharedDir := t.TempDir()
			cfg := testConfig(t, sharedDir)
			stageStubTooling(t, sharedDir)

			cmdMock := cmdMockPkg.NewInterface(t)
			expectToolingInstall(cmdMock, sharedDir, nil)

			assert.NoError(t, os.WriteFile(cfg.DtkOcpStartCompileFlag, nil, 0o644))

			topDir := "/tmp/DOCA.abc123"
			cmdMock.EXPECT().RunCommand(mock.Anything, doca.KernelSupportBin,
				"--verbose", "--dirty",
				"-s", "/usr/src/kernels/"+testKernelVer,
				"--tarfile", filepath.Join(sharedDir, constants.DtkSourceArchiveName)).
				Return("Building under "+topDir+"\n", "", nil)

			cmdMock.EXPECT().RunCommand(mock.Anything, "sh", "-c", mock.Anything).Return("", "", nil)

			ctx, cancel := context.WithCancel(context.Background())
			errCh := make(chan error)
			go func() {
				errCh <- RunBuild(ctx, log, cfg, cmdMock)
			}()

			assert.Eventually(t, func() bool {
				_, err := os.Stat(cfg.DtkOcpDoneCompileFlag)
				return err == nil
			}, 5*time.Second, 100*time.Millisecond)

			cancel()
			err := <-errCh
			assert.ErrorIs(t, err, context.Canceled)
		})

	t.Run("should fail when the tool does not report its work directory", func(t *testing.T) {
		sharedDir := t.TempDir()
		cfg := testConfig(t, sharedDir)
		stageStubTooling(t, sharedDir)

		cmdMock := cmdMockPkg.NewInterface(t)
		expectToolingInstall(cmdMock, sharedDir, nil)

		assert.NoError(t, os.WriteFile(cfg.DtkOcpStartCompileFlag, nil, 0o644))

		cmdMock.EXPECT().RunCommand(mock.Anything, doca.KernelSupportBin,
			mock.Anything, mock.Anything, mock.Anything, mock.Anything, mock.Anything, mock.Anything).
			Return("built everything, said nothing useful", "", nil)

		err := RunBuild(context.Background(), log, cfg, cmdMock)
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "could not determine doca-kernel-support work directory")
	})
}
