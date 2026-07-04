#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test ctracer: load vmlinux DWARF, find a struct's "methods" (functions
# taking a pointer to it), and generate SystemTap probes + support files.
# Optionally validate the .stp with systemtap dry-run (stap -p4).

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap 'rm -rf "$outdir"' EXIT

title_log "ctracer: struct method tracing generation."

if ! command -v ctracer > /dev/null 2>&1; then
	info_log "skip: ctracer not available in PATH"
	test_skip
fi

vmlinux=$(get_vmlinux)
if [ -z "$vmlinux" ] || [ ! -f "$vmlinux" ]; then
	info_log "skip: no vmlinux with DWARF available"
	test_skip
fi

# Use uts_namespace: small struct, few methods, fast to process.
struct_name="uts_namespace"
ctracer_dir="$outdir/ctracer_output"
mkdir -p "$ctracer_dir"

ctracer -d "$ctracer_dir" "$vmlinux" "$struct_name" 2>"$outdir/ctracer.log"
rc=$?
if [ $rc -ne 0 ]; then
	# Show log directly — avoid $(cat) which flattens newlines
	cat "$outdir/ctracer.log" >&2
	error_log "FAIL: ctracer exited with code $rc"
	test_fail
fi
info_log "   ctracer ran successfully"

# Verify all expected output files were created and are non-empty
for f in ctracer_methods.stp ctracer_classes.h ctracer_collector.c \
         "${struct_name}.functions" "${struct_name}.fields" \
         ctracer2ostra.c; do
	path="$ctracer_dir/$f"
	if [ ! -f "$path" ]; then
		error_log "FAIL: missing output file: $f"
		test_fail
	fi
	if [ ! -s "$path" ]; then
		error_log "FAIL: output file is empty: $f"
		test_fail
	fi
done
info_log "   all output files present and non-empty: ok"

# The .functions file should list kernel functions that take
# a pointer to the target struct
func_count=$(wc -l < "$ctracer_dir/${struct_name}.functions")
if [ "$func_count" -lt 1 ]; then
	error_log "FAIL: no functions found for struct $struct_name"
	test_fail
fi
info_log "   found $func_count method entries"

# The .stp file should contain SystemTap probe definitions
if ! grep -q "^probe .* = kernel.function" "$ctracer_dir/ctracer_methods.stp"; then
	error_log "FAIL: .stp file has no kernel.function probes"
	test_fail
fi
info_log "   .stp contains kernel.function probes: ok"

# The classes header should define the struct and its mini version
if ! grep -q "struct ${struct_name}" "$ctracer_dir/ctracer_classes.h"; then
	error_log "FAIL: ctracer_classes.h missing struct $struct_name"
	test_fail
fi
if ! grep -q "ctracer__mini_${struct_name}" "$ctracer_dir/ctracer_classes.h"; then
	error_log "FAIL: ctracer_classes.h missing mini struct"
	test_fail
fi
info_log "   ctracer_classes.h has struct and mini struct: ok"

# If systemtap is available, validate the .stp with a dry-run compile.
# stap -p4 compiles the script to a .ko without loading it.
if command -v stap > /dev/null 2>&1; then
	stap -p4 "$ctracer_dir/ctracer_methods.stp" \
		> "$outdir/stap.out" 2>"$outdir/stap.err"
	stap_rc=$?
	if [ $stap_rc -eq 0 ]; then
		info_log "   stap -p4 validation: ok"
	elif grep -qE "missing kernel-devel|Cannot find|linux/module\.h|unable to find kernel|ctracer_relay\.h|/build/\.config.*No such file" "$outdir/stap.err"; then
		# Missing kernel-devel headers or runtime support files —
		# infrastructure issue, not a script generation bug.
		info_log "   stap -p4 skipped: missing build environment"
		info_log "   $(head -1 "$outdir/stap.err")"
	else
		# Genuine script error — fail the test so we catch
		# ctracer generation bugs.
		cat "$outdir/stap.err" >&2
		error_log "FAIL: stap -p4 found errors in generated .stp"
		test_fail
	fi
else
	info_log "   stap not available, skipping .stp validation"
fi

test_pass
