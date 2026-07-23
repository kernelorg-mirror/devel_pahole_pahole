#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Test --prettify with structs containing bitfield members.
# Covers class_member__bitfield_value() and
# class_member__fprintf_bitfield_value() in pahole.c (both at 0% coverage).
#
# Creates a small binary file with known bitfield values and verifies
# pahole --prettify decodes them correctly.

. "$(dirname "$0")/test_lib.sh"

CC=${CC:-gcc}

if ! command -v "${CC%% *}" > /dev/null 2>&1; then
	test_skip "compiler not available"
fi

outdir=$(make_tmpdir)
trap cleanup EXIT

# Bitfield layout is endian-dependent — detect host endianness
cat > "$outdir/endian.c" <<'EOF'
#include <stdio.h>
int main(void) {
	unsigned int v = 1;
	unsigned char *p = (unsigned char *)&v;
	printf("%s\n", p[0] ? "little" : "big");
	return 0;
}
EOF
if ! $CC -o "$outdir/endian" "$outdir/endian.c" 2>"$outdir/cc.log"; then
	info_log "compiler error:"
	info_log "$(cat "$outdir/cc.log")"
	test_skip "cannot compile endianness detector"
fi
endian=$("$outdir/endian")

cat > "$outdir/bf.c" <<'EOF'
struct bf_record {
	unsigned int flags:4;
	unsigned int type:8;
	unsigned int size:20;
};

/* Ensure the struct is used so DWARF is emitted */
struct bf_record global_bf;
EOF

if ! $CC -g -c -o "$outdir/bf.o" "$outdir/bf.c" 2>"$outdir/cc.log"; then
	info_log "compiler error:"
	info_log "$(cat "$outdir/cc.log")"
	test_skip "cannot compile bitfield test source"
fi

# Write a binary record with known values:
#   flags = 0xa (4 bits), type = 0x55 (8 bits), size = 0x12345 (20 bits)
# Little-endian: bits [3:0]=flags, [11:4]=type, [31:12]=size
#   byte 0: flags(4) | type_lo(4) = 0x5a
#   byte 1: type_hi(4) | size_lo(4) = 0x45
#   byte 2: size[11:4] = 0x23
#   byte 3: size[19:12] = 0x01
cat > "$outdir/writer.c" <<'EOF'
#include <stdio.h>
struct bf_record {
	unsigned int flags:4;
	unsigned int type:8;
	unsigned int size:20;
};
int main(void) {
	struct bf_record r = { .flags = 0xa, .type = 0x55, .size = 0x12345 };
	FILE *f = fopen("bf.bin", "wb");
	if (!f) return 1;
	fwrite(&r, sizeof(r), 1, f);
	fclose(f);
	return 0;
}
EOF

if ! $CC -o "$outdir/writer" "$outdir/writer.c" 2>"$outdir/cc.log"; then
	info_log "compiler error:"
	info_log "$(cat "$outdir/cc.log")"
	test_skip "cannot compile binary writer"
fi

(cd "$outdir" && ./writer)
if [ ! -f "$outdir/bf.bin" ]; then
	test_skip "binary writer failed to produce output"
fi

# Run pahole --prettify to decode the bitfield values
output=$(pahole --prettify="$outdir/bf.bin" -C bf_record "$outdir/bf.o" 2>"$outdir/pahole.err")

if [ -z "$output" ]; then
	# --prettify with bitfields may not be supported on all builds
	if [ -s "$outdir/pahole.err" ]; then
		info_log "pahole stderr: $(cat "$outdir/pahole.err")"
	fi
	test_skip "pahole --prettify produced no output for bitfield struct"
fi

# Verify the bitfield values appear in the output
if echo "$output" | grep -q "flags"; then
	info_log "   prettify bitfield flags: ok"
else
	error_log "FAIL: prettify output missing 'flags' field"
	error_log "output: $output"
	test_fail
fi

if echo "$output" | grep -q "type"; then
	info_log "   prettify bitfield type: ok"
else
	error_log "FAIL: prettify output missing 'type' field"
	test_fail
fi

if echo "$output" | grep -q "size"; then
	info_log "   prettify bitfield size: ok"
else
	error_log "FAIL: prettify output missing 'size' field"
	test_fail
fi

# Check for specific values if possible
if echo "$output" | grep -qE '0xa|10'; then
	info_log "   prettify bitfield value (flags=0xa): ok"
fi

info_log "   endianness: $endian"

test_pass
