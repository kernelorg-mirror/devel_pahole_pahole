#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test pahole's false-sharing detector against perf's own cross-CPU
# false-sharing workload, end to end:
#
#   perf mem record (or 'perf record -d' as fallback) of
#   'perf test -w false_sharing <seconds> <nreaders>'
#   perf data convert --to-ctf --data-type
#   pahole -F dwarf --perf-data-type=<ctf> -C net_conn <that perf binary>
#
# The workload is designed so that reader CPUs read the net_conn header
# members (saddr, daddr, sport, dport, state, protocol) while a writer CPU
# updates the rx/tx counter members (bytes_rx, packets_rx, rx_queue,
# last_ack, ...) of the same struct instances: the same cacheline read by
# one CPU and written by another, close in time, which is the collision
# the detector looks for.  net_conn lives in the perf binary itself (it is
# the workload's fixture), which is what pahole reads the type from.
#
# The detector grades the finding by what the samples tell it:
#
#   - with data addresses and CPU identity (Intel PEBS and AMD IBS via the
#     memory events) the instance identity is exact, and a read/write
#     interleave on the same instance within the false-sharing window
#     (10us) on different CPUs is CONFIRMED:
#     ">>> FALSE SHARING: cacheline 0: <member> / <member>"
#   - on a fallback 'perf record -d' capture the samples may carry no
#     reliable instance or CPU identity, and the finding is SUSPECTED:
#     ">>> SUSPECTED FALSE SHARING: cacheline 0: <member> / <member>"
#
# Both gradings are accepted: the workload produces the collision, the
# hardware determines how sure pahole is allowed to be.  The workload is
# recorded with the memory events when available and falls back to
# 'perf record -d -e cycles' otherwise, so this test also runs where
# per-thread memory-event recording is refused (e.g. AMD IBS), where
# tests/perf_dt_pair.sh has to skip.
#
# The GROUP (true sharing) hints are not asserted: they need same-instance
# co-access within their own (1us) window, which addr-less fallback
# captures may never produce.  When they appear they are reported as info.
#
# The false-sharing detection is a CTF-deliverable feature: it needs the
# per-sample timestamp/CPU/addr records the aggregate JSON does not carry,
# so unlike tests/perf_dt_pair.sh this test has no JSON half.

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT
cleanup() {
	rm -rf "${outdir}"
}

title_log "perf data-type CTF false-sharing detector on the perf false_sharing workload."

# pahole itself: test_lib.sh puts ../build in PATH, the checks below need
# the just-built one to test new code.
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

# perf is the generator and the type source (the workload's net_conn
# fixture is linked into it).
if ! command -v perf > /dev/null 2>&1; then
	error_log "skip: perf not found"
	test_skip
fi
perf_bin=$(command -v perf)

# The data-type resolution perf does needs DWARF support.
if ! perf check feature -q dwarf; then
	error_log "skip: perf has no DWARF support"
	test_skip
fi

# The false-sharing detection needs the per-sample records, i.e. the CTF
# deliverable, which needs the converter's babeltrace writer.
if ! perf check feature -q babeltrace2-ctf-writer; then
	error_log "skip: perf has no babeltrace2-ctf-writer"
	test_skip
fi

