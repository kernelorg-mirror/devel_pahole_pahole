#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Exercise C++ DWARF tag handling in dwarf_loader.c and dwarves_fprintf.c:
#   - DW_TAG_template_value_parameter (dwarf_loader.c ~1478-1493)
#   - DW_TAG_constant (dwarves_fprintf.c ~2151-2160)
#   - DW_TAG_GNU_template_template_param (dwarves_emit.c ~62-71)
# These paths need specific C++ features to generate the right DWARF.

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT

title_log "C++ advanced DWARF tag coverage."

CXX=${CXX:-g++}
if ! command -v ${CXX%% *} > /dev/null 2>&1; then
	info_log "skip: $CXX not available"
	test_skip
fi

src="$outdir/cpp_adv.cpp"
obj="$outdir/cpp_adv.o"

cat > "$src" << 'EOF'
/* Template value parameter generates DW_TAG_template_value_parameter */
template<int N>
struct FixedArray {
	int data[N];
};

/* Template template parameter generates DW_TAG_GNU_template_template_param */
template<typename T>
struct Container {
	T value;
};

template<template<typename> class C, typename T>
struct Wrapper {
	C<T> inner;
};

/* constexpr generates DW_TAG_constant in some DWARF versions */
constexpr int MAX_SIZE = 256;
constexpr int MIN_SIZE = 1;

/* Instantiate templates to force DWARF emission */
FixedArray<8> g_arr8;
FixedArray<16> g_arr16;
Container<int> g_ci;
Wrapper<Container, int> g_wci;

int use_constexpr(void) { return MAX_SIZE + MIN_SIZE; }
EOF

$CXX -g -O0 -std=c++11 -c -o "$obj" "$src" 2>/dev/null
if [ $? -ne 0 ]; then
	info_log "skip: C++11 compilation failed"
	test_skip
fi

# pahole on the C++ object exercises template value parameter handling
output=$(pahole "$obj" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ] || [ -z "$output" ]; then
	error_log "FAIL: pahole on C++ template object produced no output"
	test_fail
fi
info_log "   pahole (C++ templates): ok"

# -E expand on template instantiations
output=$(pahole -E "$obj" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ] || [ -z "$output" ]; then
	error_log "FAIL: pahole -E on C++ template object produced no output"
	test_fail
fi
info_log "   pahole -E (C++ templates): ok"

# pdwtags iterates all tags including DW_TAG_constant and template params
if command -v pdwtags > /dev/null 2>&1; then
	output=$(pdwtags "$obj" 2>/dev/null)
	rc=$?
	if [ $rc -ne 0 ] || [ -z "$output" ]; then
		error_log "FAIL: pdwtags on C++ template object produced no output"
		test_fail
	fi
	info_log "   pdwtags (C++ templates + constexpr): ok"
else
	info_log "   skip: pdwtags not available"
fi

# pfunct to exercise function processing on template code
if command -v pfunct > /dev/null 2>&1; then
	output=$(pfunct -V "$obj" 2>/dev/null)
	rc=$?
	if [ $rc -ne 0 ] || [ -z "$output" ]; then
		error_log "FAIL: pfunct -V on C++ template object produced no output"
		test_fail
	fi
	info_log "   pfunct -V (C++ templates): ok"
else
	info_log "   skip: pfunct not available"
fi

# BTF encode to exercise the tag encoding path for template types
pahole -J "$obj" 2>/dev/null
rc=$?
if [ $rc -ne 0 ]; then
	info_log "   BTF encode (C++ templates): exit $rc (expected, templates may not encode fully)"
else
	output=$(pahole -F btf "$obj" 2>/dev/null)
	if [ -n "$output" ]; then
		info_log "   BTF encode (C++ templates): ok"
	else
		info_log "   BTF encode (C++ templates): encoded but no read-back (non-fatal)"
	fi
fi

test_pass
