#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test uncovered pahole.c output format and filtering paths:
#   --count/--skip with --prettify, --structs, --sizes --hex,
#   --contains --recursive, --first_obj_only

. "$(dirname "$0")/test_lib.sh"
outdir=$(make_tmpdir)

trap cleanup EXIT

title_log "Format coverage: count, skip, structs, hex, contains, first_obj_only."

CC=${CC:-gcc}
if ! command -v "${CC%% *}" > /dev/null 2>&1; then
	info_log "skip: $CC not available"
	test_skip
fi

# ============================================================
# Part 1: --count and --skip with --prettify
# ============================================================

src=$(make_tmpsrc)
obj=$(make_tmpobj)

cat > "$src" << 'EOF'
struct item {
	int id;
	int value;
};

struct item g_item;
EOF

if ! $CC -g -c -o "$obj" "$src" 2>/dev/null; then
	error_log "FAIL: item compilation failed"
	test_fail
fi

# Build a binary file with 3 records (each 8 bytes), little-endian:
#   record 0: id=10, value=100
#   record 1: id=20, value=200
#   record 2: id=30, value=300
binfile="$outdir/items.bin"
printf '\012\000\000\000' > "$binfile"
printf '\144\000\000\000' >> "$binfile"
printf '\024\000\000\000' >> "$binfile"
printf '\310\000\000\000' >> "$binfile"
printf '\036\000\000\000' >> "$binfile"
printf '\054\001\000\000' >> "$binfile"

# --count=2: should print exactly 2 records, not 3
output=$(pahole -C item --count=2 \
	--prettify "$binfile" "$obj" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ]; then
	error_log "FAIL: --count=2 exited $rc"
	test_fail
fi
id_count=$(echo "$output" | grep -c "\.id = ")
if [ "$id_count" -ne 2 ]; then
	error_log "FAIL: --count=2 printed $id_count records, expected 2"
	test_fail
fi
info_log "   --count=2: ok ($id_count records)"

# --skip=1: skip first record, print remaining 2
output=$(pahole -C item --skip=1 \
	--prettify "$binfile" "$obj" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ]; then
	error_log "FAIL: --skip=1 exited $rc"
	test_fail
fi
id_count=$(echo "$output" | grep -c "\.id = ")
if [ "$id_count" -ne 2 ]; then
	error_log "FAIL: --skip=1 printed $id_count records, expected 2"
	test_fail
fi
info_log "   --skip=1: ok ($id_count records)"

# --skip=1 --count=1: skip first, print only 1 of the remaining
output=$(pahole -C item --skip=1 --count=1 \
	--prettify "$binfile" "$obj" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ]; then
	error_log "FAIL: --skip=1 --count=1 exited $rc"
	test_fail
fi
id_count=$(echo "$output" | grep -c "\.id = ")
if [ "$id_count" -ne 1 ]; then
	error_log "FAIL: --skip=1 --count=1 printed $id_count records, expected 1"
	test_fail
fi
info_log "   --skip=1 --count=1: ok"

# ============================================================
# Part 2: --structs (filters to show only struct types)
# ============================================================

src2="$outdir/mixed.c"
obj2="$outdir/mixed.o"

cat > "$src2" << 'EOF'
struct point { int x; int y; };
union variant { int ival; float fval; };

struct point g_pt;
union variant g_var;
EOF

if ! $CC -g -c -o "$obj2" "$src2" 2>/dev/null; then
	error_log "FAIL: mixed compilation failed"
	test_fail
fi

output=$(pahole --structs "$obj2" 2>/dev/null)
if [ -z "$output" ]; then
	error_log "FAIL: --structs produced no output"
	test_fail
fi
if ! echo "$output" | grep -q "struct point"; then
	error_log "FAIL: --structs missing struct point"
	test_fail
fi
# --structs should filter out unions
if echo "$output" | grep -q "union variant"; then
	error_log "FAIL: --structs should not show union variant"
	test_fail
fi
info_log "   --structs: ok"

# ============================================================
# Part 3: --sizes --hex
# ============================================================

