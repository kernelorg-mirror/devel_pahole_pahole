#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test the DW_FORM_block byte order conversion logic used by
# __attr_numeric() in dwarf_loader.c.  Exercises both LE and BE
# conversion paths with block lengths 1, 2, 4, and 8 to catch
# endianness mistakes like using be64toh on sub-8-byte blocks.

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT

title_log "DW_FORM_block byte order conversion."

CC=${CC:-gcc}
if ! command -v ${CC%% *} > /dev/null 2>&1; then
	info_log "skip: $CC not available"
	test_skip
fi

cat > "$outdir/block_endian_test.c" << 'EOF'
#define _DEFAULT_SOURCE
#include <endian.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/*
 * These two functions replicate the exact conversion logic from
 * __attr_numeric() in dwarf_loader.c for the DW_FORM_block case.
 * Any change to that code must be mirrored here.
 */
static uint64_t block_to_u64_le(const uint8_t *data, size_t len)
{
	uint64_t value = 0;
	size_t n = len > sizeof(value) ? sizeof(value) : len;

	memcpy(&value, data, n);
	return le64toh(value);
}

static uint64_t block_to_u64_be(const uint8_t *data, size_t len)
{
	uint64_t value = 0;
	size_t n = len > sizeof(value) ? sizeof(value) : len;

	for (size_t i = 0; i < n; i++)
		value = (value << 8) | data[i];
	return value;
}

struct test_case {
	const char  *name;
	int          is_be;       /* 0 = LE target, 1 = BE target */
	uint64_t     expected;
	size_t       len;
	uint8_t      data[8];
};

static const struct test_case tests[] = {
	/* LE target, 1 byte */
	{ "LE n=1 val=5",     0, 5,     1, {0x05} },
	{ "LE n=1 val=0",     0, 0,     1, {0x00} },
	{ "LE n=1 val=255",   0, 255,   1, {0xff} },

	/* LE target, 2 bytes */
	{ "LE n=2 val=256",   0, 256,   2, {0x00, 0x01} },
	{ "LE n=2 val=0x0102",0, 0x0102,2, {0x02, 0x01} },

	/* LE target, 4 bytes */
	{ "LE n=4 val=66051", 0, 66051, 4, {0x03, 0x02, 0x01, 0x00} },
	{ "LE n=4 val=1",     0, 1,     4, {0x01, 0x00, 0x00, 0x00} },

	/* LE target, 8 bytes */
	{ "LE n=8",           0, 0x0807060504030201ULL, 8,
	  {0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08} },

	/* BE target, 1 byte (single byte has no endianness) */
	{ "BE n=1 val=5",     1, 5,     1, {0x05} },
	{ "BE n=1 val=0",     1, 0,     1, {0x00} },
	{ "BE n=1 val=255",   1, 255,   1, {0xff} },

	/* BE target, 2 bytes */
	{ "BE n=2 val=256",   1, 256,   2, {0x01, 0x00} },
	{ "BE n=2 val=0x0102",1, 0x0102,2, {0x01, 0x02} },
	{ "BE n=2 val=1",     1, 1,     2, {0x00, 0x01} },

	/* BE target, 4 bytes */
	{ "BE n=4 val=66051", 1, 66051, 4, {0x00, 0x01, 0x02, 0x03} },
	{ "BE n=4 val=1",     1, 1,     4, {0x00, 0x00, 0x00, 0x01} },

	/* BE target, 8 bytes */
	{ "BE n=8",           1, 0x0102030405060708ULL, 8,
	  {0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08} },
};

int main(void)
{
	int failures = 0;
	size_t n = sizeof(tests) / sizeof(tests[0]);

	for (size_t i = 0; i < n; i++) {
		const struct test_case *t = &tests[i];
		uint64_t got;

		if (t->is_be)
			got = block_to_u64_be(t->data, t->len);
		else
			got = block_to_u64_le(t->data, t->len);

		if (got != t->expected) {
			fprintf(stderr, "FAIL: %s: expected 0x%llx, got 0x%llx\n",
				t->name,
				(unsigned long long)t->expected,
				(unsigned long long)got);
			failures++;
		}
	}

	if (failures) {
		fprintf(stderr, "%d/%zu tests failed\n", failures, n);
		return 1;
	}
	return 0;
}
EOF

$CC -std=c11 -Wall -Werror -o "$outdir/block_endian_test" \
	"$outdir/block_endian_test.c" 2>/dev/null
if [ $? -ne 0 ]; then
	error_log "FAIL: failed to compile block_endian_test"
	test_fail
fi

output=$("$outdir/block_endian_test" 2>&1)
if [ $? -ne 0 ]; then
	error_log "FAIL: block endian conversion test failed:"
	error_log "$output"
	test_fail
fi

info_log "   block form LE+BE conversion: ok"

test_pass
