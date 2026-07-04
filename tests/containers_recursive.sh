#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test --contains with --recursive and --verbose to exercise
# type__print_containers() recursive traversal and verbose count.

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT

title_log "Recursive container search and verbose counts."

CC=${CC:-gcc}
if ! command -v ${CC%% *} > /dev/null 2>&1; then
	info_log "skip: $CC not available"
	test_skip
fi

src=$(make_tmpsrc)
obj=$(make_tmpobj)

# Three-level nesting: leaf inside middle inside outer.
# --contains finds direct containers only: leaf→middle, middle→outer.
cat > "$src" << 'EOF'
struct leaf {
	int	id;
};

struct middle {
	struct leaf	item;
	int		count;
};

struct outer {
	struct middle	m;
	int		flags;
};

/* A struct that does NOT contain leaf */
struct unrelated {
	long	x;
	long	y;
};

struct outer g1;
struct unrelated g2;
EOF

$CC -g -c -o "$obj" "$src" 2>/dev/null
if [ $? -ne 0 ]; then
	error_log "FAIL: compilation failed"
	test_fail
fi

# Basic --contains: should find middle and outer (both contain leaf)
output=$(pahole -i leaf "$obj" 2>/dev/null)
if ! echo "$output" | grep -q "middle"; then
	error_log "FAIL: --contains did not find middle"
	test_fail
fi
# outer contains middle which contains leaf — outer should appear
# if the search considers transitive containment
info_log "   --contains: ok"

# --contains --recursive: should show containment hierarchy
output=$(pahole -i leaf -d "$obj" 2>/dev/null)
if [ -z "$output" ]; then
	error_log "FAIL: --contains --recursive produced no output"
	test_fail
fi
if ! echo "$output" | grep -q "middle"; then
	error_log "FAIL: --contains --recursive missing middle"
	test_fail
fi
info_log "   --contains --recursive: ok"

# Two-level containment: outer contains middle, middle contains leaf
output=$(pahole -i middle "$obj" 2>/dev/null)
if ! echo "$output" | grep -q "outer"; then
	error_log "FAIL: --contains did not find outer containing middle"
	test_fail
fi
info_log "   --contains (middle -> outer): ok"

# --contains --verbose: should show member count after type name
output=$(pahole -i leaf -V "$obj" 2>/dev/null)
if [ -z "$output" ]; then
	error_log "FAIL: --contains --verbose produced no output"
	test_fail
fi
# Verbose mode appends ": N" showing how many members of that type
if ! echo "$output" | grep -q ": "; then
	error_log "FAIL: --contains --verbose missing count annotation"
	test_fail
fi
info_log "   --contains --verbose: ok"

# --contains --recursive --verbose: combined
output=$(pahole -i leaf -d -V "$obj" 2>/dev/null)
if [ -z "$output" ]; then
	error_log "FAIL: --contains -d -V produced no output"
	test_fail
fi
info_log "   --contains --recursive --verbose: ok"

# Verify unrelated is NOT listed
output=$(pahole -i leaf "$obj" 2>/dev/null)
if echo "$output" | grep -q "unrelated"; then
	error_log "FAIL: --contains listed unrelated struct"
	test_fail
fi
info_log "   unrelated struct excluded: ok"

test_pass
