#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test perf data-type profiling JSON backend and --perf-data-type option.
#
# The JSON backend consumes the "histograms" format produced by:
#   perf report -s type --data-type-json=file.json
#   perf annotate --data-type --data-type-json=file.json
#
# This is aggregate per-offset data with loads and stores counted separately
# (nr_samples_load/nr_samples_store, period_load/period_store) for hot-field
# highlighting and a read/write breakdown.  False-sharing detection and
# cacheline-group suggestions require the CTF backend (per-sample timestamp,
# cpu, instance identity).
#
# Tests:
#  1. Histograms profile loads and annotates struct members
#  2. Reads and writes split correctly via per-direction counters
#  3. Multi-type JSON: two structs in one file
#  4. Zero-sample offsets are skipped (only nonzero counters shown)
#  5. No false-sharing flags from aggregate data (no per-sample signal)
#  6. Error: missing file -> exit 1
#  7. Error: empty directory -> exit 1 (CTF backend dispatch)
#  8. Error: malformed JSON -> exit 1
#  9. Comment block closes with */
# 10. Duplicate type in JSON array gets samples merged
# 11. Duplicate type with disagreeing size: separate entries, size-matching
#     one is annotated
# 12. Build ID mismatch: error, no annotation for that type
# 13. Matching build ID: annotation, no unverified warning
# 14. Missing build ID: unverified warning, annotation still emitted
# 15. Multiple DSOs with the same type name: matching build ID wins
# 16. Default: full-file run pretty prints just the structs with hits
# 17. --perf-data-type-show-all prints all the structs again
# 18. Unions with hits get the annotation block too (compiled fixture)
# 19. JSON whose top level is not an object -> exit 1
# 19b. Empty profile (no types with hits) -> exit 1
# 19c. Well-formed JSON with the wrong shape -> exit 1, no OOB read
# 20. --quiet suppresses the perf_dt annotations and their warnings
# 20b. --quiet keeps the build-ID mismatch quiet as well
# 21. The access counts also go inline, in each member's offset comment
# 22. Members with no samples keep a plain offset comment
# 23. --color=always marks hot fields red and warm ones green
# 24. No colours by default (not a tty) and with --color=never
# 25. --color=always wins over NO_COLOR
# 26. The summary block is coloured too and spells out the heat bands
# 27. The summary block prints only the cachelines that had hits, keeping
#     the idle members of those cachelines as context

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT
cleanup() {
	rm -rf "${outdir}"
}

title_log "perf data-type profiling JSON backend."

# Need pahole with BTF support and a vmlinux with BTF.
# Prefer the just built one, as the other tests do: test_lib.sh puts
# ../build in PATH, which is what the tests runner (tests/tests) runs with,
# and without this fallback this test is skipped there instead of run.
pahole_bin=./build/pahole
if [ ! -x "$pahole_bin" ]; then
	pahole_bin=./pahole
fi
if [ ! -x "$pahole_bin" ]; then
	pahole_bin=$(command -v pahole 2>/dev/null)
fi
if [ ! -x "$pahole_bin" ]; then
	error_log "skip: pahole binary not found"
	test_skip
fi

vmlinux=$(get_vmlinux ./vmlinux)
if [ $? -ne 0 ]; then
	error_log "skip: vmlinux not available"
	test_skip
fi

# Check that vmlinux has BTF
if ! "$pahole_bin" -F btf -C rb_node "$vmlinux" > /dev/null 2>&1; then
	error_log "skip: vmlinux has no BTF"
	test_skip
fi

# The build-ID checks need the vmlinux's build ID, read from the ELF note
# (the BTF loader carries it into the cu, so --perf-data-type entries can
# be verified against it).
if ! command -v readelf > /dev/null 2>&1; then
	error_log "skip: readelf not available"
	test_skip
fi
build_id=$(readelf -n "$vmlinux" 2>/dev/null | sed -n 's/.*Build ID: \([0-9a-f]\{20,\}\).*/\1/p')
if [ -z "$build_id" ]; then
	error_log "skip: vmlinux has no build ID"
	test_skip
fi
info_log "vmlinux build ID: $build_id"

