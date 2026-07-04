#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test --sort with multi-CU input to exercise the resort_classes()
# deduplication path and type__compare_members_types().

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT

title_log "Sort with multi-CU deduplication."

CC=${CC:-gcc}
if ! command -v ${CC%% *} > /dev/null 2>&1; then
	info_log "skip: $CC not available"
	test_skip
fi

LD=${LD:-ld}

# Two CUs that both define "struct shared" with identical layout.
# resort_classes() re-inserts into a new rbtree using
# type__compare_members_types() to detect duplicates across CUs.
src_a="$outdir/a.c"
src_b="$outdir/b.c"
obj_a="$outdir/a.o"
obj_b="$outdir/b.o"
obj="$outdir/combined.o"

cat > "$src_a" << 'EOF'
struct shared {
	int	x;
	int	y;
};

struct only_in_a {
	char	c;
};

struct shared ga;
struct only_in_a ga2;
EOF

cat > "$src_b" << 'EOF'
struct shared {
	int	x;
	int	y;
};

struct only_in_b {
	long	l;
};

struct shared gb;
struct only_in_b gb2;
EOF

if ! $CC -g -c -o "$obj_a" "$src_a" 2>"$outdir/cc.log"; then
	info_log "$(cat "$outdir/cc.log")"
	error_log "FAIL: compilation of a.c failed"
	test_fail
fi
if ! $CC -g -c -o "$obj_b" "$src_b" 2>"$outdir/cc.log"; then
	info_log "$(cat "$outdir/cc.log")"
	error_log "FAIL: compilation of b.c failed"
	test_fail
fi

# Link into a single multi-CU object
if command -v ${LD%% *} > /dev/null 2>&1; then
	if ! $LD -r -o "$obj" "$obj_a" "$obj_b" 2>"$outdir/ld.log"; then
		info_log "$(cat "$outdir/ld.log")"
		error_log "FAIL: ld -r failed"
		test_fail
	fi
else
	if ! $CC -r -nostdlib -o "$obj" "$obj_a" "$obj_b" 2>"$outdir/cc.log"; then
		info_log "$(cat "$outdir/cc.log")"
		error_log "FAIL: $CC -r failed"
		test_fail
	fi
fi

# Without --sort, DWARF order: shared, only_in_a, only_in_b
unsorted=$(pahole "$obj" 2>/dev/null)
first_unsorted=$(echo "$unsorted" | grep "^struct " | head -1)
if ! echo "$first_unsorted" | grep -q "shared"; then
	# DWARF order may vary; just record what we got
	info_log "   unsorted first struct: $first_unsorted"
fi

# Verify dedup happened even without --sort (structures__add dedup)
shared_count=$(echo "$unsorted" | grep -c "^struct shared {")
if [ "$shared_count" -ne 1 ]; then
	error_log "FAIL: baseline dedup broken, got $shared_count copies of struct shared"
	test_fail
fi
info_log "   baseline dedup: ok (1 copy of struct shared from 2 CUs)"

# With --sort, resort_classes() re-inserts into a new rbtree using
# type__compare_members_types() to compare member names, offsets,
# bitfield sizes, and types — this is the code path we want to cover.
sorted=$(pahole --sort "$obj" 2>/dev/null)
first_sorted=$(echo "$sorted" | grep "^struct " | head -1)
if ! echo "$first_sorted" | grep -q "only_in_a"; then
	error_log "FAIL: --sort did not sort alphabetically (first: $first_sorted)"
	test_fail
fi
info_log "   --sort order: ok (first: only_in_a)"

# Verify --sort still deduplicates shared across CUs
sorted_shared=$(echo "$sorted" | grep -c "^struct shared {")
if [ "$sorted_shared" -ne 1 ]; then
	error_log "FAIL: --sort dedup broken, got $sorted_shared copies of struct shared"
	test_fail
fi
info_log "   --sort dedup: ok (1 copy of struct shared)"

# Verify all three unique structs appear in sorted output
for name in only_in_a only_in_b shared; do
	if ! echo "$sorted" | grep -q "^struct $name {"; then
		error_log "FAIL: --sort output missing struct $name"
		test_fail
	fi
done
info_log "   --sort completeness: ok (all 3 structs present)"

# --sort --count: verify count limit works with sorted output
count_output=$(pahole --sort --count 2 "$obj" 2>/dev/null)
count_structs=$(echo "$count_output" | grep -c "^struct ")
if [ "$count_structs" -ne 2 ]; then
	error_log "FAIL: --sort --count 2 showed $count_structs structs (expected 2)"
	test_fail
fi
info_log "   --sort --count 2: ok ($count_structs structs)"

# --sort --skip: verify --skip works with sorted output
skip_output=$(pahole --sort --skip 1 "$obj" 2>/dev/null)
first_skip=$(echo "$skip_output" | grep "^struct " | head -1)
# Sorted order is only_in_a, only_in_b, shared; skipping 1 gives only_in_b first
if ! echo "$first_skip" | grep -q "only_in_b"; then
	error_log "FAIL: --sort --skip 1 first struct not only_in_b (got: $first_skip)"
	test_fail
fi
info_log "   --sort --skip 1: ok (first: only_in_b)"

test_pass
