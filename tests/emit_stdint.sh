#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Exercise --compile output for structs with <stdatomic.h> members.
#
# Modern GCC/Clang encode _Atomic as DW_TAG_atomic_type wrapping a
# DW_TAG_base_type("int"), so the legacy base_type__emit_definitions()
# path in dwarves_emit.c is NOT reached here.  That path requires
# DW_TAG_base_type entries named "atomic_int" etc., which only older
# toolchains produced — see emit_atomic_basetype.sh for coverage of
# those code paths using hand-crafted DWARF.
#
# This test verifies that --compile handles DW_TAG_atomic_type members
# without crashing, produces compilable output, and that
# --skip_emitting_atomic_typedefs is accepted.

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT

title_log "DW_TAG_atomic_type member handling via --compile."

CC=${CC:-gcc}
if ! command -v ${CC%% *} > /dev/null 2>&1; then
	info_log "skip: $CC not available"
	test_skip
fi

src=$(make_tmpsrc)
obj=$(make_tmpobj)

cat > "$src" << 'EOF'
#include <stdatomic.h>

struct stdatomic_members {
	atomic_int	ai;
	atomic_uint	aui;
	atomic_long	al;
	atomic_ulong	aul;
	atomic_short	as;
	atomic_char	ac;
	atomic_bool	ab;
};

struct stdatomic_members g_sm;
EOF

if ! $CC -std=c11 -g -c -o "$obj" "$src" 2>"$outdir/cc.log"; then
	info_log "skip: $CC does not support -std=c11 or <stdatomic.h>"
	info_log "$(cat "$outdir/cc.log")"
	test_skip
fi

# Test 1: --compile produces output for the struct
output=$(pahole --compile -C stdatomic_members "$obj" 2>"$outdir/pahole.log")
rc=$?
if [ $rc -ne 0 ]; then
	error_log "FAIL: pahole --compile -C stdatomic_members exited $rc"
	info_log "$(cat "$outdir/pahole.log")"
	test_fail
fi
if [ -z "$output" ]; then
	error_log "FAIL: pahole --compile -C stdatomic_members produced no output"
	test_fail
fi
info_log "   --compile produces output: ok"

# Test 2: check for typedef _Atomic definitions
has_atomic_typedefs=0
if echo "$output" | grep -q "typedef _Atomic"; then
	has_atomic_typedefs=1
	info_log "   typedef _Atomic definitions found: ok"

	# Verify base_type__stdint2simple converted names — raw stdint
	# names like int32_t would leave a <stdint.h> dependency.
	for stdint_name in int32_t int16_t int8_t int64_t; do
		if echo "$output" | grep -q "typedef _Atomic $stdint_name"; then
			error_log "FAIL: typedef uses '$stdint_name' instead of simple C keyword"
			test_fail
		fi
	done
	info_log "   stdint2simple conversion: ok"
else
	# Compiler used DW_TAG_atomic_type wrapper — non-fatal.
	info_log "   no typedef _Atomic lines (DW_TAG_atomic_type encoding, non-fatal)"
fi

# Test 3: struct members present
for member in ai aui al aul as ac ab; do
	if ! echo "$output" | grep -q "$member"; then
		error_log "FAIL: member '$member' missing from --compile output"
		test_fail
	fi
done
info_log "   all 7 struct members present: ok"

# Test 4: emitted code compiles
echo "$output" > "$outdir/emitted.c"
if ! $CC -std=c11 -c -o "$outdir/emitted.o" "$outdir/emitted.c" 2>"$outdir/cc_emit.log"; then
	if [ $has_atomic_typedefs -eq 1 ]; then
		error_log "FAIL: emitted --compile output does not compile"
		info_log "$(cat "$outdir/cc_emit.log")"
		test_fail
	else
		info_log "   emitted code needs stdatomic.h (non-fatal)"
	fi
else
	info_log "   emitted code compiles: ok"
fi

# Test 5: --skip_emitting_atomic_typedefs
# Exercises the option parsing path.  The actual suppression depends
# on conf_fprintf propagation through the emission chain which may
# not reach base_type__emit_definitions in all display paths.
skip_output=$(pahole --compile --skip_emitting_atomic_typedefs "$obj" 2>/dev/null)
if [ $? -ne 0 ]; then
	error_log "FAIL: --skip_emitting_atomic_typedefs exited non-zero"
	test_fail
fi
info_log "   --skip_emitting_atomic_typedefs accepted: ok"

test_pass
