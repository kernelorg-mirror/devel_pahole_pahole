#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test --packable and --reorganize options.

. "$(dirname "$0")/test_lib.sh"
outdir=$(make_tmpdir)

trap cleanup EXIT

title_log "Struct packing and reorganization."

CC=${CC:-gcc}
if ! command -v "${CC%% *}" > /dev/null 2>&1; then
	info_log "skip: $CC not available"
	test_skip
fi

src=$(make_tmpsrc)
obj=$(make_tmpobj)

cat > "$src" << 'EOF'
/*
 * Struct with padding holes that shrinks when reorganized:
 * reorg moves the chars together, saving 4 bytes (16 -> 12).
 */
struct packme {
	int	a;
	char	b;
	int	c;
	char	d;
};

struct packme g;
EOF

if ! $CC -g -c -o "$obj" "$src" 2>/dev/null; then
	error_log "FAIL: compilation failed"
	test_fail
fi

# --packable should list packme with original=16 and packed=12 sizes
output=$(pahole -P "$obj" 2>/dev/null)
if ! echo "$output" | grep -q "packme"; then
	error_log "FAIL: --packable did not list packme"
	test_fail
fi
# tab-separated: name original_size packed_size savings
TAB=$(printf '\t')
if ! echo "$output" | grep -q "^packme${TAB}16${TAB}12${TAB}4$"; then
	error_log "FAIL: --packable expected 'packme 16 12 4', got: $output"
	test_fail
fi
info_log "--packable: ok"

# --reorganize should produce a 12-byte layout saving 4 bytes
output=$(pahole -R -C packme "$obj" 2>/dev/null)
if ! echo "$output" | grep -q "struct packme"; then
	error_log "FAIL: --reorganize produced no output"
	test_fail
fi
if ! echo "$output" | grep -q "saved 4 bytes"; then
	error_log "FAIL: --reorganize did not save 4 bytes"
	test_fail
fi
if ! echo "$output" | grep -q "size: 12"; then
	error_log "FAIL: --reorganize result not 12 bytes"
	test_fail
fi
info_log "--reorganize: ok"

# --show_reorg_steps implies --reorganize and shows step-by-step moves
output=$(pahole -S -C packme "$obj" 2>/dev/null)
if ! echo "$output" | grep -q "Moving"; then
	error_log "FAIL: --show_reorg_steps did not show reorganization steps"
	test_fail
fi
if ! echo "$output" | grep -q "saved"; then
	error_log "FAIL: --show_reorg_steps did not show savings"
	test_fail
fi
info_log "--show_reorg_steps: ok"

test_pass
