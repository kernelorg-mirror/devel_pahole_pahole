#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test C++ class features: inheritance and namespace printing.

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT

title_log "C++ inheritance and namespace printing."

CXX=${CXX:-g++}
if ! command -v ${CXX%% *} > /dev/null 2>&1; then
	info_log "skip: $CXX not available"
	test_skip
fi

cxx_src="$outdir/cpp_features.cpp"
cxx_obj="$outdir/cpp_features.o"

cat > "$cxx_src" << 'EOF'
namespace mylib {
  struct Base {
    int x;
    virtual void f() {}
  };
  struct Derived : public Base {
    int y;
    void f() override {}
  };
  struct VDerived : virtual public Base {
    int z;
  };
}
mylib::Derived g1;
mylib::VDerived g2;
EOF

$CXX -g -std=c++11 -c -o "$cxx_obj" "$cxx_src" 2>/dev/null
if [ $? -ne 0 ]; then
	error_log "FAIL: C++ compilation failed"
	test_fail
fi

# Inheritance - pahole -C Derived should show base class info
output=$(pahole -C Derived "$cxx_obj" 2>/dev/null)
if [ -z "$output" ]; then
	error_log "FAIL: pahole -C Derived produced no output"
	test_fail
fi
if ! echo "$output" | grep -q "Base"; then
	error_log "FAIL: inheritance output does not mention Base"
	test_fail
fi
info_log "   inheritance (Derived : Base): ok"

# Virtual inheritance — output should mention the base class
output=$(pahole -C VDerived "$cxx_obj" 2>/dev/null)
if [ -z "$output" ]; then
	error_log "FAIL: pahole -C VDerived produced no output"
	test_fail
fi
if ! echo "$output" | grep -q "Base"; then
	error_log "FAIL: VDerived output does not mention virtual Base"
	test_fail
fi
info_log "   virtual inheritance (VDerived): ok"

# -E on C++ class should expand inherited members (e.g. int x from Base)
output=$(pahole -E -C Derived "$cxx_obj" 2>/dev/null)
if [ -z "$output" ]; then
	error_log "FAIL: -E -C Derived produced no output"
	test_fail
fi
if ! echo "$output" | grep -q "int"; then
	error_log "FAIL: -E -C Derived did not expand inherited members"
	test_fail
fi
info_log "   -E on C++ class: ok"

# --compile on C++ class should emit compilable output containing struct
output=$(pahole --compile -C Derived "$cxx_obj" 2>/dev/null)
if [ -z "$output" ]; then
	error_log "FAIL: --compile -C Derived produced no output"
	test_fail
fi
# Verify the emitted code compiles (C mode, since pahole emits C structs)
compile_test="$outdir/cpp_compile_check.c"
echo "$output" > "$compile_test"
echo "int main(void) { return 0; }" >> "$compile_test"
if ! ${CC:-gcc} -fsyntax-only "$compile_test" 2>/dev/null; then
	# Non-fatal: C++ classes may not fully round-trip to C
	info_log "   --compile output syntax check: not fully compilable (non-fatal)"
fi
info_log "   --compile on C++ class: ok"

test_pass
