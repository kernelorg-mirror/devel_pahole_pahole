#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test --sort, --word_size on unions, and --prettify with bitfields.

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT

title_log "pahole coverage: sort, word_size unions, prettify bitfields."

CC=${CC:-gcc}
if ! command -v ${CC%% *} > /dev/null 2>&1; then
	info_log "skip: $CC not available"
	test_skip
fi

src=$(make_tmpsrc)
obj=$(make_tmpobj)

cat > "$src" << 'EOF'
struct gamma {
	int	g1;
	long	g2;
};

struct alpha {
	int	a1;
	char	a2;
};

struct beta {
	short	b1;
	int	b2;
	char	b3;
};

struct alpha ga;
struct beta gb;
struct gamma gg;

union with_ptrs {
	long	val;
	void	*ptr;
	char	*str;
};

struct has_union {
	int		flags;
	union with_ptrs	u;
	long		count;
};

union with_ptrs gu;
struct has_union ghu;

struct bitfield_rec {
	unsigned int	x:3;
	unsigned int	y:5;
	unsigned int	z:7;
	unsigned int	w:1;
	unsigned int	pad:16;
};

struct bitfield_rec gbf;
EOF

$CC -g -c -o "$obj" "$src" 2>/dev/null
if [ $? -ne 0 ]; then
	error_log "FAIL: compilation failed"
	test_fail
fi

output=$(pahole --sort "$obj" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ]; then
	error_log "FAIL: pahole --sort exited with code $rc"
	test_fail
fi
if [ -z "$output" ]; then
	error_log "FAIL: --sort produced no output"
	test_fail
fi
first_struct=$(echo "$output" | grep "^struct " | head -1)
case "$first_struct" in
	*alpha*) ;;
	*) error_log "FAIL: --sort did not sort alphabetically, first: $first_struct"; test_fail ;;
esac
info_log "   --sort: ok"

output=$(pahole -w 4 "$obj" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ]; then
	error_log "FAIL: pahole -w 4 exited with code $rc"
	test_fail
fi
if [ -z "$output" ]; then
	error_log "FAIL: -w 4 produced no output"
	test_fail
fi
info_log "   -w 4 (word_size with unions): ok"

output=$(pahole -w 4 -C has_union "$obj" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ]; then
	error_log "FAIL: pahole -w 4 -C has_union exited with code $rc"
	test_fail
fi
if [ -z "$output" ]; then
	error_log "FAIL: -w 4 -C has_union produced no output"
	test_fail
fi
info_log "   -w 4 -C has_union: ok"

binfile="$outdir/test.bin"
printf '\345\003\000\000' > "$binfile"
output=$(pahole -C bitfield_rec --prettify "$binfile" "$obj" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ]; then
	error_log "FAIL: pahole --prettify exited with code $rc"
	test_fail
fi
if [ -z "$output" ]; then
	error_log "FAIL: --prettify with bitfields produced no output"
	test_fail
fi
if ! echo "$output" | grep -q "\.x = "; then
	error_log "FAIL: --prettify missing bitfield values"
	test_fail
fi
info_log "   --prettify with bitfields: ok"

output=$(pahole --sort -w 4 "$obj" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ]; then
	error_log "FAIL: pahole --sort -w 4 exited with code $rc"
	test_fail
fi
if [ -z "$output" ]; then
	error_log "FAIL: --sort -w 4 produced no output"
	test_fail
fi
info_log "   --sort -w 4 combined: ok"

test_pass
