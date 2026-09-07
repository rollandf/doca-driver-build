#!/bin/bash
# Copyright (c) 2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.

# Load environment variables if file exists
if [ -f "$(dirname "$0")/dtk.env" ]; then
    source "$(dirname "$0")/dtk.env"
fi

: ${USE_NEW_ENTRYPOINT:=true}

if [ "$USE_NEW_ENTRYPOINT" = "true" ]; then
    echo "Using Go entrypoint for DTK build"
    exec "$(dirname "$0")/entrypoint" dtk-build
fi

# The bash path below is gone rather than merely unused. It drove install.pl out of a
# source tree copied onto the shared volume; the driver container now stages a source
# archive for doca-kernel-support instead, so there is no install.pl to run and no tree to
# run it in. Failing here is the honest outcome -- the alternative is a confusing
# "no such file" several steps later.
echo "USE_NEW_ENTRYPOINT=${USE_NEW_ENTRYPOINT}: the bash DTK build path no longer exists." >&2
echo "The driver container stages a source archive for doca-kernel-support, not a tree" >&2
echo "for install.pl. Unset USE_NEW_ENTRYPOINT to use the Go entrypoint." >&2
exit 1
