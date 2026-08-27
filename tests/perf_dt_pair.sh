#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test the pair of perf data-type profiling producers and the deliverables
# pahole produces from both.
#
# perf is the generator: one 'perf mem record' of a compiled fixture with a
# known struct layout, converted twice from the same perf.data:
#
#   perf report -s type --data-type-json  (the aggregate JSON producer)
#   perf data convert --to-ctf            (the per-sample CTF producer)
#
# and pahole consumes both with --perf-data-type (a file = JSON, a
# directory = CTF).  One perf.data, two producers, two consumers, one
# consistent view: this cross-validates the whole chain, perf's data-type
# histogram aggregation, its JSON producer, pahole's JSON consumer, perf's
# CTF producer and pahole's CTF consumer.  A discrepancy between the two
# deliverables means one of the five stages is wrong, and the fixtures of
# tests/perf_dt.sh pin down which side drifts.
#
# The CTF producer needs 'perf data convert --data-type', the perf-side
# option that resolves the data type of every memory sample into the
# trace (the fields pahole looks for: perf_sample_type,
# perf_sample_type_offset, perf_sample_is_write, perf_sample_cpu,
# perf_sample_addr, perf_sample_dso_id, plus the perf_dso_info side
# event).  The test asks perf whether it has that option and covers both
# sides: with it, the CTF deliverable must match the JSON one; without it
# -- or on a trace converted without the option -- pahole must fail loudly
# and name the option that is missing, instead of silently annotating
# nothing.
#
# Tests:
#  1. The recorded JSON carries the fixture's DSO identity (dso path +
#     build ID, cross-checked with readelf), and the build ID is verified
#     against the analyzed binary: pahole annotates with no warnings.
#  2. The JSON deliverable: the fixture struct is annotated, the member
#     written in the loop has nr_writes > 0, the member never touched
#     stays in the block as idle context without counters.
#  3. A trace converted without --data-type carries no perf_sample_type
#     field at all: the load fails loudly, exit != 0, naming the option.
#  4. The CTF deliverable (a perf with --data-type): the same annotation
#     view as the JSON deliverable for the fixture struct.
#
# Recording needs memory-event PMU access, which is not always available
# (e.g. per-thread mode is not supported on AMD IBS, system-wide mode is
# blocked by perf_event_paranoid): the test skips then, like perf's own
# tests/shell/data_type_json.sh.

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT
cleanup() {
	rm -rf "${outdir}"
}

title_log "perf data-type profiling producer pair: JSON + CTF."

# pahole itself: test_lib.sh puts ../build in PATH, the fixture checks
# below need the just-built one to test new code.
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

# perf is the generator of both inputs; python3 validates the JSON.
if ! command -v perf > /dev/null 2>&1; then
	error_log "skip: perf not found"
	test_skip
fi
if ! command -v python3 > /dev/null 2>&1; then
	error_log "skip: python3 not found"
	test_skip
fi

# The data-type resolution perf does needs DWARF support.
if ! perf check feature -q dwarf; then
	error_log "skip: perf has no DWARF support"
	test_skip
fi

# The memory events are what perf mem record samples.
if perf mem record -o /dev/null -- true 2>&1 |
   grep -q "failed: no PMU supports the memory events"; then
	error_log "skip: no PMU supports the memory events"
	test_skip
fi

# The CTF half needs the converter's babeltrace writer; without it the
# JSON half still runs.
have_ctf_writer=true
if ! perf check feature -q babeltrace2-ctf-writer; then
	have_ctf_writer=false
	info_log "   perf has no babeltrace2-ctf-writer: the CTF half is skipped"
fi

# The fixture: a struct whose hot member is written in a loop and whose
# idle member is never touched, so the deliverable's counters are
# predictable per member: stores are always sampled, and the idle member
# must never get any.  It is compiled with DWARF and a build ID, so pahole
# resolves the members and verifies the profile's build ID against it.
CC=${CC:-gcc}
if ! command -v "${CC%% *}" > /dev/null 2>&1; then
	error_log "skip: ${CC%% *} not found, cannot build the fixture"
	test_skip
fi
fixture_src=$(make_tmpsrc)
fixture="$outdir/dt_fixture"
cat > "$fixture_src" << 'ENDSRC'
struct hot_struct {
	int	hot_written;	/* written in the loop below */
	int	idle;		/* never touched: no counters */
};
static volatile struct hot_struct hs;
int main(void)
{
	for (long i = 0; i < 500000000L; i++)
		hs.hot_written = (int)i;
	return 0;
}
ENDSRC
if ! $CC -g -O0 -Wl,--build-id -o "$fixture" "$fixture_src" 2> "$outdir/cc.log"; then
	error_log "skip: fixture compile failed:"
	info_log "   $(cat "$outdir/cc.log")"
	test_skip
fi

