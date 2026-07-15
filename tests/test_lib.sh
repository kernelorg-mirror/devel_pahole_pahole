#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (c) 2026, Oracle and/or its affiliates.
#
# Common helper functions for the testsuite.
#

# if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
# 	echo "This script is meant to be sourced. Please use 'source test_lib.sh'."
# 	exit 1
# fi

# Auto-detect and use just-built binaries from build/ directory.
# When running tests after 'make -C build', automatically use those binaries
# instead of distro-installed or ~/bin versions, with no PATH setup required.
tests_root=$(cd "$(dirname "$0")" && pwd)
build_dir="$tests_root/../build"
if [ -d "$build_dir" ] && [ -x "$build_dir/pahole" ]; then
	export PATH="$build_dir:$PATH"
	export LD_LIBRARY_PATH="$build_dir:${LD_LIBRARY_PATH}"
fi

check_color_support()
{
	if [ ! -z "$color_support" ] ; then
		return $color_support
	else
		if tput colors >/dev/null 2>&1; then
			num_colors=$(tput colors)
			if [ $num_colors -gt 0 ] && [ -n "$BASH_VERSION" ] ; then
				RED='\033[0;31m'
				GREEN='\033[0;32m'
				YELLOW='\033[0;33m'
				NC='\033[0m'
				color_support=1
			else
				RED=''
				GREEN=''
				YELLOW=''
				NC=''
				color_support=0
			fi
		else
			RED=''
			GREEN=''
			YELLOW=''
			NC=''
			color_support=0
		fi
	fi
	return $color_support
}

color_print()
{
	if [ $color_support -eq 1 ] ; then
		echo -e "$1$2${NC}"
	else
		echo $1
	fi
}

get_vmlinux()
{

	vmlinux=${vmlinux:-$1}

	if [ -z "$vmlinux" ] ; then
		vmlinux=$(pahole --running_kernel_vmlinux)
		if [ -z "$vmlinux" ] ; then
			check_color_support
			color_print ${RED} "Please specify a vmlinux file to operate on"
			exit 2
		fi
	fi

	if [ ! -f "$vmlinux" ] ; then
		echo ${RED} "$vmlinux file not available, please specify another"
		exit 2
	fi

	echo $vmlinux
	return 0
}

