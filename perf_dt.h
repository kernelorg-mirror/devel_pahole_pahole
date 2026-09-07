/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef _PERF_DT_H
#define _PERF_DT_H

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

struct class;
struct cu;

/*
 * One access record, shared by both backends.  The JSON backend fills only
 * offset/nr/period (aggregate histogram data for hot-field highlighting).
 * The CTF backend fills all fields including timestamp/cpu/instance/is_write
 * (per-sample data for false-sharing detection and cacheline-group suggestions).
 */
struct perf_dt_access {
	uint64_t	offset;
	uint64_t	nr;
	uint64_t	period;
	uint64_t	timestamp;	/* sample timestamp (ns/order); 0 == unknown */
	uint32_t	cpu;
	uint64_t	instance;	/* allocation tag / address; 0 == unknown */
	bool		is_write;
};

/*
 * One DSO the profile was collected from.  The JSON backend fills it from
 * the per-DSO "dso"/"build_id" fields perf emits, one "dsos" entry per DSO
 * with the types that had hits in it; the CTF backend registers a single
 * unknown DSO until the perf side learns to emit per-sample DSO ids
 * (perf_dso_info).  The build ID (a hex string) is the portable binary
 * identity: same build ID == same binary, whatever path it was found at.
 * NULL means "not present" (stripped binary, --no-buildid, vdso, or a
 * producer that predates the field).
 */
struct perf_dt_dso {
	char			*long_name;
	char			*build_id;
};

struct perf_dt_type {
	char			*name;
	uint32_t		cacheline_size;
	uint32_t		size;	/* type size in bytes, from the JSON "size"
					 * field; 0 when the producer omitted it.  Used to
					 * flag a vmlinux/DWARF mismatch. */
	uint32_t		dso;	/* index into perf_dt_profile::dsos */
	struct perf_dt_access	*accesses;
	size_t			nr_accesses;
	size_t			alloc_accesses;
	bool			warned_size;	/* size-mismatch warning already
						 * emitted for this type (once per
						 * type, not per CU / per call) */
	bool			warned_unmatched;	/* unmatched-samples warning
							 * already emitted for this type */
	bool			warned_bid;	/* build-ID error/warning already
						 * emitted for this type */
};

struct perf_dt_profile {
	struct perf_dt_dso	*dsos;
	size_t			nr_dsos;
	size_t			alloc_dsos;
	struct perf_dt_type	*types;
	size_t			nr_types;
	size_t			alloc_types;
};

/* Backend loaders (dispatch in perf_dt_profile__load). */
int perf_dt_profile__load_json(const char *path);
int perf_dt_profile__load_ctf(const char *path);

/* Shared by the backends to populate the profile. */
uint32_t perf_dt_profile__find_or_add_dso(struct perf_dt_profile *p,
					  const char *long_name,
					  const char *build_id);
struct perf_dt_type *perf_dt_profile__add_type(struct perf_dt_profile *p,
					       uint32_t dso, const char *name,
					       uint32_t cln, uint32_t size);
struct perf_dt_type *perf_dt_profile__find_or_add_type(struct perf_dt_profile *p,
						       uint32_t dso, const char *name,
						       uint32_t cln, uint32_t size);
void perf_dt_type__add_access(struct perf_dt_type *dt, uint64_t offset,
			      uint64_t nr, uint64_t period, uint64_t ts,
			      uint32_t cpu, uint64_t inst, bool wr);

/* Load a perf data-type profile, auto-detecting JSON (a file) vs CTF (a
 * directory produced by: perf mem record -a ... ; perf data convert
 * --to-ctf=./dir).
 *
 * JSON gives aggregate hot-field highlighting (from perf report --json).
 * CTF gives per-sample analysis: false-sharing detection, cacheline-group
 * suggestions (from perf mem record + perf data convert --to-ctf).
 *
 * Parses and stores the profile; a later call replaces it.
 * Returns 0 on success, -1 on error (and prints a message to stderr).
 */
int perf_dt_profile__load(const char *path);

/* Whether a perf data-type profile is loaded (--perf-data-type). */
bool perf_dt_profile__loaded(void);

/*
 * How far apart two accesses may be, in microseconds, and still count as
 * interfering in the two analyses the per-sample (CTF) data enables: false
 * sharing, and the cacheline-group suggestion built on co-accessed reads.
 * Zero asks for accesses carrying the same timestamp.  The defaults are 10
 * and 1, see --perf-data-type-fs-window and --perf-data-type-group-window.
 */
void perf_dt_set_false_sharing_window(uint64_t usec);
void perf_dt_set_group_window(uint64_t usec);

/* Whether the class has hits in the loaded perf data-type profile: only when
 * a profile entry for this type name, usable per the cu build ID rules below,
 * carries samples.  With no profile loaded not one class has hits (false),
 * just like anonymous classes (name == NULL), which can't be keyed by name.
 * warn=false keeps the build-ID mismatch silent, for the print filter under
 * --quiet, where the annotation path it gates stays quiet as well.
 */
bool perf_dt_profile__class_has_hits(const char *name, const struct cu *cu,
				     uint32_t class_size, bool warn);

/* Emit a cacheline-grouping annotation block for the given class, using the
 * loaded perf profile.  With JSON data: hot-field highlighting only.  With
 * CTF data: also false-sharing detection and cacheline-group suggestions.
 * Does nothing (returns 0) if there is no profile or the type has no samples.
 *
 * The profile entry is matched by (DSO, name), verified via the build ID:
 * when both the entry's DSO and the cu carry one and they disagree, the
 * samples were collected on a different binary and the type is skipped with
 * an error (a same-name type from another build may even share the size,
 * but not the member layout).  A missing build ID on either side falls back
 * to name+size matching, warning once per type.
 */
size_t perf_dt_profile__fprintf_block(FILE *fp, struct class *class,
				      const struct cu *cu, int indent);

#endif /* _PERF_DT_H */