# --- Test JSON: histograms format matching perf report --data-type-json output ---
#
# The profile is a single object: "machine" carries the cacheline size the
# histograms were collected with and "dsos" has one entry per DSO, with its
# identity ("dso" path and "build_id" hex string, both nullable) and the
# types that had hits in it.
#
# Uses struct rb_node (a config-independent layout: __rb_parent_color @0,
# rb_right @8, rb_left @16, size 24) and struct list_head (next @0, prev @8)
# so the checks do not depend on CONFIG_MUTEX_SPIN_ON_OWNER / CONFIG_DEBUG_MUTEXES.
json_file=$(mktemp "$outdir/json.XXXXXX")
cat > "$json_file" << 'ENDJSON'
{
  "machine": { "hostname": "test", "cacheline_size": 64 },
  "dsos": [
    {
      "dso": null,
      "build_id": null,
      "types": [
        {
          "type": "struct rb_node",
          "size": 24,
          "histograms": [
            {
              "event": "cpu/mem-loads,ldlat=30/P",
              "total_samples": 80,
              "total_period": 800,
              "samples": [
                {"offset": 0, "nr_samples_load": 50, "period_load": 500, "nr_samples_store": 0, "period_store": 0},
                {"offset": 8, "nr_samples_load": 30, "period_load": 300, "nr_samples_store": 0, "period_store": 0},
                {"offset": 16, "nr_samples_load": 0, "period_load": 0, "nr_samples_store": 0, "period_store": 0}
              ]
            },
            {
              "event": "cpu/mem-stores/P",
              "total_samples": 20,
              "total_period": 200,
              "samples": [
                {"offset": 0, "nr_samples_load": 0, "period_load": 0, "nr_samples_store": 10, "period_store": 100},
                {"offset": 8, "nr_samples_load": 0, "period_load": 0, "nr_samples_store": 10, "period_store": 100}
              ]
            }
          ]
        },
        {
          "type": "struct list_head",
          "size": 16,
          "histograms": [
            {
              "event": "cpu/mem-loads,ldlat=30/P",
              "total_samples": 25,
              "total_period": 250,
              "samples": [
                {"offset": 0, "nr_samples_load": 7, "period_load": 70, "nr_samples_store": 0, "period_store": 0},
                {"offset": 8, "nr_samples_load": 18, "period_load": 180, "nr_samples_store": 0, "period_store": 0}
              ]
            }
          ]
        }
      ]
    }
  ]
}
ENDJSON

# --- Check 1: histograms profile loads and annotates struct members ---
output=$("$pahole_bin" -F btf --perf-data-type="$json_file" -C rb_node "$vmlinux" 2>/dev/null)
if [ $? -ne 0 ]; then
	error_log "FAIL: --perf-data-type failed to load"
	test_fail
fi

if [ -z "$output" ]; then
	error_log "FAIL: no output from --perf-data-type"
	test_fail
fi

if ! echo "$output" | grep -q "perf data-type profile"; then
	error_log "FAIL: perf data-type profile block not found in output"
	test_fail
fi
info_log "histograms profile loads and produces annotation block: ok"

# --- Check 2: reads and writes split correctly via per-direction counters ---
# __rb_parent_color at offset 0 gets 50 loads (nr_reads=50) and 10 stores (nr_writes=10)
if ! echo "$output" | grep "__rb_parent_color" | grep -Eq "nr_reads=50( |$)"; then
	error_log "FAIL: __rb_parent_color nr_reads=50 not found (50 load samples)"
	test_fail
fi
if ! echo "$output" | grep "__rb_parent_color" | grep -Eq "nr_writes=10( |$)"; then
	error_log "FAIL: __rb_parent_color nr_writes=10 not found (10 store samples)"
	test_fail
fi
# rb_right at offset 8 gets 30 (loads only)
if ! echo "$output" | grep "rb_right" | grep -Eq "nr_reads=30( |$)"; then
	error_log "FAIL: rb_right nr_reads=30 not found"
	test_fail
fi
info_log "reads and writes split correctly via per-direction counters: ok"

# --- Check 3: multi-type JSON: struct list_head also works ---
output_file=$("$pahole_bin" -F btf --perf-data-type="$json_file" -C list_head "$vmlinux" 2>/dev/null)
if [ $? -ne 0 ]; then
	error_log "FAIL: struct list_head annotation failed"
	test_fail
fi
if ! echo "$output_file" | grep -Eq "nr_reads=7( |$)"; then
	error_log "FAIL: struct list_head nr_reads=7 not found"
	test_fail
fi
info_log "multi-type JSON (struct list_head): ok"

# --- Check 4: zero-sample offsets are skipped ---
# rb_left at offset 16 has zero load/store counters -> should not show nr_reads or nr_writes
if echo "$output" | grep "rb_left" | grep -q "nr_reads="; then
	error_log "FAIL: rb_left should have no nr_reads (nr_samples=0)"
	test_fail
fi
info_log "zero-sample offsets skipped: ok"

# --- Check 5: no false-sharing flags from aggregate data ---
if echo "$output" | grep -q "FALSE SHARING"; then
	error_log "FAIL: aggregate data should not produce false-sharing flags"
	test_fail
fi
info_log "no false-sharing from aggregate data (needs CTF): ok"

# --- Check 6: missing file -> exit 1 ---
"$pahole_bin" -F btf --perf-data-type=/tmp/no-such-file.json -C rb_node "$vmlinux" > /dev/null 2>&1
if [ $? -eq 0 ]; then
	error_log "FAIL: missing file did not cause exit 1"
	test_fail
fi
info_log "missing file -> exit 1: ok"

# --- Check 7: empty directory -> exit 1 (CTF backend) ---
mkdir -p "$outdir/empty-dir"
"$pahole_bin" -F btf --perf-data-type="$outdir/empty-dir" -C rb_node "$vmlinux" > /dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
	error_log "FAIL: empty directory did not cause non-zero exit"
	test_fail
fi
info_log "empty directory -> exit $rc: ok"

# --- Check 8: malformed JSON -> exit 1 ---
bad_json=$(mktemp "$outdir/bad.XXXXXX")
echo "{not valid json" > "$bad_json"
"$pahole_bin" -F btf --perf-data-type="$bad_json" -C rb_node "$vmlinux" > /dev/null 2>&1
if [ $? -eq 0 ]; then
	error_log "FAIL: malformed JSON did not cause exit 1"
	test_fail
