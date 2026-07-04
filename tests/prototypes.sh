#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test prototype expression parsing and --prettify pretty-printing.
# Exercises prototype__new(), class_member_filter__parse(), and
# prototype__stdio_fprintf_value() with various argument forms.
#
# The existing prettify_perf.data.sh tests the full pipeline with
# explicit sizeof=size,type=type,type_enum=...,filter=type==SYMBOL.
# This test covers additional syntax: shorthand sizeof/type keywords,
# shorthand filter (foo==bar without filter= prefix), numeric filter
# values, and --header_type with --seek_bytes/--size_bytes.

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT

title_log "Prototype expression parsing and prettify."

perf=$(which perf 2>/dev/null)
if [ -z "$perf" ]; then
	info_log "skip: perf not available"
	test_skip
fi

# Check that perf has the needed type info
perf_lacks_type() {
	# Use -F dwarf to match the prettify() helper — avoid false
	# positive if perf has BTF but no DWARF
	if ! pahole --features=force_cu_merging -F dwarf -C "$1" "$perf" 2>/dev/null | grep -q "^struct $1 {"; then
		info_log "skip: $perf lacks '$1' type info"
		test_skip
	fi
}

perf_lacks_type perf_event_header
perf_lacks_type perf_file_header

# Record a tiny perf.data
perf_data="$outdir/perf.data"
$perf record --quiet -o "$perf_data" sleep 0.00001 2>/dev/null
if [ ! -s "$perf_data" ]; then
	info_log "skip: perf record produced no data"
	test_skip
fi

# Helper: run pahole --prettify with given -C expression
prettify() {
	pahole --features=force_cu_merging -F dwarf "$perf" \
		--header=perf_file_header \
		--seek_bytes='$header.data.offset' \
		--size_bytes='$header.data.size' \
		-C "$1" \
		--prettify "$perf_data" 2>/dev/null
}

# --- Shorthand sizeof (keyword only, no =size) ---
output=$(prettify 'perf_event_header(sizeof)')
if [ -z "$output" ]; then
	error_log "FAIL: shorthand sizeof produced no output"
	test_fail
fi
if ! echo "$output" | grep -q "\.type = "; then
	error_log "FAIL: shorthand sizeof output missing .type field"
	test_fail
fi
info_log "   shorthand sizeof: ok"

# --- Shorthand type (keyword only, no =type) ---
output=$(prettify 'perf_event_header(sizeof,type)')
if [ -z "$output" ]; then
	error_log "FAIL: shorthand type produced no output"
	test_fail
fi
info_log "   shorthand type: ok"

# --- Explicit sizeof=size,type=type ---
output=$(prettify 'perf_event_header(sizeof=size,type=type)')
if [ -z "$output" ]; then
	error_log "FAIL: explicit sizeof=size,type=type produced no output"
	test_fail
fi
info_log "   explicit sizeof=size,type=type: ok"

# --- Numeric filter value (type==3 is PERF_RECORD_COMM) ---
output=$(prettify 'perf_event_header(sizeof,filter=type==3)')
if [ -z "$output" ]; then
	# perf.data might not have COMM records in data section,
	# but the command shouldn't crash
	info_log "   numeric filter: no matching records (ok)"
else
	if ! echo "$output" | grep -q "\.type = 3,"; then
		error_log "FAIL: numeric filter output has wrong type"
		test_fail
	fi
	# Verify filter excludes other types
	if echo "$output" | grep "\.type = " | grep -qv "\.type = 3,"; then
		error_log "FAIL: numeric filter leaked non-matching records"
		test_fail
	fi
	info_log "   numeric filter (type==3): ok"
fi

# --- Shorthand filter syntax (foo==bar without filter= prefix) ---
output=$(prettify 'perf_event_header(sizeof,type==3)')
# Same as above — may not have records, but shouldn't crash
if [ -n "$output" ]; then
	if ! echo "$output" | grep -q "\.type = 3,"; then
		error_log "FAIL: shorthand filter has wrong type"
		test_fail
	fi
	# Verify filter exclusion
	if echo "$output" | grep "\.type = " | grep -qv "\.type = 3,"; then
		error_log "FAIL: shorthand filter leaked non-matching records"
		test_fail
	fi
fi
info_log "   shorthand filter (type==3): ok"

# --- Symbolic filter with type_enum ---
# Use -F dwarf to match the prettify() helper
if pahole --features=force_cu_merging -F dwarf -C perf_event_type "$perf" 2>/dev/null | grep -q "^enum perf_event_type"; then
	output=$(prettify 'perf_event_header(sizeof,type=type,type_enum=perf_event_type,filter=type==PERF_RECORD_COMM)')
	if [ -z "$output" ]; then
		# Short trace may not have COMM records
		info_log "   symbolic filter: no COMM records (ok)"
	else
		if ! echo "$output" | grep -q "PERF_RECORD_COMM"; then
			error_log "FAIL: symbolic filter output missing PERF_RECORD_COMM"
			test_fail
		fi
		comm_count=$(echo "$output" | grep -c "\.type = PERF_RECORD_COMM,")
		info_log "   symbolic filter (PERF_RECORD_COMM): ok ($comm_count records)"
	fi
else
	info_log "   skip: perf_event_type enum not available"
fi

# --- Multiple type_enum sources (enum1+enum2) ---
# Use -F dwarf to match the prettify() helper
if pahole --features=force_cu_merging -F dwarf -C perf_user_event_type "$perf" 2>/dev/null | grep -q "^enum perf_user_event_type"; then
	output=$(prettify 'perf_event_header(sizeof,type=type,type_enum=perf_event_type+perf_user_event_type,filter=type==PERF_RECORD_FINISHED_INIT)')
	if [ -z "$output" ]; then
		# Short trace may not have FINISHED_INIT records
		info_log "   multi type_enum: no FINISHED_INIT records (ok)"
	else
		if ! echo "$output" | grep -q "PERF_RECORD_FINISHED_INIT"; then
			error_log "FAIL: multi type_enum output missing PERF_RECORD_FINISHED_INIT"
			test_fail
		fi
		info_log "   multi type_enum (enum1+enum2): ok"
	fi
else
	info_log "   skip: perf_user_event_type enum not available"
fi

# --- Error handling: unknown argument should not crash ---
output=$(pahole --features=force_cu_merging -F dwarf "$perf" \
	-C "perf_event_header(bogus_arg=value)" 2>"$outdir/err.txt")
rc=$?
if [ $rc -gt 128 ]; then
	error_log "FAIL: unknown arg caused crash (signal $((rc - 128)))"
	test_fail
fi
info_log "   unknown argument: no crash (rc=$rc)"

test_pass