# Get perf binary with debug info, building from source if needed.
# Uses a shared cache directory for all tests in the run to avoid rebuilding.
# Returns: path to perf binary, or exits with skip if unavailable
get_perf_with_debug()
{
	# Check if system perf has usable DWARF debug info
	# Alpine Linux packages perf without debuginfo, so we can't rely on "not stripped"
	# check alone - verify actual DWARF type info is present using pahole.
	system_perf="$(command -v perf 2>/dev/null)"
	if [ -n "$system_perf" ]; then
		# First quick check: is it stripped? If yes, skip pahole verification
		if file "$system_perf" | grep -q "not stripped"; then
			# Binary has symbols, now verify DWARF debug info is actually present.
			# Check that pahole can extract type information from the binary.
			if pahole --features=force_cu_merging -F dwarf -C perf_event_header "$system_perf" 2>/dev/null | grep -q "^struct perf_event_header {"; then
				echo "$system_perf"
				return 0
			fi
			# Binary not stripped but lacks DWARF - Alpine case
		fi
		# Stripped or lacks DWARF, need to build from source
	fi

	# Build from source if needed - use shared cache across all tests
	perf_cache="${PERF_CACHE_DIR:-/tmp/pahole-test-perf-cache}"
	perf_bin="$perf_cache/tools/perf/perf"
	perf_complete="$perf_cache/.build-complete"

	# If build is complete and binary exists, use it
	if [ -f "$perf_complete" ] && [ -x "$perf_bin" ]; then
		echo "$perf_bin"
		return 0
	fi

	# Need to build perf - use atomic directory creation as lock to prevent parallel builds
	# (88 tests run concurrently, only one should build)
	# Download perf-specific tarball (much smaller than full kernel tree)
	# See https://www.kernel.org/pub/linux/kernel/tools/perf/HOWTO.build.perf
	lockdir="$perf_cache.lock"

	# Try to acquire lock by creating directory (atomic operation)
	max_wait=300  # seconds
	waited=0
	got_lock=0

	while [ $waited -lt $max_wait ]; do
		if mkdir "$lockdir" 2>/dev/null; then
			got_lock=1
			break
		fi

		# Another test is building, check if it's done
		if [ -f "$perf_complete" ] && [ -x "$perf_bin" ]; then
			echo "$perf_bin"
			return 0
		fi

		# Wait a bit and retry
		sleep 1
		waited=$((waited + 1))
	done

	if [ $got_lock -eq 0 ]; then
		info_log "skip: timeout waiting for perf build to complete" >&2
		test_skip
	fi

	# Got lock, check again (another test may have finished while we waited)
	if [ -f "$perf_complete" ] && [ -x "$perf_bin" ]; then
		rmdir "$lockdir"
		echo "$perf_bin"
		return 0
	fi

	# Clean up any incomplete build from previous failed attempt
	if [ -d "$perf_cache" ]; then
		rm -rf "$perf_cache"
	fi

	# Build perf from source
	if [ ! -d "$perf_cache" ]; then
		mkdir -p "$perf_cache"

		# Priority: PERF_SRC_DIR env var > /tmp/perf_src_dir > download from kernel.org
		# PERF_SRC_DIR allows using a pre-downloaded kernel source tree to avoid
		# hitting kernel.org mirrors (which fight against automatic downloaders)
		# /tmp/perf_src_dir is the standard location for containers (bind-mount source there)
		perf_src_dir=""

		if [ -n "$PERF_SRC_DIR" ]; then
			# Use user-provided source directory
			perf_src_dir="$PERF_SRC_DIR"
			info_log "Building perf from PERF_SRC_DIR=$perf_src_dir..." >&2
		elif [ -d "/tmp/perf_src_dir/tools/perf" ]; then
			# Fall back to /tmp/perf_src_dir if available (container-friendly)
			perf_src_dir="/tmp/perf_src_dir"
			info_log "Building perf from $perf_src_dir..." >&2
		fi

		if [ -n "$perf_src_dir" ]; then
			# Build from local source directory using O= for out-of-tree build
			# This avoids copying sources and puts build artifacts in cache directory

			# Verify it's a valid kernel/perf source tree
			if [ ! -d "$perf_src_dir/tools/perf" ]; then
				info_log "skip: $perf_src_dir does not contain tools/perf directory" >&2
				info_log "Source directory should point to kernel root (contains tools/perf/)" >&2
				rm -rf "$perf_cache"
				rmdir "$lockdir"
				test_skip
			fi

			# Build perf with debug info using O= for out-of-tree build
			# DEBUG=1 enables -g, EXTRA_CFLAGS adds explicit debug flags for paranoia
			if ! make -C "$perf_src_dir/tools/perf" O="$perf_cache/perf-build" \
				DEBUG=1 WERROR=0 EXTRA_CFLAGS="-g -ggdb3" \
				> "$perf_cache/build.log" 2>&1; then
				info_log "skip: failed to build perf from $perf_src_dir" >&2
				rm -rf "$perf_cache"
				rmdir "$lockdir"
				test_skip
			fi

			perf_build_dir="$perf_cache/perf-build"
		else
			# No local source, download from kernel.org as last resort
			info_log "Downloading and building perf with debug info (one-time setup)..." >&2
			info_log "Tip: set PERF_SRC_DIR or place kernel at /tmp/perf_src_dir to avoid downloads" >&2

			perf_version="6.19.0"
			perf_tarball="perf-${perf_version}.tar.xz"
			perf_url="https://mirrors.edge.kernel.org/pub/linux/kernel/tools/perf/v${perf_version}/${perf_tarball}"

			# Download perf tarball (~3MB vs ~200MB+ for full kernel)
			# Try wget first, fall back to curl
			download_ok=0
			if command -v wget > /dev/null 2>&1; then
				if wget -q -O "$perf_cache/$perf_tarball" "$perf_url" 2>"$perf_cache/download.log"; then
					download_ok=1
				fi
			elif command -v curl > /dev/null 2>&1; then
				if curl -sL -o "$perf_cache/$perf_tarball" "$perf_url" 2>"$perf_cache/download.log"; then
					download_ok=1
				fi
			else
				info_log "skip: neither wget nor curl available to download perf" >&2
				info_log "Set PERF_SRC_DIR to build from local kernel source instead" >&2
				rm -rf "$perf_cache"
				rmdir "$lockdir"
				test_skip
			fi

			if [ $download_ok -eq 0 ]; then
				info_log "skip: failed to download perf tarball from $perf_url" >&2
				info_log "Set PERF_SRC_DIR to build from local kernel source instead" >&2
				rm -rf "$perf_cache"
				rmdir "$lockdir"
				test_skip
			fi

			# Extract tarball
			if ! tar -xf "$perf_cache/$perf_tarball" -C "$perf_cache" 2>"$perf_cache/extract.log"; then
				info_log "skip: failed to extract perf tarball" >&2
				rm -rf "$perf_cache"
				rmdir "$lockdir"
				test_skip
			fi

			# Move extracted directory to expected location
			if ! mv "$perf_cache/perf-${perf_version}" "$perf_cache/perf-src" 2>"$perf_cache/mv.log"; then
				info_log "skip: failed to move extracted perf directory" >&2
				rm -rf "$perf_cache"
				rmdir "$lockdir"
				test_skip
			fi

			# Build perf with debug info
			# DEBUG=1 enables -g, EXTRA_CFLAGS adds explicit debug flags for paranoia
			if ! make -C "$perf_cache/perf-src/tools/perf" \
				DEBUG=1 WERROR=0 EXTRA_CFLAGS="-g -ggdb3" \
				> "$perf_cache/build.log" 2>&1; then
				info_log "skip: failed to build perf from source" >&2
				rm -rf "$perf_cache"
				rmdir "$lockdir"
				test_skip
			fi

			perf_build_dir="$perf_cache/perf-src/tools/perf"
		fi  # end if [ -n "$perf_src_dir" ]

		# Find the actual ELF binary (perf creates a script wrapper, real binary elsewhere)
		# Look for 'perf' ELF file in the build output directory
		built_perf=$(find "$perf_build_dir" -type f -name 'perf' -executable \
			-exec file {} \; 2>/dev/null | grep 'ELF.*executable' | head -1 | cut -d: -f1)

		if [ -z "$built_perf" ] || [ ! -f "$built_perf" ]; then
			info_log "skip: could not find built perf ELF binary" >&2
			find "$perf_cache/perf-src/tools/perf" -name 'perf' > "$perf_cache/find.log" 2>&1
			rm -rf "$perf_cache"
			rmdir "$lockdir"
			test_skip
		fi

		# Verify binary has usable debug info before moving
		# Check that pahole can actually extract type information, not just that
		# the binary has some debug sections (file "not stripped" is insufficient)
		if ! pahole --features=force_cu_merging -F dwarf -C perf_event_header "$built_perf" 2>/dev/null | grep -q "^struct perf_event_header {"; then
			info_log "skip: built perf binary lacks DWARF type info (DEBUG=1 build failed)" >&2
			rm -rf "$perf_cache"
			rmdir "$lockdir"
			test_skip
		fi

		# Move built binary to expected location
		mkdir -p "$perf_cache/tools/perf"
		if ! mv "$built_perf" "$perf_bin" 2>"$perf_cache/mv-bin.log"; then
			info_log "skip: failed to move perf binary" >&2
			rm -rf "$perf_cache"
			rmdir "$lockdir"
			test_skip
		fi

		# Ensure filesystem has flushed the moved file before marking complete
		sync

		# Mark build as complete (atomic operation)
		touch "$perf_complete"

		info_log "Built perf from source at $perf_bin" >&2
	fi

	# Release lock
	rmdir "$lockdir" 2>/dev/null

	if [ -f "$perf_complete" ] && [ -x "$perf_bin" ]; then
		echo "$perf_bin"
		return 0
	else
		info_log "skip: perf not available"
		test_skip
	fi
}