fi
info_log "malformed JSON -> exit 1: ok"

# --- Check 9: comment block closes with */ ---
if ! echo "$output" | grep -q '\*/'; then
	error_log "FAIL: annotation block does not close with */"
	test_fail
fi
info_log "comment block closes with */: ok"

# --- Check 10: duplicate type in the same DSO entry gets samples merged ---
dup_json=$(mktemp "$outdir/dup.XXXXXX")
cat > "$dup_json" << 'ENDJSON'
{
  "machine": { "cacheline_size": 64 },
  "dsos": [
    {
      "dso": null,
      "build_id": null,
      "types": [
        {
          "type": "struct rb_node",
          "histograms": [
            {
              "event": "cpu/mem-loads,ldlat=30/P",
              "samples": [
                {"offset": 0, "nr_samples_load": 50, "period_load": 500, "nr_samples_store": 0, "period_store": 0}
              ]
            }
          ]
        },
        {
          "type": "struct rb_node",
          "histograms": [
            {
              "event": "cpu/mem-loads,ldlat=30/P",
              "samples": [
                {"offset": 0, "nr_samples_load": 25, "period_load": 250, "nr_samples_store": 0, "period_store": 0}
              ]
            }
          ]
        }
      ]
    }
  ]
}
ENDJSON
dup_output=$("$pahole_bin" -F btf --perf-data-type="$dup_json" -C rb_node "$vmlinux" 2>/dev/null)
if [ $? -ne 0 ]; then
	error_log "FAIL: duplicate type JSON failed to load"
	test_fail
fi
# 50 + 25 = 75 merged samples
if ! echo "$dup_output" | grep -Eq "nr_reads=75( |$)"; then
	error_log "FAIL: duplicate type did not merge (expected nr_reads=75)"
	test_fail
fi
info_log "duplicate type merge (50+25=75): ok"

# --- Check 11: duplicate type with disagreeing size: separate entries ---
# Same (DSO, name) with different nonzero sizes are different types (perf
# emits one object per (DSO, type), but generic names like char[] share a
# spelling at different sizes).  No build IDs here, so both are unverified
# name+size matches and the class size selects the size-24 entry.
sizemismatch_json=$(mktemp "$outdir/sizemismatch.XXXXXX")
cat > "$sizemismatch_json" << 'ENDJSON'
{
  "machine": { "cacheline_size": 64 },
  "dsos": [
    {
      "dso": null,
      "build_id": null,
      "types": [
        {
          "type": "struct rb_node",
          "size": 24,
          "histograms": [
            {
              "event": "cpu/mem-loads,ldlat=30/P",
              "samples": [
                {"offset": 0, "nr_samples_load": 5, "period_load": 50, "nr_samples_store": 0, "period_store": 0}
              ]
            }
          ]
        },
        {
          "type": "struct rb_node",
          "size": 99,
          "histograms": [
            {
              "event": "cpu/mem-loads,ldlat=30/P",
              "samples": [
                {"offset": 0, "nr_samples_load": 4, "period_load": 40, "nr_samples_store": 0, "period_store": 0}
              ]
            }
          ]
        }
      ]
    }
  ]
}
ENDJSON
# The stderr warning shows the fallback path, and the old duplicate-merge
# warning must be gone.
sm_output=$("$pahole_bin" -F btf --perf-data-type="$sizemismatch_json" -C rb_node "$vmlinux" 2>&1)
if [ $? -ne 0 ]; then
	error_log "FAIL: size-mismatch JSON failed to load"
	test_fail
fi
if echo "$sm_output" | grep -q "duplicate entry size mismatch"; then
	error_log "FAIL: different sizes must be separate entries, not a warned merge"
	test_fail
fi
# The class size (24) selects the size-24 entry: 5 reads, not the 5+4=9 a
# merge would give.
if ! echo "$sm_output" | grep -Eq "nr_reads=5( |$)"; then
	error_log "FAIL: size-matching entry not selected (expected nr_reads=5)"
	test_fail
fi
if echo "$sm_output" | grep -Eq "nr_reads=9( |$)"; then
	error_log "FAIL: size-mismatched entry merged into the annotation (nr_reads=9)"
	test_fail
fi
info_log "duplicate type with disagreeing size: separate entries, size-matching one annotated: ok"

# --- Check 12: build ID mismatch -> error, no annotation for the type ---
bidmismatch_json=$(mktemp "$outdir/bidmismatch.XXXXXX")
cat > "$bidmismatch_json" << 'ENDJSON'
{
  "machine": { "cacheline_size": 64 },
  "dsos": [
    {
      "dso": "/tmp/other-kernel/vmlinux",
      "build_id": "ffffffffffffffffffffffffffffffffffffffff",
      "types": [
        {
          "type": "struct rb_node",
          "size": 24,
          "histograms": [
            {
              "event": "cpu/mem-loads,ldlat=30/P",
              "samples": [
                {"offset": 0, "nr_samples_load": 5, "period_load": 50, "nr_samples_store": 0, "period_store": 0}
              ]
            }
          ]
        }
      ]
    }
  ]
}
ENDJSON
bm_stdout=$("$pahole_bin" -F btf --perf-data-type="$bidmismatch_json" -C rb_node "$vmlinux" 2>"$outdir/bidmismatch.err")
if [ $? -ne 0 ]; then
	error_log "FAIL: build-ID mismatch should not fail the whole run (the error is per type)"
	test_fail
