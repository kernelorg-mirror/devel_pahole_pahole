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
 * with the types that had hits in it; the CTF backend fills it from the
 * perf_dso_info side events the converter emits once per DSO it resolved
 * types in (an unknown DSO, with no build ID, for traces that predate
 * them).  The build ID (a hex string) is the portable binary identity:
 * same build ID == same binary, whatever path it was found at.  NULL means
 * "not present" (stripped binary, --no-buildid, vdso, or a producer that
 * predates the field).
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

/* Replace the currently loaded profile (used by the CTF backend). */
void perf_dt_profile__set(struct perf_dt_profile *p);

/* Release a profile and everything it owns; NULL is a no-op. */
void perf_dt_profile__delete(struct perf_dt_profile *p);

/* Shared by the backends to populate the profile. */
void perf_dt__oom_dropping(const char *what);
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

/*
 * The profile for one class: the profile entry it matched plus the accesses
 * aggregated onto its members and the totals used to rank them.  Built once
 * for a class being pretty printed (perf_dt_class__new) and then consumed
 * twice: by the inline member annotations, while each member is printed, and
 * by the summary block at the end of the struct.
 *
 * NULL when there is no profile, no entry for this class, or when not a
 * single sample matched one of its members, i.e. when there is nothing to
 * annotate.
 *
 * The profile entry is matched by (DSO, name), verified via the build ID:
 * when both the entry's DSO and the cu carry one and they disagree, the
 * samples were collected on a different binary and the type is skipped with
 * an error (a same-name type from another build may even share the size,
 * but not the member layout).  A missing build ID on either side falls back
 * to name+size matching, warning once per type.
 */
struct perf_dt_class;

struct perf_dt_class *perf_dt_class__new(struct class *class, const struct cu *cu);
void perf_dt_class__delete(struct perf_dt_class *pdc);

/* Inline annotation: the accesses to this member, at the end of its offset
 * comment (the same comment, not a second one), so that a hot field is
 * spotted while browsing a big struct, not just in the summary block at its
 * end.  Members with no accesses print nothing, and, riding in the offset
 * comment, it goes away with --suppress_offset_comment (-q).
 */
size_t perf_dt_class__fprintf_member(FILE *fp, const struct perf_dt_class *pdc,
				     const struct class_member *member);

/* The summary block at the end of the struct: per-cacheline access counts
 * plus, with CTF per-sample data, false-sharing detection and cacheline-group
 * suggestions.  Does nothing (returns 0) for a NULL pdc.
 */
size_t perf_dt_class__fprintf_block(FILE *fp, const struct perf_dt_class *pdc,
				    int indent);

#endif /* _PERF_DT_H */
