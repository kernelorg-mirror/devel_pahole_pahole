#!/usr/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (c) 2025, Oracle and/or its affiliates.
#

GITHUB_WORKSPACE=${GITHUB_WORKSPACE:-$(pwd)}
VMLINUX=${GITHUB_WORKSPACE}/.kernel/vmlinux
SELFTESTS=${GITHUB_WORKSPACE}/tests
cd $SELFTESTS
export PATH=${GITHUB_WORKSPACE}/install/usr/local/bin:${GITHUB_WORKSPACE}/install/usr/local/sbin:${PATH}
export LLVM_OBJCOPY=objcopy
# Use quick mode for btf_functions.sh (test_bin only, ~30ms vs 2+ minutes)
export BTF_FUNCTIONS_QUICK=1
which pahole
pahole --version
bpftool --version
vmlinux=$VMLINUX ./tests