fi
if ! grep -q "profile build ID" "$outdir/bidmismatch.err" ||
   ! grep -q "skipping its annotation" "$outdir/bidmismatch.err"; then
	error_log "FAIL: build-ID mismatch did not error on stderr"
	test_fail
fi
if echo "$bm_stdout" | grep -q "perf data-type profile"; then
	error_log "FAIL: mismatched type was annotated anyway"
	test_fail
fi
info_log "build ID mismatch: error on stderr, no annotation: ok"

# --- Check 13: matching build ID -> annotation, no warnings ---
verified_json=$(mktemp "$outdir/verified.XXXXXX")
cat > "$verified_json" << ENDJSON
{
  "machine": { "cacheline_size": 64 },
  "dsos": [
    {
      "dso": "/tmp/this-kernel/vmlinux",
      "build_id": "$build_id",
      "types": [
        {
          "type": "struct rb_node",
          "size": 24,
          "histograms": [
            {
              "event": "cpu/mem-loads,ldlat=30/P",
              "samples": [
                {"offset": 0, "nr_samples_load": 7, "period_load": 70, "nr_samples_store": 0, "period_store": 0}
              ]
            }
          ]
        }
      ]
    }
  ]
}
ENDJSON
v_stdout=$("$pahole_bin" -F btf --perf-data-type="$verified_json" -C rb_node "$vmlinux" 2>"$outdir/verified.err")
if [ $? -ne 0 ]; then
	error_log "FAIL: verified JSON failed to load"
	test_fail
fi
if ! echo "$v_stdout" | grep -q "perf data-type profile"; then
	error_log "FAIL: verified type was not annotated"
	test_fail
fi
if ! echo "$v_stdout" | grep -Eq "nr_reads=7( |$)"; then
	error_log "FAIL: verified annotation counters wrong (expected nr_reads=7)"
	test_fail
fi
if [ -s "$outdir/verified.err" ]; then
	error_log "FAIL: verified run should be warning-free: $(cat "$outdir/verified.err")"
	test_fail
fi
info_log "matching build ID: annotated with no warnings: ok"

# --- Check 14: missing build ID -> unverified warning, still annotated ---
nobid_json=$(mktemp "$outdir/nobid.XXXXXX")
cat > "$nobid_json" << 'ENDJSON'
{
  "machine": { "cacheline_size": 64 },
  "dsos": [
    {
      "dso": "/tmp/this-kernel/vmlinux",
      "build_id": null,
      "types": [
        {
          "type": "struct rb_node",
          "size": 24,
          "histograms": [
            {
              "event": "cpu/mem-loads,ldlat=30/P",
              "samples": [
                {"offset": 0, "nr_samples_load": 7, "period_load": 70, "nr_samples_store": 0, "period_store": 0}
              ]
            }
          ]
        }
      ]
    }
  ]
}
ENDJSON
nb_stdout=$("$pahole_bin" -F btf --perf-data-type="$nobid_json" -C rb_node "$vmlinux" 2>"$outdir/nobid.err")
if [ $? -ne 0 ]; then
	error_log "FAIL: no-build-ID JSON failed to load"
	test_fail
fi
if ! echo "$nb_stdout" | grep -q "perf data-type profile"; then
	error_log "FAIL: unverified type was not annotated"
	test_fail
fi
if ! grep -q "unverified" "$outdir/nobid.err"; then
	error_log "FAIL: missing build ID did not warn (unverified)"
	test_fail
fi
info_log "missing build ID: unverified warning, still annotated: ok"

# --- Check 15: same type name from two DSOs: matching build ID wins ---
multidso_json=$(mktemp "$outdir/multidso.XXXXXX")
cat > "$multidso_json" << ENDJSON
{
  "machine": { "cacheline_size": 64 },
  "dsos": [
    {
      "dso": "/tmp/other-kernel/vmlinux",
      "build_id": "ffffffffffffffffffffffffffffffffffffffff",
      "types": [
        {
          "type": "struct rb_node",
          "size": 24,
          "histograms": [
            {
              "event": "cpu/mem-loads,ldlat=30/P",
              "samples": [
                {"offset": 0, "nr_samples_load": 100, "period_load": 1000, "nr_samples_store": 0, "period_store": 0}
              ]
            }
          ]
        }
      ]
    },
    {
      "dso": "/tmp/this-kernel/vmlinux",
      "build_id": "$build_id",
      "types": [
        {
          "type": "struct rb_node",
          "size": 24,
          "histograms": [
            {
              "event": "cpu/mem-loads,ldlat=30/P",
              "samples": [
                {"offset": 0, "nr_samples_load": 7, "period_load": 70, "nr_samples_store": 0, "period_store": 0}
              ]
            }
          ]
        }
      ]
    }
  ]
}
ENDJSON
md_stdout=$("$pahole_bin" -F btf --perf-data-type="$multidso_json" -C rb_node "$vmlinux" 2>"$outdir/multidso.err")
if [ $? -ne 0 ]; then
	error_log "FAIL: multi-DSO JSON failed to load"
	test_fail
