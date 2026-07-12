#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test C++ DWARF cleanup paths in dwarves.c that are typically uncovered:
#   - lexblock__delete_tags (called when freeing lexical blocks)
#   - template_parameter_pack__delete_tags (called when freeing template packs)
#   - formal_parameter_pack__delete_tags (called when freeing parameter packs)
#   - parameter__delete (called when freeing function parameters)
#
# These are all reached via tag__delete() during CU cleanup, but may not
# be measured if cleanup happens after coverage collection stops. This test
# uses a small C program that explicitly exercises pahole's cleanup paths.

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT

title_log "C++ cleanup: delete_tags coverage for lexblock, parameter packs."

CXX=${CXX:-g++}
if ! command -v ${CXX%% *} > /dev/null 2>&1; then
	info_log "skip: $CXX not available"
	test_skip
fi

# Create a C++ source that produces:
#   1. Template parameter packs (DW_TAG_template_parameter_pack)
#   2. Formal parameter packs (DW_TAG_formal_parameter_pack)
#   3. Lexical blocks (DW_TAG_lexical_block) with local variables
#   4. Function parameters

cat > "$outdir/cleanup_test.cpp" << 'EOF'
// Variadic template — generates template_parameter_pack
template<typename... Ts>
struct Container {
	int count;
};

// Variadic function — generates formal_parameter_pack
template<typename... Args>
int process(Args... args) {
	// Lexical block with local variables
	{
		int local_a = sizeof...(args);
		int local_b = local_a * 2;
		if (local_b > 0) {
			int local_c = local_b + 1;
			return local_c;
		}
	}
	return 0;
}

// Function with explicit parameters to exercise parameter cleanup
int compute(int a, int b, int c, int d) {
	// Nested lexical blocks
	{
		int x = a + b;
		{
			int y = x + c;
			{
				int z = y + d;
				return z;
			}
		}
	}
	return 0;
}

// Instantiate templates to ensure DWARF is generated
template struct Container<int, float, double, char>;
template int process<int, float, double>(int, float, double);

Container<int, float> g_container;
int g_result = compute(1, 2, 3, 4);
EOF

$CXX -std=c++11 -g -c -o "$outdir/cleanup_test.o" "$outdir/cleanup_test.cpp" 2>/dev/null
if [ $? -ne 0 ]; then
	error_log "FAIL: C++ compilation failed"
	test_fail
fi

# Run pahole to load and process all DWARF tags. The key is that pahole
# needs to allocate and then free all these structures. Running with
# various options exercises different code paths.

# Basic run: loads CU, processes all tags, cleanup on exit
pahole "$outdir/cleanup_test.o" > "$outdir/pahole_basic.txt" 2>/dev/null
if [ $? -ne 0 ]; then
	error_log "FAIL: pahole basic run failed"
	test_fail
fi
info_log "   pahole basic run (loads + cleans up all tags): ok"

# Verify template struct is present (proves template_parameter_pack was processed)
if ! grep -q "struct Container" "$outdir/pahole_basic.txt"; then
	error_log "FAIL: Container template struct not found"
	cat "$outdir/pahole_basic.txt" >&2
	test_fail
fi

# Run with --class to exercise per-class processing and cleanup
pahole -C Container "$outdir/cleanup_test.o" > "$outdir/pahole_class.txt" 2>/dev/null
if [ $? -ne 0 ]; then
	error_log "FAIL: pahole -C Container failed"
	test_fail
fi
info_log "   pahole -C Container (targeted lookup + cleanup): ok"

# Run pfunct if available to exercise function parameter cleanup paths
if command -v pfunct > /dev/null 2>&1; then
	pfunct "$outdir/cleanup_test.o" > "$outdir/pfunct.txt" 2>/dev/null
	if [ $? -ne 0 ]; then
		error_log "FAIL: pfunct failed"
		test_fail
	fi

	# Verify functions are listed
	if ! grep -q "process" "$outdir/pfunct.txt"; then
		error_log "FAIL: process function not found in pfunct output"
		cat "$outdir/pfunct.txt" >&2
		test_fail
	fi

	if ! grep -q "compute" "$outdir/pfunct.txt"; then
		error_log "FAIL: compute function not found in pfunct output"
		cat "$outdir/pfunct.txt" >&2
		test_fail
	fi

	info_log "   pfunct (exercises function parameter cleanup): ok"
else
	info_log "   pfunct not available, skipping parameter cleanup verification"
fi

# The test passes if all tools successfully load, process, and clean up
# the C++ DWARF without crashing. Coverage tools should now measure:
#   - lexblock__delete_tags (via lexical blocks in compute/process)
#   - template_parameter_pack__delete_tags (via Container<...>)
#   - formal_parameter_pack__delete_tags (via process<Args...>)
#   - parameter__delete (via compute parameters and template args)

test_pass
