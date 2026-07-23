#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Test codiff --terse (-t) and --terse --verbose (-tV) output paths.
#
# Covers:
#   print_terse_type_changes() in codiff.c -- terse one-line summary
#   listing which attributes changed (size, nr_members, type, offset).
#
#   print_total_function_diff() in codiff.c -- multi-CU total function
#   diff summary via -f -V.

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT

title_log "codiff --terse (-t) type change reporting."

CC=${CC:-gcc}
if ! command -v "${CC%% *}" > /dev/null 2>&1; then
	info_log "skip: $CC not available"
	test_skip
fi

if ! command -v codiff > /dev/null 2>&1; then
	info_log "skip: codiff not available"
	test_skip
fi

LD=${LD:-ld}
if ! command -v "${LD%% *}" > /dev/null 2>&1; then
	info_log "skip: $LD not available"
	test_skip
fi

# -- Single-CU test: size, nr_members, type changes --
cat > "$outdir/single_v1.c" <<'EOF'
struct item {
	int	id;
	char	tag;
};

int use_item(struct item *i) { return i->id; }
EOF

cat > "$outdir/single_v2.c" <<'EOF'
struct item {
	int	id;
	int	tag;
	long	value;
	short	flags;
};

int use_item(struct item *i) { return i->id + (int)i->value; }
EOF

if ! $CC -g -c -o "$outdir/single_v1.o" "$outdir/single_v1.c" 2>"$outdir/cc.log"; then
	info_log "compilation failed:"
	info_log "$(cat "$outdir/cc.log")"
	test_fail
fi

if ! $CC -g -c -o "$outdir/single_v2.o" "$outdir/single_v2.c" 2>"$outdir/cc.log"; then
	info_log "compilation failed:"
	info_log "$(cat "$outdir/cc.log")"
	test_fail
fi

output=$(codiff -t "$outdir/single_v1.o" "$outdir/single_v2.o" 2>/dev/null)

if [ -z "$output" ]; then
	error_log "FAIL: codiff -t produced no output"
	test_fail
fi

if ! echo "$output" | grep -q "struct item"; then
	error_log "FAIL: codiff -t output missing 'struct item'"
	test_fail
fi

if ! echo "$output" | grep -q "size"; then
	error_log "FAIL: codiff -t output missing 'size' change"
	test_fail
fi

if ! echo "$output" | grep -q "nr_members"; then
	error_log "FAIL: codiff -t output missing 'nr_members' change"
	test_fail
fi

info_log "   codiff -t single-CU (size, nr_members): ok"

# -- Multi-CU test: print_total_function_diff via -f -V --
cat > "$outdir/alpha_v1.c" <<'EOF'
struct widget { int x; int y; };
int widget_area(struct widget *w) { return w->x * w->y; }
EOF

cat > "$outdir/beta_v1.c" <<'EOF'
struct gadget { long serial; short mode; };
int gadget_init(struct gadget *g) { return (int)g->serial; }
EOF

cat > "$outdir/alpha_v2.c" <<'EOF'
struct widget { int x; int y; long weight; };
int widget_area(struct widget *w) { return w->x * w->y + (int)w->weight; }
EOF

cat > "$outdir/beta_v2.c" <<'EOF'
struct gadget { long serial; short mode; int revision; };
int gadget_init(struct gadget *g) { return (int)g->serial + g->revision; }
EOF

if ! $CC -g -c -o "$outdir/alpha_v1.o" "$outdir/alpha_v1.c" 2>"$outdir/cc.log" ||
   ! $CC -g -c -o "$outdir/beta_v1.o"  "$outdir/beta_v1.c"  2>>"$outdir/cc.log" ||
   ! $CC -g -c -o "$outdir/alpha_v2.o" "$outdir/alpha_v2.c" 2>>"$outdir/cc.log" ||
   ! $CC -g -c -o "$outdir/beta_v2.o"  "$outdir/beta_v2.c"  2>>"$outdir/cc.log"; then

	info_log "multi-CU compilation failed:"
	info_log "$(cat "$outdir/cc.log")"
	test_fail
fi

if ! $LD -r -o "$outdir/multi_old.o" "$outdir/alpha_v1.o" "$outdir/beta_v1.o" 2>"$outdir/cc.log" ||
   ! $LD -r -o "$outdir/multi_new.o" "$outdir/alpha_v2.o" "$outdir/beta_v2.o" 2>>"$outdir/cc.log"; then

	info_log "ld -r failed:"
	info_log "$(cat "$outdir/cc.log")"
	test_fail
fi

output=$(codiff -t "$outdir/multi_old.o" "$outdir/multi_new.o" 2>/dev/null)

if [ -z "$output" ]; then
	error_log "FAIL: codiff -t multi-CU produced no output"
	test_fail
fi

if ! echo "$output" | grep -q "struct widget"; then
	error_log "FAIL: codiff -t multi-CU missing 'struct widget'"
	test_fail
fi

if ! echo "$output" | grep -q "struct gadget"; then
	error_log "FAIL: codiff -t multi-CU missing 'struct gadget'"
	test_fail
fi

info_log "   codiff -t multi-CU (widget + gadget): ok"

# -f -V on multi-CU triggers print_total_function_diff()
output=$(codiff -f -V "$outdir/multi_old.o" "$outdir/multi_new.o" 2>/dev/null)

if [ -z "$output" ]; then
	error_log "FAIL: codiff -f -V multi-CU produced no output"
	test_fail
fi

if ! echo "$output" | grep -q "function.*changed"; then
	error_log "FAIL: codiff -f -V missing total function diff summary"
	test_fail
fi

info_log "   codiff -f -V multi-CU (print_total_function_diff): ok"

# -- Offset change test --
cat > "$outdir/holes_v1.c" <<'EOF'
struct record { long a; int b; short c; char d; };
int use_record(struct record *r) { return (int)r->a + r->b; }
EOF

cat > "$outdir/holes_v2.c" <<'EOF'
struct record { char d; long a; int b; short c; };
int use_record(struct record *r) { return (int)r->a + r->b; }
EOF

if ! $CC -g -c -o "$outdir/holes_v1.o" "$outdir/holes_v1.c" 2>"$outdir/cc.log" ||
   ! $CC -g -c -o "$outdir/holes_v2.o" "$outdir/holes_v2.c" 2>>"$outdir/cc.log"; then

	info_log "holes test compilation failed:"
	info_log "$(cat "$outdir/cc.log")"
	test_fail
fi

output=$(codiff -t "$outdir/holes_v1.o" "$outdir/holes_v2.o" 2>/dev/null)

if [ -z "$output" ]; then
	error_log "FAIL: codiff -t holes test produced no output"
	test_fail
fi

if ! echo "$output" | grep -q "offset"; then
	error_log "FAIL: codiff -t holes test missing 'offset' change"
	test_fail
fi

info_log "   codiff -t offset changes: ok"

test_pass