fi
if ! echo "$md_stdout" | grep -Eq "nr_reads=7( |$)"; then
	error_log "FAIL: matching-DSO entry not selected (expected nr_reads=7)"
	test_fail
fi
if echo "$md_stdout" | grep -Eq "nr_reads=100( |$)"; then
	error_log "FAIL: mismatching-DSO entry annotated (nr_reads=100)"
	test_fail
fi
if grep -q "profile build ID" "$outdir/multidso.err" ||
   grep -q "unverified" "$outdir/multidso.err"; then
	error_log "FAIL: multi-DSO selection should be verified and silent: $(cat "$outdir/multidso.err")"
	test_fail
fi
info_log "multiple DSOs with the same type name: matching build ID wins: ok"

# --- Check 16: default pretty prints just the structs with profile hits ---
# Full-file run (no -C): only the structs in the profile that had hits are
# printed, so a big vmlinux doesn't bury the interesting ones.
flt_output=$("$pahole_bin" -F btf --perf-data-type="$json_file" "$vmlinux" 2>/dev/null)
if [ $? -ne 0 ]; then
	error_log "FAIL: full-file run with --perf-data-type failed"
	test_fail
fi
for t in "^struct rb_node {" "^struct list_head {"; do
	if ! echo "$flt_output" | grep -q "$t"; then
		error_log "FAIL: profiled type missing from default output: $t"
		test_fail
	fi
done
# task_struct is in any vmlinux and has no hits in this profile.
if echo "$flt_output" | grep -q '^struct task_struct {'; then
	error_log "FAIL: struct task_struct printed without profile hits"
	test_fail
fi
if ! echo "$flt_output" | grep -q "perf data-type profile"; then
	error_log "FAIL: printed structs lost their annotation blocks"
	test_fail
fi
info_log "default pretty prints just the structs with profile hits: ok"

# --- Check 17: --perf-data-type-show-all prints all the structs again ---
all_output=$("$pahole_bin" -F btf --perf-data-type="$json_file" --perf-data-type-show-all "$vmlinux" 2>/dev/null)
if [ $? -ne 0 ]; then
	error_log "FAIL: --perf-data-type-show-all run failed"
	test_fail
fi
if ! echo "$all_output" | grep -q '^struct task_struct {'; then
	error_log "FAIL: --perf-data-type-show-all did not print non-profiled structs"
	test_fail
fi
if ! echo "$all_output" | grep -q "perf data-type profile"; then
	error_log "FAIL: --perf-data-type-show-all lost the annotation blocks"
	test_fail
fi
info_log "--perf-data-type-show-all prints all the structs, annotated: ok"

# --- Check 18: unions with hits get the annotation block too ---
# A compiled fixture: a union that exists in every vmlinux is hard to pin
# down, the layout of a kernel union depends on the config.  All the members
# of a union sit at offset 0 spanning the whole union, so an offset matches
# every member and the smallest one is taken as the most specific match for
# the counts.
CC=${CC:-gcc}
if command -v "${CC%% *}" > /dev/null 2>&1; then
	union_src=$(make_tmpsrc)
	union_obj=$(make_tmpobj)
	cat > "$union_src" << 'ENDSRC'
union u_hot {
	long  l;
	int   i;
	short s;
};
union u_hot *refu(void) { static union u_hot u; return &u; }
ENDSRC
	if $CC -g -O0 -c "$union_src" -o "$union_obj" 2> "$outdir/cc.log"; then
		union_json=$(mktemp "$outdir/union.XXXXXX")
		cat > "$union_json" << 'ENDJSON'
{
  "machine": { "cacheline_size": 64 },
  "dsos": [
    { "dso": null, "build_id": null,
      "types": [
        {"type": "union u_hot",
         "histograms": [{"event": "cpu/mem-loads/P", "total_samples": 42, "total_period": 420,
           "samples": [
             {"offset": 0, "nr_samples_load": 42, "period_load": 420, "nr_samples_store": 0, "period_store": 0}]}]}
      ] }
  ]
}
ENDJSON
		u_output=$("$pahole_bin" -F dwarf --perf-data-type="$union_json" -C u_hot "$union_obj" 2>/dev/null)
		if [ $? -ne 0 ]; then
			error_log "FAIL: union annotation run failed"
			test_fail
		fi
		if ! echo "$u_output" | grep -q "^union u_hot {"; then
			error_log "FAIL: union with hits was not printed"
			test_fail
		fi
		if ! echo "$u_output" | grep -q "perf data-type profile"; then
			error_log "FAIL: union with hits printed without the annotation block"
			test_fail
		fi
		# The short int (2 bytes) is the most specific offset-0 member.
		if ! echo "$u_output" | grep -Eq "\+0 +s +sz=2 +nr_reads=42( |$)"; then
			error_log "FAIL: union counts not on the smallest offset-0 member"
			test_fail
		fi
		info_log "union with hits gets the annotation block: ok"
	else
		error_log "skip: union fixture compile failed:"
		info_log "   $(cat "$outdir/cc.log")"
		info_log "   union annotation check skipped: ok"
	fi
else
	info_log "   no compiler, union annotation check skipped: ok"
fi