# The build ID the profile must carry for the fixture's DSO: the ELF note
# perf read when recording it, the same one pahole verifies at annotation
# time.
if ! command -v readelf > /dev/null 2>&1; then
	error_log "skip: readelf not found"
	test_skip
fi
fixture_bid=$(readelf -n "$fixture" 2>/dev/null |
	      sed -n 's/.*Build ID: \([0-9a-f]\{20,\}\).*/\1/p')
if [ -z "$fixture_bid" ]; then
	error_log "skip: fixture has no build ID"
	test_skip
fi

# Record once, with --sample-cpu so the per-sample CPU pahole's CTF backend
# needs is meaningful (perf mem record does not request it by default
# yet).  Per-thread mode first; on PMUs where that is not supported
# (e.g. AMD IBS) system-wide is the fallback, when perf_event_paranoid
# allows it.
perfdata="$outdir/perf.data"
if ! perf mem record --sample-cpu -o "$perfdata" -- "$fixture" > /dev/null 2>&1 &&
   ! perf mem record -a --sample-cpu -o "$perfdata" -- "$fixture" > /dev/null 2>&1; then
	error_log "skip: perf mem record failed (no memory-event access for this workload)"
	test_skip
fi

# --- The JSON producer: perf report -s type --data-type-json ---
json_profile="$outdir/profile.json"
if ! perf report -i "$perfdata" -s type --data-type-json="$json_profile" > /dev/null 2>&1; then
	error_log "FAIL: perf report --data-type-json failed"
	test_fail
fi
if ! python3 -m json.tool "$json_profile" > /dev/null 2>&1; then
	error_log "FAIL: the JSON profile is not valid JSON"
	test_fail
fi

# --- Check 1: the profile carries the fixture's DSO identity ---
# The dso/build_id identity fields are what lets pahole find the right
# DWARF and verify it is the binary that was profiled: the fixture's
# entry must carry the path perf recorded and the ELF note's build ID.
if ! python3 - "$json_profile" "$fixture" "$fixture_bid" << 'ENDPY'
import json, sys

profile = json.load(open(sys.argv[1]))
fixture = sys.argv[2]
bid = sys.argv[3]

for dso in profile["dsos"]:
    if dso["dso"] == fixture and dso["build_id"] == bid:
        sys.exit(0)
sys.exit("no DSO entry with the fixture path and its build ID")
ENDPY
then
	error_log "FAIL: the JSON profile has no verified entry for the fixture DSO"
	test_fail
fi
info_log "the JSON profile carries the fixture's dso path and build ID: ok"

# --- Check 2: the JSON deliverable ---
# pahole consumes the aggregate JSON: hot_written (stored every loop
# iteration, stores are always sampled) must carry samples, idle must stay
# without counters.  The build ID matches the fixture, so the annotation
# is verified: stderr must be empty, no "unverified" fallback.
json_stdout=$("$pahole_bin" -F dwarf --perf-data-type="$json_profile" -C hot_struct "$fixture" 2> "$outdir/json.err")
if [ $? -ne 0 ]; then
	error_log "FAIL: pahole failed on the JSON deliverable"
	test_fail
fi
if ! echo "$json_stdout" | grep -q "perf data-type profile"; then
	error_log "FAIL: the fixture struct was not annotated from the JSON profile"
	test_fail
fi
if ! echo "$json_stdout" | grep "hot_written" | grep -Eq "nr_writes=[1-9]"; then
	error_log "FAIL: hot_written has no stores in the JSON deliverable: $(echo "$json_stdout" | grep hot_written)"
	test_fail
fi
if echo "$json_stdout" | grep "idle" | grep -q "nr_"; then
	error_log "FAIL: the idle member got counters in the JSON deliverable"
	test_fail
fi
if [ -s "$outdir/json.err" ]; then
	error_log "FAIL: verified annotation printed to stderr: $(cat "$outdir/json.err")"
	test_fail
fi
info_log "the JSON deliverable annotates the fixture with the right counters: ok"

