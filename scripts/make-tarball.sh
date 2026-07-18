#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Generate release tarball with version derived from latest git tag.
# Similar to Linux kernel's perf-tar-src-pkg targets.
# Includes a HEAD file with the git SHA for build containers.
#
# Usage: make-tarball.sh {xz|gz|bz2|tar}

set -e

if [ $# -ne 1 ]; then
	echo "Usage: $0 {xz|gz|bz2|tar}" >&2
	exit 1
fi

compression="$1"

# Validate compression type
case "$compression" in
	xz|gz|bz2|tar)
		;;
	*)
		echo "Error: unknown compression type '$compression'" >&2
		echo "Valid types: xz, gz, bz2, tar" >&2
		exit 1
		;;
esac

# Calculate version: next minor version after latest tag
# e.g., if latest tag is v1.31, version becomes 1.32
latest_tag=$(git tag | grep -E '^v[0-9]+\.[0-9]+$' | sort -V | tail -1)
if [ -z "$latest_tag" ]; then
	echo "Error: no version tags found (expected format: v1.31)" >&2
	exit 1
fi

major=$(echo "$latest_tag" | cut -d. -f1 | sed 's/v//')
minor=$(echo "$latest_tag" | cut -d. -f2)
next_minor=$((minor + 1))
version="${major}.${next_minor}"

# Set up tarball output (current directory by default, like kernel)
tarball_dir="${TARBALL_DIR:-.}"
if [ "$tarball_dir" != "." ]; then
	mkdir -p "$tarball_dir"
fi

case "$compression" in
	xz)
		tarball="${tarball_dir}/dwarves-${version}.tar.xz"
		tar_opts="cvfJ"
		;;
	gz)
		tarball="${tarball_dir}/dwarves-${version}.tar.gz"
		tar_opts="cvfz"
		;;
	bz2)
		tarball="${tarball_dir}/dwarves-${version}.tar.bz2"
		tar_opts="cvfj"
		;;
	tar)
		tarball="${tarball_dir}/dwarves-${version}.tar"
		tar_opts="cvf"
		;;
esac

# Create temporary HEAD file with current git SHA
# This lets build containers know exactly what source they're building
git rev-parse HEAD > HEAD

# Get list of files from MANIFEST, prepending "../pahole/" to each
# (assumes script is run from source root, MANIFEST lists relative paths)
manifest_files=$(sed 's%^%../pahole/%g' MANIFEST)

echo "Creating $tarball from MANIFEST files + HEAD"
echo "Version: ${version} (${latest_tag} + 1 minor)"
echo "HEAD: $(cat HEAD)"
echo ""

# Create tarball with version-prefixed directory structure
# Transform: ../pahole/foo -> dwarves-X.Y/foo
tar $tar_opts "$tarball" \
	--transform "s,^pahole/,dwarves-${version}/," \
	$manifest_files \
	../pahole/HEAD

rm -f HEAD

echo ""
echo "Created: $tarball"
ls -lh "$tarball" | awk '{print "Size:    " $5}'
echo ""
