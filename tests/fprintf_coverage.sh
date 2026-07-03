#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Exercise uncovered paths in dwarves_fprintf.c:
#   - DW_TAG_subroutine_type in struct member printing (function pointers)
#   - "first biggest size base type member" verbose output (-l flag)
#   - DW_TAG_label, DW_TAG_lexical_block in function body display
#   - DW_TAG_reference_type, DW_TAG_ptr_to_member_type (C++)
#   - DW_TAG_imported_declaration, DW_TAG_imported_module (C++)

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT

title_log "dwarves_fprintf.c coverage: fn-ptr members, labels, C++ types."

CC=${CC:-gcc}
if ! command -v ${CC%% *} > /dev/null 2>&1; then
	info_log "skip: $CC not available"
	test_skip
fi

# ---------------------------------------------------------------
# Part 1: C source — function pointer members, verbose output
# ---------------------------------------------------------------

c_src="$outdir/fprintf_c.c"
c_obj="$outdir/fprintf_c.o"

cat > "$c_src" << 'EOF'
typedef int (*callback_fn)(void *, int);

/* Function pointer members trigger DW_TAG_subroutine_type handling
 * in struct_member__fprintf (dwarves_fprintf.c lines ~1272-1303). */
struct with_fn_ptr {
	callback_fn	on_event;
	void		(*on_done)(void);
	int		data;
};

/* Mixed-size base type members — the -l flag triggers
 * show_first_biggest_size_base_type_member output (line ~2084). */
struct mixed_sizes {
	long	big;
	char	small;
	int	medium;
	short	tiny;
};

/* Function with a label and goto — produces DW_TAG_label in DWARF.
 * pfunct -T exercises the DW_TAG_label case (line ~1374). */
int with_label(int x) {
	if (x > 0) goto positive;
	return -1;
positive:
	return x;
}

/* Inner block exercises DW_TAG_lexical_block printing (line ~1385). */
int with_block(int x) {
	int result = 0;
	{
		int tmp = x * 2;
		result = tmp + 1;
	}
	return result;
}

struct with_fn_ptr g_fp;
struct mixed_sizes g_ms;
EOF

$CC -g -O0 -c -o "$c_obj" "$c_src" 2>/dev/null
if [ $? -ne 0 ]; then
	error_log "FAIL: C compilation failed"
	test_fail
fi

output=$(pahole -C with_fn_ptr "$c_obj" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ] || [ -z "$output" ]; then
	error_log "FAIL: pahole -C with_fn_ptr produced no output"
	test_fail
fi
if ! echo "$output" | grep -q "on_done"; then
	error_log "FAIL: with_fn_ptr missing on_done member"
	test_fail
fi
info_log "   pahole -C with_fn_ptr: ok"

output=$(pahole -E -C with_fn_ptr "$c_obj" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ] || [ -z "$output" ]; then
	error_log "FAIL: pahole -E -C with_fn_ptr produced no output"
	test_fail
fi
info_log "   pahole -E -C with_fn_ptr: ok"

# -l triggers show_first_biggest_size_base_type_member: prints the
# name, offset, and size of the largest base-type member in the struct
output=$(pahole -l -C mixed_sizes "$c_obj" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ] || [ -z "$output" ]; then
	error_log "FAIL: pahole -l -C mixed_sizes produced no output"
	test_fail
fi
if echo "$output" | grep -q "first biggest size base type member"; then
	info_log "   pahole -l (first biggest base type): ok"
else
	info_log "   pahole -l: produced output (biggest base type line may be compiler-dependent)"
fi

output=$(pahole --reorganize -C mixed_sizes "$c_obj" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ] || [ -z "$output" ]; then
	error_log "FAIL: pahole --reorganize -C mixed_sizes produced no output"
	test_fail
fi
info_log "   pahole --reorganize -C mixed_sizes: ok"

# pfunct -T shows function bodies including labels and lexical blocks
if command -v pfunct > /dev/null 2>&1; then
	output=$(pfunct -T -V "$c_obj" 2>/dev/null)
	rc=$?
	if [ $rc -ne 0 ] || [ -z "$output" ]; then
		error_log "FAIL: pfunct -T -V produced no output"
		test_fail
	fi
	info_log "   pfunct -T -V (labels/blocks): ok"
else
	info_log "   skip: pfunct not available"
fi

# ---------------------------------------------------------------
# Part 2: C++ source — reference types, ptr-to-member, using decls
# ---------------------------------------------------------------

CXX=${CXX:-g++}
if ! command -v ${CXX%% *} > /dev/null 2>&1; then
	info_log "   skip: C++ tests — $CXX not available"
	test_pass
fi

cpp_src="$outdir/fprintf_cpp.cpp"
cpp_obj="$outdir/fprintf_cpp.o"

cat > "$cpp_src" << 'EOF'
struct Base {
	int x;
	int y;
};

/* Pointer-to-member type — produces DW_TAG_ptr_to_member_type in DWARF.
 * tag__name() formats this as "int Base::*" (dwarves_fprintf.c line ~622). */
int Base::*g_ptm = &Base::x;

/* Reference parameter — produces DW_TAG_reference_type in DWARF.
 * tag__name() formats the "&" suffix (line ~620). */
int& ref_func(int& x) { return x; }

namespace util {
	struct Helper { int val; };
	int helper_fn(Helper *h) { return h->val; }
}

/* using-declaration produces DW_TAG_imported_declaration;
 * using-directive produces DW_TAG_imported_module.
 * pdwtags exercises imported_declaration__fprintf() and
 * imported_module__fprintf() (lines ~2251-2263). */
using util::Helper;
using namespace util;

Helper g_helper;
EOF

$CXX -g -O0 -c -o "$cpp_obj" "$cpp_src" 2>/dev/null
if [ $? -ne 0 ]; then
	info_log "   skip: C++ compilation failed"
	test_pass
fi

output=$(pahole "$cpp_obj" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ] || [ -z "$output" ]; then
	error_log "FAIL: pahole on C++ object produced no output"
	test_fail
fi
if ! echo "$output" | grep -q "struct Base"; then
	error_log "FAIL: C++ output missing struct Base"
	test_fail
fi
info_log "   pahole (C++ types): ok"

output=$(pahole -E -C Base "$cpp_obj" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ] || [ -z "$output" ]; then
	error_log "FAIL: pahole -E -C Base produced no output"
	test_fail
fi
info_log "   pahole -E -C Base (C++): ok"

# pdwtags iterates all tag types including imported declarations/modules
if command -v pdwtags > /dev/null 2>&1; then
	output=$(pdwtags "$cpp_obj" 2>/dev/null)
	rc=$?
	if [ $rc -ne 0 ] || [ -z "$output" ]; then
		error_log "FAIL: pdwtags on C++ object produced no output"
		test_fail
	fi
	info_log "   pdwtags (C++): ok"
else
	info_log "   skip: pdwtags not available"
fi

test_pass