# --- Check 19: JSON whose top level is not an object -> exit 1 ---
# A file that parses as JSON but is not the {"machine", "dsos"} object must
# fail the load like malformed JSON does, else with the default filter it
# would load as an empty profile, print nothing and exit 0.  A top level
# array is what perf emitted before the "dsos" grouping, hence the hint.
obj_json=$(mktemp "$outdir/notobject.XXXXXX")
echo '[{"type": "struct rb_node", "cacheline_size": 64}]' > "$obj_json"
"$pahole_bin" -F btf --perf-data-type="$obj_json" -C rb_node "$vmlinux" > /dev/null 2> "$outdir/notobject.err"
if [ $? -eq 0 ]; then
	error_log "FAIL: non-object JSON did not cause exit 1"
	test_fail
fi
if ! grep -q "not an object" "$outdir/notobject.err"; then
	error_log "FAIL: non-object JSON did not say why on stderr"
	test_fail
fi
info_log "non-object JSON -> exit 1: ok"

# --- Check 19b: empty profile -> exit 1 ---
# An object with no types carrying samples would load as an empty profile
# and, with the default filter, print nothing and exit 0: fail loudly
# instead, like a non-object top level.
empty_json=$(mktemp "$outdir/empty.XXXXXX")
echo '{}' > "$empty_json"
"$pahole_bin" -F btf --perf-data-type="$empty_json" -C rb_node "$vmlinux" > /dev/null 2> "$outdir/empty.err"
if [ $? -eq 0 ]; then
	error_log "FAIL: empty JSON did not cause exit 1"
	test_fail
fi
if ! grep -q "empty profile" "$outdir/empty.err"; then
	error_log "FAIL: empty JSON did not say why on stderr"
	test_fail
fi
empty_dsos_json=$(mktemp "$outdir/emptydsos.XXXXXX")
echo '{"machine": {"cacheline_size": 64}, "dsos": []}' > "$empty_dsos_json"
"$pahole_bin" -F btf --perf-data-type="$empty_dsos_json" "$vmlinux" > /dev/null 2> "$outdir/emptydsos.err"
if [ $? -eq 0 ]; then
	error_log "FAIL: empty dsos JSON did not cause exit 1"
	test_fail
fi
if ! grep -q "empty profile" "$outdir/emptydsos.err"; then
	error_log "FAIL: empty dsos JSON did not say why on stderr"
	test_fail
fi
info_log "empty profile -> exit 1: ok"

# --- Check 19c: well-formed JSON with the wrong shape -> exit 1 ---
# jsmn parses all of these, but the walkers used to read past the token
# array when a value was not the object/array the documented shape asks
# for (a heap OOB read, now closed by bounding tok_end() with the token
# count and checking the container types); they must fail cleanly, like
# any other malformed document.
for bad_shape in \
	'{"machine":{"cacheline_size":64},"dsos":[["dso"]]}' \
	'{"machine":{},"dsos":[{"types":[["type"]]}]}' \
	'{"dsos":[{"types":[{"type":"struct rb_node","histograms":[["samples"]]}]}]}'; do
	shape_json=$(mktemp "$outdir/shape.XXXXXX")
	echo "$bad_shape" > "$shape_json"
	"$pahole_bin" -F btf --perf-data-type="$shape_json" -C rb_node "$vmlinux" > /dev/null 2> "$outdir/shape.err"
	if [ $? -eq 0 ]; then
		error_log "FAIL: wrong-shape JSON did not cause exit 1: $bad_shape"
		test_fail
	fi
	if ! grep -q "unexpected structure" "$outdir/shape.err"; then
		error_log "FAIL: wrong-shape JSON did not say why on stderr: $bad_shape"
		test_fail
	fi
done
info_log "wrong-shape JSON -> exit 1: ok"

# --- Check 20: --quiet suppresses the perf_dt annotations and their warnings ---
# With the stats comments suppressed nothing perf_dt prints, so the profile
# gathering is skipped entirely and its warnings (unverified build ID,
# unmatched offsets) stay quiet as well.
"$pahole_bin" -F btf -q --perf-data-type="$json_file" -C rb_node "$vmlinux" > "$outdir/quiet.out" 2> "$outdir/quiet.err"
if [ $? -ne 0 ]; then
	error_log "FAIL: --quiet run with profile failed"
	test_fail
fi
if [ -s "$outdir/quiet.err" ]; then
	error_log "FAIL: --quiet run printed to stderr: $(cat "$outdir/quiet.err")"
	test_fail
fi
if grep -q "perf data-type profile" "$outdir/quiet.out"; then
	error_log "FAIL: --quiet run printed the perf_dt annotation block"
	test_fail
fi
info_log "--quiet keeps the perf_dt annotations and warnings quiet: ok"
# --- Check 21: access counts go inline, in the member's offset comment ---
# The summary block at the end of the struct is compact, but a task_struct is
# 400+ lines long: by the time one gets to it, the members that were hit are
# long scrolled past.  So the counts ride along in the offset comment, in the
# same comment (not a second one), leaving the offsets where they always were.
inline_output=$("$pahole_bin" -F btf --perf-data-type="$json_file" -C rb_node "$vmlinux" 2>/dev/null)
if [ $? -ne 0 ]; then
	error_log "FAIL: inline annotation run failed"
	test_fail