# Record the workload: the memory events when this PMU allows recording
# them for a workload process, the cycles + address fallback otherwise
# (which yields SUSPECTED findings on hardware without data addresses).
# Two tries: the finding is an observation over a sampled window, and a
# heavily loaded test box (the suite runs its tests in parallel) can
# starve a short capture of qualifying read/write interleaves, so the
# retry doubles down on traffic before the test fails.
perfdata="$outdir/fs.data"
ctf_dir="$outdir/fs.ctf"
fs_try=1
fs_line=""
while :; do
	if [ "$fs_try" -eq 1 ]; then
		wl_args="4 4"
	else
		wl_args="10 8"
		info_log "   no FALSE SHARING finding in the first capture, retrying with a longer one"
	fi
	if ! perf mem record --sample-cpu -o "$perfdata" -- perf test -w false_sharing $wl_args > /dev/null 2>&1 &&
	   ! perf record -d --sample-cpu -c 500000 -e cycles:u -o "$perfdata" -- perf test -w false_sharing $wl_args > /dev/null 2>&1; then
		if [ "$fs_try" -eq 1 ]; then
			error_log "skip: cannot record the false_sharing workload (no memory events and cycles -d failed)"
			test_skip
		fi
		error_log "FAIL: the retry capture failed"
		test_fail
	fi
	if [ ! -s "$perfdata" ]; then
		error_log "skip: the recorded perf.data is empty"
		test_skip
	fi

	# Convert to the CTF deliverable with the data-type resolution in.
	if ! perf data convert --to-ctf="$ctf_dir" --data-type --force -i "$perfdata" > "$outdir/convert.log" 2>&1; then
		error_log "FAIL: perf data convert --to-ctf --data-type failed:"
		info_log "   $(tail -2 "$outdir/convert.log")"
		test_fail
	fi
	if [ ! -f "$ctf_dir/metadata" ]; then
		error_log "FAIL: the converted trace has no metadata"
		test_fail
	fi

	# The perf binary must carry the fixture's type for pahole to
	# annotate; a stripped distro perf has no net_conn DWARF, which is
	# environmental.
	if ! "$pahole_bin" -F dwarf -C net_conn "$perf_bin" 2>/dev/null |
	     grep -q "struct net_conn {"; then
		error_log "skip: no net_conn DWARF in $perf_bin"
		test_skip
	fi

	ctf_stdout=$("$pahole_bin" -F dwarf --perf-data-type="$ctf_dir" -C net_conn "$perf_bin" 2> "$outdir/ctf.err")
	ctf_rc=$?

	if [ "$ctf_rc" -gt 128 ]; then
		error_log "FAIL: pahole died with signal $((ctf_rc - 128)) on the CTF deliverable"
		test_fail
	fi
	if grep -q "built without libbabeltrace2" "$outdir/ctf.err"; then
		error_log "skip: pahole built without libbabeltrace2"
		test_skip
	fi
	if [ "$ctf_rc" -ne 0 ]; then
		error_log "FAIL: pahole failed on the CTF deliverable: $(cat "$outdir/ctf.err")"
		test_fail
	fi

	# The annotated struct must carry the profile block; its absence is
	# not something a longer capture fixes, so no retry for it.
	if ! echo "$ctf_stdout" | grep -q "perf data-type profile"; then
		error_log "FAIL: net_conn was not annotated from the CTF trace: $(cat "$outdir/ctf.err")"
		test_fail
	fi

	# Accept either grading: CONFIRMED when the samples carry instance
	# and CPU identity, SUSPECTED when they do not.
	fs_line=$(echo "$ctf_stdout" |
		  sed -n 's/.*>>> \(SUSPECTED \)\{0,1\}FALSE SHARING: cacheline [0-9]*: \(.*\)$/\1|\2/p')
	[ -n "$fs_line" ] && break
	if [ "$fs_try" -ge 2 ]; then
		break
	fi
	fs_try=$((fs_try + 1))
done

if [ -z "$fs_line" ]; then
	error_log "FAIL: no FALSE SHARING finding for the false_sharing workload:"
	info_log "   $(echo "$ctf_stdout" | sed -n '/perf data-type profile/,/\*\//p' | tail -5)"
	test_fail
fi
fs_grade=$(echo "$fs_line" | cut -d'|' -f1)
fs_pair=$(echo "$fs_line" | cut -d'|' -f2)
if [ "$fs_grade" = "SUSPECTED " ]; then
	info_log "   finding graded SUSPECTED (no instance identity in the samples): ok"
else
	info_log "   finding graded CONFIRMED: ok"
fi

# The flagged pair must name two real members of the annotated profile,
# not garbage from a mangled CTF record or a wrong type resolution.
fs_read=$(echo "$fs_pair" | cut -d' ' -f1)
fs_write=$(echo "$fs_pair" | cut -d' ' -f3)
for fs_member in "$fs_read" "$fs_write"; do
	if ! echo "$ctf_stdout" |
	     grep -Eq "^[[:space:]]*\+[0-9]+[[:space:]]+${fs_member}([[:space:]]|$)"; then
		error_log "FAIL: the FALSE SHARING pair names '$fs_member', which is not a member of the profile"
		test_fail
	fi
done
info_log "the detector flagged the workload's collision: cacheline pair '$fs_pair': ok"

# Non-fatal: the same-instance co-access GROUP hints need the 1us
# co-access window populated with identified instances, which addr-less
# fallback captures may never produce.  Report them when they show up.
group_nr=$(echo "$ctf_stdout" | grep -c ">>> GROUP (true sharing):" || true)
if [ "$group_nr" -gt 0 ]; then
	info_log "   $group_nr GROUP (true sharing) hints reported"
fi

test_pass