output=$(pahole --sizes --hex "$obj2" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ]; then
	error_log "FAIL: --sizes --hex exited $rc"
	test_fail
fi
if [ -z "$output" ]; then
	error_log "FAIL: --sizes --hex produced no output"
	test_fail
fi
# Hex output should contain "0x" for the size column
if ! echo "$output" | grep -q "0x"; then
	error_log "FAIL: --sizes --hex missing hex values"
	test_fail
fi
info_log "   --sizes --hex: ok"

# ============================================================
# Part 4: --contains with --recursive (-i -d)
# ============================================================

src3="$outdir/nested.c"
obj3="$outdir/nested.o"

cat > "$src3" << 'EOF'
struct base { int id; };
struct middle { struct base b; int flags; };
struct outer { struct middle m; char name[8]; };
struct unrelated { long x; };

struct outer g_outer;
struct unrelated g_unrel;
EOF

if ! $CC -g -c -o "$obj3" "$src3" 2>/dev/null; then
	error_log "FAIL: nested compilation failed"
	test_fail
fi

# -i base: find types directly containing struct base
output=$(pahole -i base "$obj3" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ]; then
	error_log "FAIL: -i base exited $rc"
	test_fail
fi
if [ -z "$output" ]; then
	error_log "FAIL: -i base produced no output"
	test_fail
fi
if ! echo "$output" | grep -q "middle"; then
	error_log "FAIL: -i base missing middle"
	test_fail
fi
info_log "   -i base (--contains): ok"

# -i base -d: recursive containment — exercises the -d code path.
# The recursive flag enables searching inside nested structs; the output
# still lists direct containers ("middle"), not transitive ones.
output=$(pahole -i base -d "$obj3" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ]; then
	error_log "FAIL: -i base -d exited $rc"
	test_fail
fi
if [ -z "$output" ]; then
	error_log "FAIL: -i base -d produced no output"
	test_fail
fi
if echo "$output" | grep -q "unrelated"; then
	error_log "FAIL: -i base -d should not list unrelated"
	test_fail
fi
info_log "   -i base -d (--recursive): ok"

# ============================================================
# Part 5: --first_obj_only with multi-CU linked object
# ============================================================

# LD may contain flags (e.g. "ld -m elf_x86_64"), strip them for the
# availability check, same as the CC check above uses ${CC%% *}.
LD=${LD:-ld}
if command -v "${LD%% *}" > /dev/null 2>&1; then
	cat > "$outdir/cu_a.c" << 'EOF'
struct alpha { int a1; };
struct alpha g_alpha;
EOF
	cat > "$outdir/cu_b.c" << 'EOF'
struct beta { int b1; };
struct beta g_beta;
EOF

	$CC -g -c -o "$outdir/cu_a.o" "$outdir/cu_a.c" 2>/dev/null
	$CC -g -c -o "$outdir/cu_b.o" "$outdir/cu_b.c" 2>/dev/null
	if $LD -r -o "$outdir/multi.o" "$outdir/cu_a.o" "$outdir/cu_b.o" 2>/dev/null; then
		all_output=$(pahole "$outdir/multi.o" 2>/dev/null)
		first_output=$(pahole --first_obj_only "$outdir/multi.o" 2>/dev/null)

		if [ -z "$first_output" ]; then
			error_log "FAIL: --first_obj_only produced no output"
			test_fail
		fi

		# --first_obj_only must produce strictly less output than the
		# full scan (two CUs have different structs, so filtering to
		# the first CU must drop at least one struct)
		all_lines=$(echo "$all_output" | wc -l)
		first_lines=$(echo "$first_output" | wc -l)
		if [ "$first_lines" -ge "$all_lines" ]; then
			error_log "FAIL: --first_obj_only did not filter ($first_lines >= $all_lines lines)"
			test_fail
		fi
		info_log "   --first_obj_only: ok ($first_lines vs $all_lines lines)"
	else
		info_log "   skip: ld -r failed"
	fi
else
	info_log "   skip: ld not available"
fi

test_pass