make_tmpdir()
{
	outdir=$(mktemp -d /tmp/$(basename "$0").XXXXXX)
	echo $outdir
	return 0
}

make_tmpobj()
{
	outobj=$(mktemp "$outdir/$(basename "$0").obj.XXXXXX.o")
	echo $outobj
	return 0
}

make_tmpsrc()
{
	outsrc=$(mktemp "$outdir/$(basename "$0").src.XXXXXX.c")
	echo $outsrc
	return 0
}

make_tmpfile()
{
	outfile=$(mktemp "$outdir/$(basename "$0").data.XXXXXX")
	echo $outfile
	return 0
}

info_log()
{
	printf "   "
	echo $1
}

title_log()
{
	check_color_support
	color_print ${YELLOW} "$1"
}

verbose_log()
{
	if [[ -n "$VERBOSE" ]]; then
		printf "   "
		echo $1
	fi
}

error_log()
{
	printf "   "
	check_color_support
	color_print $RED "${1}"
}

test_softfail()
{
	if [ -z "$softfail_count" ] ; then
		softfail_count=1
	else
		softfail_count=$((softfail_count + 1))
	fi
}

test_fail()
{
	trap - EXIT
	check_color_support
	color_print ${RED} "Test $0 failed"
	if [ -d "$outdir" ]; then
		color_print ${RED} "Test data is in $outdir"
	fi
	exit 1
}

check_softfail()
{
	if [ ! -z "$softfail_count" ] ; then
		check_color_support
		color_print ${RED} "Soft failures: $softfail_count"
		return 1
	else
		return 0
	fi
}

test_pass()
{
	check_color_support
	color_print ${GREEN} "Test $0 passed"
	exit 0
}

test_skip()
{
	check_color_support
	color_print ${YELLOW} "Skipping test ..."
	exit 2
}

cleanup()
{
	if [ -n "$outdir" ] && [ -d "$outdir" ]; then
		rm -f ${outdir}/*
		rmdir $outdir
	fi
	return 0
}
