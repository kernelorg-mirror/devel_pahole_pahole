#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test C++ template pretty printing round-trip.
#
# Verifies that pahole --compile --emit_variables on C++ template
# instantiations produces valid, compilable C++ that survives a
# round-trip: the pahole output from the recompiled code must be
# identical to the pahole output from the original.
#
# Covers: type parameters, value parameters, parameter packs, and
# nested templates.

. "$(dirname "$0")/test_lib.sh"
outdir=$(make_tmpdir)

trap cleanup EXIT

title_log "C++ template pretty printing round-trip."

CXX=${CXX:-g++}
if ! command -v "${CXX%% *}" > /dev/null 2>&1; then
	info_log "skip: $CXX not available"
	test_skip
fi

# Step 1: Create a C++ source with various template patterns
cat > "$outdir/templates.cpp" << 'EOF'
template<typename T, int N>
struct FixedArray {
	T data[N];
	int size;
};

template<typename K, typename V>
struct Pair {
	K key;
	V value;
};

template<typename... Ts>
struct Tuple {
	int dummy;
};

template<typename T>
struct Wrapper {
	T inner;
	int flags;
};

// Plain (non-template) struct — canary for template-skip gating
struct PlainConfig {
	int flags;
	int mode;
	char name[32];
};

// Instantiate all templates so DWARF includes them
FixedArray<int, 10> fixed_arr;
Pair<int, float> pair;
Pair<int, Wrapper<int>> nested_pair;
Tuple<int, float, double> tuple;
Wrapper<int> wrapper;
PlainConfig plain_cfg;
EOF

# Step 2: Compile the original source
if ! $CXX -std=c++11 -g -c "$outdir/templates.cpp" -o "$outdir/templates.o" 2>/dev/null; then
	error_log "FAIL: failed to compile original C++ source"
	test_fail
fi

# Step 3: Generate compilable output from the original object
if ! pahole --compile --emit_variables "$outdir/templates.o" > "$outdir/pass1.cpp" 2>/dev/null; then
	error_log "FAIL: pahole --compile --emit_variables failed on original object"
	test_fail
fi

# Verify the output is non-empty
if [ ! -s "$outdir/pass1.cpp" ]; then
	error_log "FAIL: pahole --compile produced empty output"
	test_fail
fi

# Step 4: Compile the pahole output
if ! $CXX -std=c++11 -g -x c++ -c "$outdir/pass1.cpp" -o "$outdir/pass1.o" 2>/dev/null; then
	error_log "FAIL: pahole output does not compile as C++"
	info_log "Output was:"
	cat "$outdir/pass1.cpp" >&2
	test_fail
fi

# Step 5: Generate compilable output from the recompiled object
if ! pahole --compile --emit_variables "$outdir/pass1.o" > "$outdir/pass2.cpp" 2>/dev/null; then
	error_log "FAIL: pahole --compile --emit_variables failed on recompiled object"
	test_fail
fi

# Step 6: Compare the two pahole outputs — they must be identical
if ! diff -u "$outdir/pass1.cpp" "$outdir/pass2.cpp" > "$outdir/diff.txt" 2>&1; then
	error_log "FAIL: round-trip produced different output"
	info_log "diff:"
	cat "$outdir/diff.txt" >&2
	test_fail
fi

# Step 7: Verify key template syntax elements are present
if ! grep -q "^template<[^>]" "$outdir/pass1.cpp"; then
	error_log "FAIL: no template<> forward declarations found"
	test_fail
fi

if ! grep -q "^template<>$" "$outdir/pass1.cpp"; then
	error_log "FAIL: no template<> specialization prefix found"
	test_fail
fi

if ! grep -q "__pahole_type_" "$outdir/pass1.cpp"; then
	error_log "FAIL: no __pahole_type_ variables found"
	test_fail
fi

# Plain struct must survive (canary: template-skip must not eat non-templates)
if ! grep -q "struct PlainConfig" "$outdir/pass1.cpp"; then
	error_log "FAIL: plain (non-template) struct PlainConfig missing from output"
	test_fail
fi

test_pass
