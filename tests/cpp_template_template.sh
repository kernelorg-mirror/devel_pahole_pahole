#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test C++ template template parameter pretty printing round-trip.
#
# Verifies that pahole correctly stores DW_TAG_GNU_template_template_param
# and emits valid C++ forward declarations for types that use template
# template parameters (e.g. "template<template<typename...> class C, typename T>").
#
# The round-trip must produce identical output: original → pahole → compile →
# pahole must match.

. "$(dirname "$0")/test_lib.sh"
outdir=$(make_tmpdir)

trap cleanup EXIT

title_log "C++ template template parameter pretty printing round-trip."

CXX=${CXX:-g++}
if ! command -v "${CXX%% *}" > /dev/null 2>&1; then
	info_log "skip: $CXX not available"
	test_skip
fi

# Step 1: Create a C++ source with template template parameters
cat > "$outdir/ttp.cpp" << 'EOF'
template<typename... Ts>
struct BasicList {
	int dummy;
};

template<typename T>
struct SingleContainer {
	T value;
};

template<template<typename...> class Container, typename T>
struct Wrapper {
	Container<T> data;
	int flags;
};

template<template<typename> class C, template<typename...> class D, typename T>
struct MultiTTP {
	C<T> single;
	D<T> multi;
	int count;
};

template<typename T, int N>
struct FixedArray {
	T data[N];
};

template<template<typename, int> class Arr, typename T>
struct WrapperMixed {
	Arr<T, 10> storage;
};

template<template<typename> class... Cs>
struct PackOfTTP {
	int marker;
};

/* Instantiate so DWARF includes them */
Wrapper<BasicList, int> wrapper;
MultiTTP<SingleContainer, BasicList, float> multi;
WrapperMixed<FixedArray, float> mixed;
PackOfTTP<SingleContainer, SingleContainer> pott;
EOF

# Step 2: Compile the original source
if ! $CXX -g -c "$outdir/ttp.cpp" -o "$outdir/ttp.o" 2>/dev/null; then
	error_log "FAIL: failed to compile original C++ source"
	test_fail
fi

# Step 2b: Skip if compiler did not emit template template param DWARF tags
READELF=${READELF:-$(command -v readelf || command -v eu-readelf || true)}
if [ -z "$READELF" ]; then
	info_log "skip: neither readelf nor eu-readelf available"
	test_skip
fi
# Older binutils readelf prints unknown vendor tags as "Unknown TAG value: 4106"
# rather than the symbolic name; match either form.
if ! $READELF --debug-dump=info "$outdir/ttp.o" 2>/dev/null | grep -qE 'GNU_template_template_param|TAG value: 4106'; then
	info_log "skip: compiler did not emit DW_TAG_GNU_template_template_param"
	test_skip
fi

# Step 3: Verify no "tag not supported 0x4106" warnings
warnings=$(pahole "$outdir/ttp.o" 2>&1 | grep -c 'not supported.*4106')
if [ "$warnings" -ne 0 ]; then
	error_log "FAIL: pahole emitted $warnings 'tag not supported 0x4106' warnings"
	test_fail
fi

# Step 4: Generate compilable output from the original object
if ! pahole --compile --emit_variables "$outdir/ttp.o" > "$outdir/pass1.cpp" 2>/dev/null; then
	error_log "FAIL: pahole --compile --emit_variables failed on original object"
	test_fail
fi

if [ ! -s "$outdir/pass1.cpp" ]; then
	error_log "FAIL: pahole --compile produced empty output"
	test_fail
fi

# Step 5: Verify template template parameter syntax is present
if ! grep -q 'template<typename\.\.\.>' "$outdir/pass1.cpp"; then
	error_log "FAIL: no 'template<typename...> class' forward declarations found"
	info_log "Output was:"
	cat "$outdir/pass1.cpp" >&2
	test_fail
fi

# Step 5b: Verify non-variadic template template parameter signatures
if ! grep -q 'template<typename> class' "$outdir/pass1.cpp"; then
	error_log "FAIL: no 'template<typename> class' signature found (single type param)"
	info_log "Output was:"
	cat "$outdir/pass1.cpp" >&2
	test_fail
fi

if ! grep -q 'template<typename, int> class' "$outdir/pass1.cpp"; then
	error_log "FAIL: no 'template<typename, int> class' signature found (mixed params)"
	info_log "Output was:"
	cat "$outdir/pass1.cpp" >&2
	test_fail
fi

# Step 5c: Verify pack-of-template-template-params emits the resolved
# inner signature "template<typename> class..." rather than the lossy
# fallback "template<typename...> class...".  Pins the assumption that
# GCC emits DW_AT_GNU_template_name on pack children.
if ! grep -q 'template<typename> class\.\.\.' "$outdir/pass1.cpp"; then
	error_log "FAIL: no 'template<typename> class...' found for pack-of-ttp parameter"
	info_log "Output was:"
	cat "$outdir/pass1.cpp" >&2
	test_fail
fi

# Step 6: Compile the pahole output
if ! $CXX -g -x c++ -c "$outdir/pass1.cpp" -o "$outdir/pass1.o" 2>/dev/null; then
	error_log "FAIL: pahole output does not compile as C++"
	info_log "Output was:"
	cat "$outdir/pass1.cpp" >&2
	test_fail
fi

# Step 7: Generate compilable output from the recompiled object
if ! pahole --compile --emit_variables "$outdir/pass1.o" > "$outdir/pass2.cpp" 2>/dev/null; then
	error_log "FAIL: pahole --compile --emit_variables failed on recompiled object"
	test_fail
fi

# Step 8: Compare the two pahole outputs — they must be identical.
# This cross-braces with step 5c: if pass1's compiled output ever loses
# DW_AT_GNU_template_name on pack children, pass2 would emit the lossy
# fallback form and this diff catches the divergence.
if ! diff -u "$outdir/pass1.cpp" "$outdir/pass2.cpp" > "$outdir/diff.txt" 2>&1; then
	error_log "FAIL: round-trip produced different output"
	info_log "diff:"
	cat "$outdir/diff.txt" >&2
	test_fail
fi

test_pass
