#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Test if BTF generated serially matches reproducible parallel DWARF loading + serial BTF encoding
# Arnaldo Carvalho de Melo <acme@redhat.com> (C) 2024-

source "$(dirname "$0")/test_lib.sh"

vmlinux=$(get_vmlinux $1)
if [ $? -ne 0 ]; then
	info_log "$vmlinux"
	test_fail
fi

outdir=$(make_tmpdir)

# Comment this out to save test data.
trap cleanup EXIT

title_log "Parallel reproducible DWARF Loading/Serial BTF encoding."

verbose_log "Begin serial encoding..."

# This will make pahole and pfunct to skip rust CUs
export PAHOLE_LANG_EXCLUDE=rust

pahole --btf_features=default --btf_encode_detached=$outdir/vmlinux.btf.serial $vmlinux
bpftool btf dump file $outdir/vmlinux.btf.serial > $outdir/bpftool.output.vmlinux.btf.serial

nr_proc=$(getconf _NPROCESSORS_ONLN)
half_proc=$((nr_proc / 2))
thread_list=$(echo "1 2 4 $half_proc $nr_proc" | tr ' ' '\n' | sort -nu | tr '\n' ' ')

for threads in $thread_list ; do
	verbose_log "$threads threads encoding"
	pahole -j$threads --btf_features=default,reproducible_build --btf_encode_detached=$outdir/vmlinux.btf.parallel.reproducible $vmlinux &
	pahole=$!
	# HACK: Wait a bit for pahole to start its threads
	sleep 1s
	# Count threads for this specific pahole process (not system-wide)
	nr_threads_started=$(ps -L -p $pahole 2>/dev/null | grep -v PID | wc -l)
		((nr_threads_started -= 1)) # main thread doesn't count, it waits to join

	if [ $threads != $nr_threads_started ] ; then
		error_log "ERROR: pahole asked to start $threads encoding threads, started $nr_threads_started"
		test_fail
	fi

	verbose_log "$nr_threads_started threads started"
	wait $pahole
	rm -f $outdir/bpftool.output.vmlinux.btf.parallel.reproducible
	bpftool btf dump file $outdir/vmlinux.btf.parallel.reproducible > $outdir/bpftool.output.vmlinux.btf.parallel.reproducible
	verbose_log "diff from serial encoding:"
	diff -u $outdir/bpftool.output.vmlinux.btf.serial $outdir/bpftool.output.vmlinux.btf.parallel.reproducible > $outdir/diff
	if [ -s $outdir/diff ] ; then
		error_log "ERROR: BTF generated from DWARF in parallel is different from the one generated in serial!"
		test_fail
	fi
	verbose_log -----------------------------
done

test_pass