fi
# __rb_parent_color: 50 loads + 10 stores of the 100 samples in the type.
if ! echo "$inline_output" | grep "__rb_parent_color" |
   grep -qE "/\* +0 +8 \| +60\.0% R:50 W:10 \*/"; then
	error_log "FAIL: inline annotation for __rb_parent_color: $(echo "$inline_output" | grep __rb_parent_color)"
	test_fail
fi
if ! echo "$inline_output" | grep "rb_right" |
   grep -qE "/\* +8 +8 \| +40\.0% R:30 W:10 \*/"; then
	error_log "FAIL: inline annotation for rb_right: $(echo "$inline_output" | grep rb_right)"
	test_fail
fi
info_log "access counts annotated inline in the member offset comments: ok"

# --- Check 22: members with no samples keep a plain offset comment ---
if ! echo "$inline_output" | grep "rb_left" | grep -qE "/\* +16 +8 \*/"; then
	error_log "FAIL: member without samples: $(echo "$inline_output" | grep rb_left)"
	test_fail
fi
info_log "members with no samples keep a plain offset comment: ok"

# --- Check 23: --color=always marks hot fields red, warm ones green ---
# The heat bands are a share of the accesses to the type, using the same
# thresholds perf colours hot entries with in 'perf report'/'perf annotate'
# (MIN_RED 5.0, MIN_GREEN 0.5): 6000/6060 = 99.0% is hot, 60/6060 = 1.0% is
# warm, rb_left took no samples at all and is left alone.
heat_json=$(mktemp "$outdir/heat.XXXXXX")
cat > "$heat_json" << 'ENDJSON'
{
  "machine": { "cacheline_size": 64 },
  "dsos": [
    {
      "dso": null,
      "build_id": null,
      "types": [
        {
          "type": "struct rb_node",
          "size": 24,
          "histograms": [
            {
              "event": "cpu/mem-loads,ldlat=30/P",
              "samples": [
                {"offset": 0, "nr_samples_load": 6000, "period_load": 60000, "nr_samples_store": 0, "period_store": 0},
                {"offset": 8, "nr_samples_load": 60, "period_load": 600, "nr_samples_store": 0, "period_store": 0},
                {"offset": 16, "nr_samples_load": 0, "period_load": 0, "nr_samples_store": 0, "period_store": 0}
              ]
            }
          ]
        }
      ]
    }
  ]
}
ENDJSON
red=$(printf '\033[31m')
green=$(printf '\033[32m')
esc=$(printf '\033')
color_output=$("$pahole_bin" -F btf --perf-data-type="$heat_json" --color=always -C rb_node "$vmlinux" 2>/dev/null)
if [ $? -ne 0 ]; then
	error_log "FAIL: --color=always run failed"
	test_fail
fi
hot_line=$(echo "$color_output" | grep "__rb_parent_color")
if ! echo "$hot_line" | grep -qF "$red" || ! echo "$hot_line" | grep -qF "99.0% R:6.0K"; then
	error_log "FAIL: hottest member not marked red: $hot_line"
	test_fail
fi
warm_line=$(echo "$color_output" | grep "rb_right")
if ! echo "$warm_line" | grep -qF "$green" || ! echo "$warm_line" | grep -qF "1.0% R:60"; then
	error_log "FAIL: warm member not marked green: $warm_line"
	test_fail
fi
cold_line=$(echo "$color_output" | grep "rb_left")
if echo "$cold_line" | grep -qF "$esc"; then
	error_log "FAIL: member without samples is coloured: $cold_line"
	test_fail
fi
info_log "--color=always marks hot fields red and warm ones green: ok"

# --- Check 24: no colours by default here (not a tty) nor with --color=never ---
if echo "$inline_output" | grep -qF "$esc"; then
	error_log "FAIL: colour emitted when not printing to a terminal"
	test_fail
fi
never_output=$("$pahole_bin" -F btf --perf-data-type="$heat_json" --color=never -C rb_node "$vmlinux" 2>/dev/null)
if [ $? -ne 0 ]; then
	error_log "FAIL: --color=never run failed"
	test_fail
fi
if echo "$never_output" | grep -qF "$esc"; then
	error_log "FAIL: --color=never emitted colours"
	test_fail
fi
# The counts are there, just not coloured.
if ! echo "$never_output" | grep "rb_right" | grep -qF "1.0% R:60"; then
	error_log "FAIL: --color=never lost the inline annotation: $(echo "$never_output" | grep rb_right)"
	test_fail
fi
info_log "no colours by default when not a tty, nor with --color=never: ok"

# --- Check 25: an explicit --color=always wins over NO_COLOR ---
nocolor_output=$(NO_COLOR=1 "$pahole_bin" -F btf --perf-data-type="$heat_json" --color=always -C rb_node "$vmlinux" 2>/dev/null)
if ! echo "$nocolor_output" | grep "__rb_parent_color" | grep -qF "$red"; then
	error_log "FAIL: NO_COLOR overrode an explicit --color=always"
	test_fail
fi
info_log "--color=always wins over NO_COLOR: ok"

# --- Check 26: the summary block is coloured and spells out the heat bands ---
# The block is the compact view, where all the members are listed: colour its
# entries with the same bands as the inline annotations, and say in its header
# what those bands are, so that the colours can be interpreted without having
# to know about perf's thresholds.
block_line=$(echo "$color_output" | grep "+0 ")
if ! echo "$block_line" | grep -qF "$red" || ! echo "$block_line" | grep -qF "nr_reads=6000"; then
	error_log "FAIL: hot entry in the summary block not marked red: $block_line"
	test_fail