# --- The CTF producer: perf data convert --to-ctf ---
if [ "$have_ctf_writer" = true ]; then
	# Does this perf resolve data types into the trace?  The option is
	# what makes the converter emit the perf_sample_* fields pahole reads.
	have_dt_convert=false
	if perf data convert -h 2>&1 | grep -q -- "--data-type"; then
		have_dt_convert=true
	else
		info_log "   perf data convert has no --data-type: the CTF half asserts the loud failure only"
	fi

	ctf_dir="$outdir/ctf.dir"
	dt_opt=""
	if [ "$have_dt_convert" = true ]; then
		dt_opt="--data-type"
	fi
	if ! perf data convert --to-ctf "$ctf_dir" $dt_opt --force -i "$perfdata" > /dev/null 2>&1; then
		error_log "FAIL: perf data convert --to-ctf $dt_opt failed"
		test_fail
	fi
	if [ ! -f "$ctf_dir/metadata" ]; then
		error_log "FAIL: the converted trace has no metadata"
		test_fail
	fi

	# pahole's CTF consumer needs the babeltrace2 library too.
	ctf_stdout=$("$pahole_bin" -F dwarf --perf-data-type="$ctf_dir" -C hot_struct "$fixture" 2> "$outdir/ctf.err")
	ctf_rc=$?

	if grep -q "built without libbabeltrace2" "$outdir/ctf.err"; then
		info_log "   pahole built without libbabeltrace2: the CTF deliverable check is skipped: ok"
	elif [ "$have_dt_convert" != true ]; then
		# --- Check 3: a trace without the data-type fields fails loudly ---
		# This perf's converter emits the raw sample fields only, and
		# pahole refuses to silently annotate nothing.
		if [ "$ctf_rc" -eq 0 ]; then
			error_log "FAIL: the data-type-less CTF trace did not fail the load"
			test_fail
		fi
		if ! grep -q "has no perf_sample_type fields" "$outdir/ctf.err" ||
		   ! grep -q -- "--data-type" "$outdir/ctf.err"; then
			error_log "FAIL: the data-type-less CTF trace did not say why: $(cat "$outdir/ctf.err")"
			test_fail
		fi
		info_log "CTF from a perf without --data-type fails loudly, naming the option: ok"
	else
		# --- Check 3: a trace converted without --data-type fails loudly ---
		# Even with a perf that can resolve data types, a trace
		# converted without the option carries no perf_sample_type
		# field at all: the load must fail and say which option is
		# missing, not silently annotate nothing.
		plain_dir="$outdir/ctf-plain.dir"
		if perf data convert --to-ctf "$plain_dir" --force -i "$perfdata" > /dev/null 2>&1; then
			"$pahole_bin" -F dwarf --perf-data-type="$plain_dir" -C hot_struct "$fixture" > /dev/null 2> "$outdir/ctf-plain.err"
			plain_rc=$?
			if [ "$plain_rc" -eq 0 ]; then
				error_log "FAIL: the trace converted without --data-type did not fail the load"
				test_fail
			fi
			if ! grep -q "has no perf_sample_type fields" "$outdir/ctf-plain.err" ||
			   ! grep -q -- "--data-type" "$outdir/ctf-plain.err"; then
				error_log "FAIL: the trace converted without --data-type did not say why: $(cat "$outdir/ctf-plain.err")"
				test_fail
			fi
			info_log "a CTF trace converted without --data-type fails loudly, naming the option: ok"
		fi

		# --- Check 4: the CTF deliverable must match the JSON one ---
		# The per-sample records resolve to the same members with the
		# same read/write split as the aggregate histogram, so the two
		# deliverables must agree.
		if [ "$ctf_rc" -ne 0 ]; then
			error_log "FAIL: pahole failed on the CTF deliverable: $(cat "$outdir/ctf.err")"
			test_fail
		fi
		if ! echo "$ctf_stdout" | grep -q "perf data-type profile"; then
			error_log "FAIL: the fixture struct was not annotated from the CTF trace"
			test_fail
		fi
		if ! echo "$ctf_stdout" | grep "hot_written" | grep -Eq "nr_writes=[1-9]"; then
			error_log "FAIL: hot_written has no stores in the CTF deliverable"
			test_fail
		fi
		if echo "$ctf_stdout" | grep "idle" | grep -q "nr_"; then
			error_log "FAIL: the idle member got counters in the CTF deliverable"
			test_fail
		fi
		if [ -s "$outdir/ctf.err" ]; then
			error_log "FAIL: the CTF deliverable printed to stderr: $(cat "$outdir/ctf.err")"
			test_fail
		fi
		# The member lines of both deliverables must match: same offsets,
		# same sizes, same counters.  The CTF-only per-sample analysis
		# lines (FALSE SHARING, GROUP) are dropped, and so is the block
		# closing comment marker, which rides at the end of whatever
		# line came last (a GROUP hint, on a trace with one).  The
		# fixture is single-threaded and touches one member, so no such
		# lines are expected anyway.
		json_members=$(echo "$json_stdout" | sed -n '/perf data-type profile/,/\*\//p' |
			       grep -E "^\s+\+" | grep -v ">>" | sed 's/ \*\/$//')
		ctf_members=$(echo "$ctf_stdout" | sed -n '/perf data-type profile/,/\*\//p' |
			      grep -E "^\s+\+" | grep -v ">>" | sed 's/ \*\/$//')
		if [ "$json_members" != "$ctf_members" ]; then
			error_log "FAIL: the JSON and CTF deliverables disagree:"
			info_log "   JSON: $json_members"
			info_log "   CTF:  $ctf_members"
			test_fail
		fi
		info_log "the CTF deliverable matches the JSON deliverable: ok"
	fi
fi

test_pass
