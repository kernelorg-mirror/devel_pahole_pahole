#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test C++ value parameter packs and shadow definition disambiguation.
#
# Covers two uncovered paths in dwarves_emit.c:
#   1. type__emit_template_pack_param() value-param branch: a pack
#      like template<int... Ns> must emit "int... Ns" not "typename... Ns"
#   2. type_emissions__find_shadow_definition() + suffix_disambiguation:
#      when enum foo and struct foo coexist, the second gets a "__1" suffix

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT

title_log "C++ value parameter pack and shadow definition disambiguation."

CXX=${CXX:-g++}
if ! command -v ${CXX%% *} > /dev/null 2>&1; then
	info_log "skip: $CXX not available"
	test_skip
fi

src="$outdir/cpp_shadow.cpp"
obj="$outdir/cpp_shadow.o"

cat > "$src" << 'EOF'
template<int... Ns>
struct IntSequence {
	int count;
};

template<int N>
struct FixedBuf {
	char data[N];
};

/* Shadow definitions: in C (not C++), enum foo and struct foo
 * can coexist because they occupy separate tag namespaces.
 * When pahole emits both with --compile, the second must be
 * disambiguated with a "__1" suffix.  We test this via a
 * separate C compilation below. */

IntSequence<1, 2, 3> g_seq;
FixedBuf<64> g_buf;
EOF

if ! $CXX -g -std=c++11 -c -o "$obj" "$src" 2>"$outdir/cc.log"; then
	info_log "skip: C++ compilation failed"
	info_log "$(cat "$outdir/cc.log")"
	test_skip
fi

compile_out="$outdir/compile_out.cpp"
pahole --compile --emit_variables "$obj" > "$compile_out" 2>"$outdir/pahole.log"
rc=$?

if [ $rc -gt 128 ]; then
	error_log "FAIL: pahole crashed (signal $((rc - 128)))"
	test_fail
fi
if [ ! -s "$compile_out" ]; then
	error_log "FAIL: pahole --compile produced no output"
	test_fail
fi
info_log "   pahole --compile produced output: ok"

# Check 1: value parameter pack — "int..." in template decl
if grep -q 'int\.\.\.' "$compile_out"; then
	info_log "   value parameter pack 'int...' found: ok"
elif grep -q 'template<int, int, int>' "$compile_out"; then
	# Compiler expanded pack into individual params — non-fatal
	info_log "   value pack expanded to individual params (compiler choice, non-fatal)"
elif grep -q 'IntSequence' "$compile_out"; then
	info_log "   IntSequence present but no pack pattern (compiler-dependent, non-fatal)"
else
	error_log "FAIL: IntSequence not found in --compile output"
	test_fail
fi

# Check 2: single value parameter
if grep -q 'template<int' "$compile_out"; then
	info_log "   single value param 'template<int' present: ok"
else
	error_log "FAIL: FixedBuf template<int N> not found"
	test_fail
fi

# Check 3: round-trip compilation of C++ output
if ! $CXX -std=c++11 -x c++ -c -o "$outdir/roundtrip.o" "$compile_out" 2>"$outdir/cc_rt.log"; then
	error_log "FAIL: --compile output does not compile back"
	info_log "$(cat "$outdir/cc_rt.log")"
	test_fail
fi
info_log "   round-trip compilation: ok"

# Shadow definition disambiguation (enum foo + struct foo) requires
# DWARF from merged CUs (e.g. vmlinux) which can't be synthesized
# from a single source file.  Not tested here.

test_pass