fi
if ! echo "$color_output" | grep "perf data-type profile" | grep -qF "heat: hot >= 5.0%, warm > 0.5%"; then
	error_log "FAIL: summary block header does not spell out the heat bands"
	test_fail
fi
# Without colours the entries keep the exact same alignment as before.
if ! echo "$never_output" | grep -qE "^\s+\+0 +__rb_parent_color +sz=8 +nr_reads=6000"; then
	error_log "FAIL: summary block entry alignment changed: $(echo "$never_output" | grep '+0 ')"
	test_fail
fi
info_log "summary block coloured, with the heat bands in its header: ok"

# --- Check 27: the summary block prints only the cachelines that had hits ---
# A task_struct spans ~160 cachelines and only a handful see traffic: lines
# where no member was hit are noise and get dropped, but the idle members of
# a printed line stay -- they contextualise the hot field and show what sits
# unused next to it.  Hit offset 0 (struct thread_info, first member of
# cacheline 0); any member it covers works, the size is read from this very
# vmlinux so the name+size match goes through.
ts_size=$("$pahole_bin" -F btf -C task_struct "$vmlinux" 2>/dev/null |
	  sed -n 's|.*/\* size: \([0-9]*\),.*|\1|p')
if [ -z "$ts_size" ]; then
	error_log "FAIL: could not determine struct task_struct size"
	test_fail
fi
cl_json=$(mktemp "$outdir/cachelines.XXXXXX")
cat > "$cl_json" << ENDJSON
{
  "machine": { "cacheline_size": 64 },
  "dsos": [
    {
      "dso": "/tmp/this-kernel/vmlinux",
      "build_id": "$build_id",
      "types": [
        {
          "type": "struct task_struct",
          "size": $ts_size,
          "histograms": [
            {
              "event": "cpu/mem-loads,ldlat=30/P",
              "samples": [
                {"offset": 0, "nr_samples_load": 90, "period_load": 900, "nr_samples_store": 0, "period_store": 0}
              ]
            }
          ]
        }
      ]
    }
  ]
}
ENDJSON
cl_stdout=$("$pahole_bin" -F btf --perf-data-type="$cl_json" -C task_struct "$vmlinux" 2>"$outdir/cachelines.err")
if [ $? -ne 0 ]; then
	error_log "FAIL: cacheline profile JSON failed to load"
	test_fail
fi
if [ -s "$outdir/cachelines.err" ]; then
	error_log "FAIL: verified run should be warning-free: $(cat "$outdir/cachelines.err")"
	test_fail
fi
if ! echo "$cl_stdout" | grep -q "cacheline 0 \[0-63\]:"; then
	error_log "FAIL: cacheline 0, the one with hits, not in the summary block"
	test_fail
fi
# task_struct is far bigger than one cacheline, so the block must carry
# only the one with hits.
if [ "$ts_size" -le 64 ]; then
	error_log "FAIL: vmlinux under test has a <= 64 byte task_struct, nothing to check"
	test_fail
fi
cl_count=$(echo "$cl_stdout" | sed -n '/\/\* perf data-type profile/,/\*\//p' |
	   grep -c "cacheline [0-9]* \[")
if [ "$cl_count" -ne 1 ]; then
	error_log "FAIL: summary block prints $cl_count cachelines, expected only the 1 hit one"
	test_fail
fi
# Members past the hit one, on the same (printed) cacheline, must stay.
if ! echo "$cl_stdout" | sed -n '/cacheline 0 \[0-63\]:/,$p' |
   grep -qE "^[[:space:]]+\+([1-5][0-9])[[:space:]]+[a-z_]+[[:space:]]+sz="; then
	error_log "FAIL: idle members of the hit cacheline were dropped"
	test_fail
fi
info_log "summary block prints only the cachelines that had hits: ok"

# --- Check 20b: --quiet keeps the build-ID mismatch quiet as well ---
# The mismatch error goes through the print filter in a full-file run and
# through the annotation path with an explicit -C: both stay quiet.
"$pahole_bin" -F btf -q --perf-data-type="$bidmismatch_json" -C rb_node "$vmlinux" > /dev/null 2> "$outdir/quiet-bid.err"
if [ $? -ne 0 ]; then
	error_log "FAIL: --quiet mismatch run with -C failed"
	test_fail
fi
if [ -s "$outdir/quiet-bid.err" ]; then
	error_log "FAIL: --quiet mismatch run with -C printed to stderr: $(cat "$outdir/quiet-bid.err")"
	test_fail
fi
"$pahole_bin" -F btf -q --perf-data-type="$bidmismatch_json" "$vmlinux" > /dev/null 2> "$outdir/quiet-bid-full.err"
if [ $? -ne 0 ]; then
	error_log "FAIL: --quiet mismatch full-file run failed"
	test_fail
fi
if [ -s "$outdir/quiet-bid-full.err" ]; then
	error_log "FAIL: --quiet mismatch full-file run printed to stderr: $(cat "$outdir/quiet-bid-full.err")"
	test_fail
fi
info_log "--quiet keeps the build-ID mismatch quiet: ok"


test_pass
