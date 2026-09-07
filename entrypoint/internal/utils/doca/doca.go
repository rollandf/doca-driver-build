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

// Package doca holds the parts of the doca-kernel-support contract that both containers
// which run the tool have to agree on: the driver container, where doca-extra is
// installed, and the OpenShift driver-toolkit sidecar, where it is not and has to be
// staged in.
package doca

import (
	"fmt"
	"path/filepath"
	"regexp"
)

// Where doca-extra installs the tool. These are not configurable: doca-kernel-support
// assigns RES_FOLDER to an absolute path and reads find-provides.ksyms from underneath it,
// so a container that stages the tool rather than installing the package must reproduce
// this layout exactly.
const (
	ToolsDir     = "/opt/mellanox/doca/tools"
	ResourcesDir = ToolsDir + "/resources"

	KernelSupportBin = ToolsDir + "/doca-kernel-support"
	// OfedVersionBin comes from doca-ofed-source, not doca-extra, but the tool calls it
	// unconditionally under set -e and dies without it.
	OfedVersionBin = ToolsDir + "/get_mlnx_ofed_version"
	// FindProvidesKsyms is passed to rpmbuild as __provided_ksyms_provides.
	FindProvidesKsyms = ResourcesDir + "/find-provides.ksyms"
)

// StagedFiles is everything a container needs in order to run doca-kernel-support without
// having the doca-extra package installed. Order matters only for readability.
var StagedFiles = []string{KernelSupportBin, OfedVersionBin, FindProvidesKsyms}

// topDirPattern matches the line doca-kernel-support prints to announce its working
// directory ("Building under /tmp/DOCA.XXXXXXXXXX"). The directory comes from mktemp and
// cannot be set by the caller, so parsing the output is the only way to locate the build.
var topDirPattern = regexp.MustCompile(`Building under (\S+)`)

// ParseTopDir extracts the working directory doca-kernel-support reports on stdout,
// returning "" when the output does not name one.
func ParseTopDir(output string) string {
	match := topDirPattern.FindStringSubmatch(output)
	if len(match) < 2 {
		return ""
	}
	return match[1]
}

// PackagesDir is where a finished build leaves its loose packages, given the working
// directory ParseTopDir found. --dirty is what keeps this directory from being deleted in
// favour of the doca-kernel-repo wrapper package.
func PackagesDir(topDir, kernelVersion string) string {
	return filepath.Join(topDir, "packages", kernelVersion)
}

// HarvestScript copies the packages a build produced into destDir, and fails if it
// produced none.
//
// Debug packages are dropped deliberately. The RPM path splits symbols out into a ~47MB
// -debuginfo and a -debugsource beside a 3MB kmod; anything left in the inventory is
// cached per kernel and installed onto every node, so they are pure waste there.
//
// The emptiness check is what makes a build that silently produced nothing fail here
// rather than yield an empty inventory.
func HarvestScript(srcDir, extension, destDir string) string {
	return fmt.Sprintf(`set -e
files=$(find %s -name '*.%s' ! -name '*debuginfo*' ! -name '*debugsource*')
[ -n "$files" ] || { echo "doca-kernel-support produced no packages under %s" >&2; exit 1; }
cp $files %s/
`, srcDir, extension, srcDir, destDir)
}
