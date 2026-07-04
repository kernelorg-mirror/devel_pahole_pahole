#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test --word_size with unions and nested structs/unions to exercise
# union__find_new_size() and its recursive struct/union resizing.
# Also test --packable --hex for hex format output in print_packable_info.

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT

title_log "Union word_size resize and packable hex."

CC=${CC:-gcc}
if ! command -v ${CC%% *} > /dev/null 2>&1; then
	info_log "skip: $CC not available"
	test_skip
fi

# --word_size resizing only makes sense on LP64 hosts
native_ptr_size=$($CC -dM -E - < /dev/null | awk '/__SIZEOF_POINTER__/{print $3}')
if [ "$native_ptr_size" != "8" ]; then
	info_log "skip: native pointer size is $native_ptr_size, not 8 (need LP64 host)"
	test_skip
fi

src=$(make_tmpsrc)
obj=$(make_tmpobj)

cat > "$src" << 'EOF'
/* Union with pointer and long members — these change size with word_size.
 * On LP64: ptr=8, long=8, union size=8.
 * With --word_size=4: ptr=4, long=4, union size internally=4.
 */
union ptr_or_long {
	void	*ptr;
	long	val;
};

/* Struct containing a union — exercises the recursive path where
 * class__resize_LP encounters a union member and calls
 * union__find_new_size() to compute the resized union size.
 * LP64: int(4) + 4hole + union(8) + long(8) = 24
 * LP32: int(4) + union(4) + long(4) = 12 (no hole, pointers=4)
 */
struct with_union {
	int		flags;
	union ptr_or_long	data;
	long		next;
};

/* Nested union inside struct inside union — tests the mutual recursion
 * between union__find_new_size and class__resize_LP.
 */
struct inner_s {
	long	a;
	void	*b;
};

union nested {
	struct inner_s	s;
	long		raw;
};

struct outer_with_nested {
	int		tag;
	union nested	n;
	void		*link;
};

/* Packable struct for --packable --hex testing.
 * Has holes that make it packable: 16 bytes -> 12 bytes.
 */
struct packable_hex {
	int	a;
	char	b;
	int	c;
	char	d;
};

union ptr_or_long g1;
struct with_union g2;
struct outer_with_nested g3;
struct packable_hex g4;
EOF

$CC -g -c -o "$obj" "$src" 2>/dev/null
if [ $? -ne 0 ]; then
	error_log "FAIL: compilation failed"
	test_fail
fi

# Helper to extract size from --sizes output for a given type
get_size() {
	echo "$1" | awk -v name="$2" '$1 == name {print $2}'
}

# --- --sizes shows resize effect on struct containing union ---
# Note: class__resize_LP adjusts struct size and member offsets but does
# not update individual member byte_size fields, so the struct reports 16
# (not the ideal 12) because union/long members still show size 8.
sizes_64=$(pahole --sizes "$obj" 2>/dev/null)
sizes_32=$(pahole --sizes --word_size=4 "$obj" 2>/dev/null)

sz_wu_64=$(get_size "$sizes_64" "with_union")
sz_wu_32=$(get_size "$sizes_32" "with_union")
if [ "$sz_wu_64" = "24" ] && [ "$sz_wu_32" = "16" ]; then
	info_log "   with_union --word_size=4: 24 -> 16 bytes: ok"
else
	error_log "FAIL: with_union resize unexpected (64=$sz_wu_64, 32=$sz_wu_32)"
	test_fail
fi

# --- Nested union/struct mutual recursion via --sizes ---
sz_owu_64=$(get_size "$sizes_64" "outer_with_nested")
sz_owu_32=$(get_size "$sizes_32" "outer_with_nested")
if [ -n "$sz_owu_64" ] && [ -n "$sz_owu_32" ]; then
	if [ "$sz_owu_32" -lt "$sz_owu_64" ]; then
		info_log "   outer_with_nested --word_size=4: $sz_owu_64 -> $sz_owu_32 bytes: ok"
	else
		error_log "FAIL: outer_with_nested did not shrink ($sz_owu_64 -> $sz_owu_32)"
		test_fail
	fi
else
	error_log "FAIL: could not get outer_with_nested sizes"
	test_fail
fi

# --- Verify struct layout changes (hole removal) ---
# LP64: with_union has a 4-byte hole between flags and data
output_64=$(pahole -C with_union "$obj" 2>/dev/null)
if ! echo "$output_64" | grep -q "hole"; then
	error_log "FAIL: LP64 with_union should have a hole"
	test_fail
fi
# LP32: hole should disappear (union shrinks to 4, fits right after int)
output_32=$(pahole --word_size=4 -C with_union "$obj" 2>/dev/null)
if echo "$output_32" | grep -q "XXX.*hole"; then
	error_log "FAIL: LP32 with_union still has hole"
	test_fail
fi
info_log "   with_union hole removal on LP32: ok"

# --- --packable with --hex: sizes in hex format ---
output=$(pahole --packable --hex "$obj" 2>/dev/null)
if [ -z "$output" ]; then
	error_log "FAIL: --packable --hex produced no output"
	test_fail
fi
if ! echo "$output" | grep -q "packable_hex"; then
	error_log "FAIL: --packable --hex did not list packable_hex"
	test_fail
fi
# Hex output has 0x prefix (0x10 for 16, 0xc for 12, 0x4 for savings)
if ! echo "$output" | grep "packable_hex" | grep -q "0x"; then
	error_log "FAIL: --packable --hex output not in hex format"
	error_log "Got: $(echo "$output" | grep packable_hex)"
	test_fail
fi
info_log "   --packable --hex: ok"

# --- --sizes with --hex: struct sizes in hex ---
output=$(pahole --sizes --hex "$obj" 2>/dev/null)
if [ -z "$output" ]; then
	error_log "FAIL: --sizes --hex produced no output"
	test_fail
fi
if ! echo "$output" | grep "ptr_or_long" | grep -q "0x"; then
	error_log "FAIL: --sizes --hex output not in hex format"
	test_fail
fi
info_log "   --sizes --hex: ok"

test_pass
