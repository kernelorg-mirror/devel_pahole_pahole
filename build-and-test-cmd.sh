#!/bin/sh

# Build the tools
./buildcmd.sh || exit 1

# Prepend build directory to PATH so tests use the just-built binaries
# (not installed versions or other build directories like build-coverage/)
export PATH="$(pwd)/build:$PATH"

# Use quick mode for BTF functions test (~30ms instead of 2+ minutes)
# Full vmlinux validation is tested in CI with BTF_FUNCTIONS_QUICK=0
export BTF_FUNCTIONS_QUICK=1

# Run tests
tests/tests
