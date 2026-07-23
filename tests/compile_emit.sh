#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test --compile emission pipeline (dwarves_emit.c coverage).

. "$(dirname "$0")/test_lib.sh"
outdir=$(make_tmpdir)

trap cleanup EXIT

title_log "Compile emission pipeline."

CC=${CC:-gcc}
if ! command -v "${CC%% *}" > /dev/null 2>&1; then
	info_log "skip: $CC not available"
	test_skip
fi

src=$(make_tmpsrc)
obj=$(make_tmpobj)

cat > "$src" << 'EOF'
typedef unsigned int my_uint;

enum priority {
	LOW,
	MEDIUM,
	HIGH,
};

struct config {
	int		flags;
	my_uint		timeout;
};

struct node {
	int		value;
	struct node	*next;
	enum priority	prio;
};

typedef void (*event_handler_t)(struct node *, int);

struct widget {
	struct config		*cfg;
	struct node		items;
	event_handler_t		on_event;
	int			(*compare)(const struct node *, const struct node *);
	my_uint			id;
};

struct widget g1;
EOF

if ! $CC -g -c -o "$obj" "$src" 2>/dev/null; then
	error_log "FAIL: compilation failed"
	test_fail
fi

# --compile -C widget: emit compilable C for widget and its dependencies
output=$(pahole --compile -C widget "$obj" 2>/dev/null)
if [ -z "$output" ]; then
	error_log "FAIL: --compile produced no output"
	test_fail
fi

# typedef should be emitted
if ! echo "$output" | grep -q "typedef.*my_uint"; then
	error_log "FAIL: typedef not emitted"
	test_fail
fi
info_log "   typedef emission: ok"

# enum should be emitted
if ! echo "$output" | grep -q "enum priority"; then
	error_log "FAIL: enum not emitted"
	test_fail
fi
info_log "   enum emission: ok"

# function pointer should appear in output
if ! echo "$output" | grep -q "event_handler_t"; then
	if ! echo "$output" | grep -q "on_event"; then
		error_log "FAIL: function pointer not emitted"
		test_fail
	fi
fi
info_log "   function pointer: ok"

# struct config forward declaration should be emitted (used via pointer)
if ! echo "$output" | grep -q "^struct config;"; then
	error_log "FAIL: struct config forward declaration not emitted"
	test_fail
fi
info_log "   forward declaration: ok"

# self-referential struct node should be emitted
if ! echo "$output" | grep -q "struct node"; then
	error_log "FAIL: struct node not emitted"
	test_fail
fi
info_log "   self-referential struct: ok"

# The emitted code should actually compile
emit_src="$outdir/emitted.c"
emit_obj="$outdir/emitted.o"
echo "$output" > "$emit_src"
if ! $CC -c -o "$emit_obj" "$emit_src" 2>/dev/null; then
	error_log "FAIL: emitted code does not compile"
	test_fail
fi
info_log "   emitted code compiles: ok"

test_pass
