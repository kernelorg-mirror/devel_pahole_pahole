#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test --word_size LP64/LP32 resizing (pahole.c coverage).

. "$(dirname "$0")/test_lib.sh"
outdir=$(make_tmpdir)

trap cleanup EXIT

title_log "Word size LP resizing."

CC=${CC:-gcc}
if ! command -v "${CC%% *}" > /dev/null 2>&1; then
	info_log "skip: $CC not available"
	test_skip
fi

src=$(make_tmpsrc)
obj=$(make_tmpobj)

cat > "$src" << 'EOF'
struct with_ptrs {
	void		*data;
	long		count;
	int		flags;
	char		*name;
};

struct with_ptrs g1;
EOF

if ! $CC -g -c -o "$obj" "$src" 2>/dev/null; then
	error_log "FAIL: compilation failed"
	test_fail
fi

# --word_size resizing only makes sense on LP64 hosts
native_ptr_size=$($CC -dM -E - < /dev/null | awk '/__SIZEOF_POINTER__/{print $3}')
if [ "$native_ptr_size" != "8" ]; then
	info_log "skip: native pointer size is $native_ptr_size, not 8 (need LP64 host)"
	test_skip
fi

# Extract "size: NNN" from the comment line for a given struct.
# --word_size works without -C (it iterates all CU types).
get_struct_size() {
	sed -n "/^struct $1 {/,/^};/p" | grep '/\* size:' | sed 's|.*/\* size: \([0-9]*\).*|\1|'
}

# Default (LP64): pointers and longs are 8 bytes
output_64=$(pahole "$obj" 2>/dev/null)
size_64=$(echo "$output_64" | get_struct_size with_ptrs)
if [ -z "$size_64" ]; then
	error_log "FAIL: could not get LP64 size"
	test_fail
fi
info_log "   LP64 with_ptrs size: $size_64"

# --word_size=4 (LP32): pointers and longs shrink to 4 bytes
output_32=$(pahole --word_size=4 "$obj" 2>/dev/null)
size_32=$(echo "$output_32" | get_struct_size with_ptrs)
if [ -z "$size_32" ]; then
	error_log "FAIL: --word_size=4 produced no size"
	test_fail
fi
info_log "   LP32 with_ptrs size: $size_32"

# LP32 struct should be smaller than LP64
if [ "$size_32" -ge "$size_64" ]; then
	error_log "FAIL: LP32 size ($size_32) not smaller than LP64 ($size_64)"
	test_fail
fi
info_log "   --word_size=4: ok"

# --word_size=8 should match default LP64
output_w8=$(pahole --word_size=8 "$obj" 2>/dev/null)
size_w8=$(echo "$output_w8" | get_struct_size with_ptrs)
if [ "$size_w8" != "$size_64" ]; then
	error_log "FAIL: --word_size=8 size ($size_w8) != default ($size_64)"
	test_fail
fi
info_log "   --word_size=8: ok"

# --word_size=4 must also work with -C (class name filter)
size_c32=$(pahole --word_size=4 -C with_ptrs "$obj" 2>/dev/null | get_struct_size with_ptrs)
if [ -z "$size_c32" ]; then
	error_log "FAIL: --word_size=4 -C produced no size"
	test_fail
fi
if [ "$size_c32" -ge "$size_64" ]; then
	error_log "FAIL: --word_size=4 -C size ($size_c32) not smaller than LP64 ($size_64)"
	test_fail
fi
info_log "   --word_size=4 -C: ok"

# --sizes with --word_size=4 should work
sizes_output=$(pahole --sizes --word_size=4 "$obj" 2>/dev/null)
if [ -z "$sizes_output" ]; then
	error_log "FAIL: --sizes --word_size=4 produced no output"
	test_fail
fi
info_log "   --sizes --word_size=4: ok"

test_pass
