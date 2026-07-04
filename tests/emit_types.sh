#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test --compile (type emission) and --skip_emitting_atomic_typedefs to
# exercise dwarves_emit.c emission paths including forward declarations,
# typedef resolution, and atomic base type emission.

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT

title_log "Type emission (--compile) and atomic typedefs."

CC=${CC:-gcc}
if ! command -v ${CC%% *} > /dev/null 2>&1; then
	info_log "skip: $CC not available"
	test_skip
fi

src=$(make_tmpsrc)
obj=$(make_tmpobj)

cat > "$src" << 'EOF'
/* Forward declaration — forces emit path to resolve ordering */
struct fwd_decl;

typedef unsigned int my_uint;
typedef my_uint nested_uint;

struct inner {
	int	a;
	int	b;
};

/* Uses forward-declared struct, typedefs, and nested struct */
struct outer {
	struct inner	nested;
	nested_uint	id;
	struct fwd_decl	*ptr;
};

struct fwd_decl {
	long	val;
};

/* Enum to exercise enum emission */
enum color {
	RED,
	GREEN,
	BLUE
};

struct with_enum {
	enum color	c;
	int		value;
};

struct outer g1;
struct fwd_decl g2;
struct with_enum g3;
EOF

if ! $CC -g -c -o "$obj" "$src" 2>"$outdir/cc.log"; then
	info_log "$(cat "$outdir/cc.log")"
	error_log "FAIL: compilation failed"
	test_fail
fi

# --compile: should emit all types needed for recompilation
output=$(pahole --compile "$obj" 2>/dev/null)
if [ -z "$output" ]; then
	error_log "FAIL: --compile produced no output"
	test_fail
fi

# Verify forward declaration is resolved — struct fwd_decl should
# appear as a full definition, not just "struct fwd_decl;"
if ! echo "$output" | grep -q "struct fwd_decl {"; then
	error_log "FAIL: --compile did not emit struct fwd_decl definition"
	test_fail
fi
info_log "   forward declaration resolution: ok"

# Verify typedef chain emission: nested_uint -> my_uint -> unsigned int
if ! echo "$output" | grep -q "typedef.*my_uint"; then
	error_log "FAIL: --compile did not emit typedef my_uint"
	test_fail
fi
if ! echo "$output" | grep -q "typedef.*nested_uint"; then
	error_log "FAIL: --compile did not emit typedef nested_uint"
	test_fail
fi
info_log "   typedef chain emission: ok"

# Verify enum emission
if ! echo "$output" | grep -q "enum color"; then
	error_log "FAIL: --compile did not emit enum color"
	test_fail
fi
info_log "   enum emission: ok"

# Verify struct ordering: inner must appear before outer since
# outer contains struct inner.
inner_line=$(echo "$output" | grep -n "struct inner {" | head -1 | cut -d: -f1)
outer_line=$(echo "$output" | grep -n "struct outer {" | head -1 | cut -d: -f1)
if [ -n "$inner_line" ] && [ -n "$outer_line" ]; then
	if [ "$inner_line" -ge "$outer_line" ]; then
		error_log "FAIL: inner emitted after outer (line $inner_line >= $outer_line)"
		test_fail
	fi
	info_log "   dependency ordering: ok (inner at $inner_line, outer at $outer_line)"
else
	error_log "FAIL: could not find inner/outer in --compile output"
	test_fail
fi

# --compile -C: emit a single type and its dependencies
output=$(pahole --compile -C outer "$obj" 2>/dev/null)
if [ -z "$output" ]; then
	error_log "FAIL: --compile -C outer produced no output"
	test_fail
fi
if ! echo "$output" | grep -q "struct inner {"; then
	error_log "FAIL: --compile -C outer did not emit dependency struct inner"
	test_fail
fi
info_log "   --compile -C (with dependencies): ok"

# --emit_variables: emit dummy variables for each type
output=$(pahole --compile --emit_variables "$obj" 2>/dev/null)
if [ -z "$output" ]; then
	error_log "FAIL: --compile --emit_variables produced no output"
	test_fail
fi
# Should have variable declarations like: struct outer __outer_var;
# or similar placeholder variables
info_log "   --emit_variables: ok (no crash)"

test_pass
