/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Consume perf's data-type profiling JSON in pahole.
 *
 * The JSON carries aggregate histograms from `perf report --data-type-json`
 * or `perf annotate --data-type --data-type-json`: per-event, per-offset
 * nr_samples_load/nr_samples_store and period_load/period_store.  This gives
 * hot-field highlighting and a read/write breakdown, but cannot drive
 * false-sharing detection (no per-sample temporal/spatial signal).
 *
 * The profile is a single object with two entries: "machine", describing the
 * machine the profile was captured on, from which pahole takes the cacheline
 * size the histograms were collected with, which groups the offsets into
 * cachelines; and "dsos", with one entry per DSO that had types with hits in
 * it, carrying its identity, "dso" (perf's dso__long_name, possibly a
 * build-id cache path) and "build_id" (hex string, null when absent), and
 * the "types" that had hits in it, each with its size, its member tree and
 * its per-event, per-offset histograms.
 *
 * For false-sharing analysis and cacheline-group suggestions, use the CTF
 * backend (perf_dt_ctf.c) which reads per-sample records with timestamp,
 * cpu, address (instance identity), and is_write from:
 *     perf mem record -a sleep N
 *     perf data convert --to-ctf=./ctf.dir
 *
 * The JSON parser is jsmn (vendored, header-only, MIT).  See jsmn.h.
 *
 * Types are keyed on (DSO, name, size) and, when annotating, verified
 * against the build ID of the binary being analyzed: a mismatch means the
 * samples were collected on a different binary and is an error, not a
 * warning.
 */

#define JSMN_STATIC
#include "jsmn.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>
#include <sys/stat.h>

#include "dwarves.h"
#include "perf_dt.h"

/* Bound on JSON nesting depth for the iterative tok_end() traversal. */
#define PERF_DT_TOK_DEPTH 64

static struct perf_dt_profile *perf_dt_profile;

static int json_key_eq(const char *buf, const jsmntok_t *t, const char *s)
{
	int len = t->end - t->start;

	return (int)strlen(s) == len && strncmp(&buf[t->start], s, len) == 0;
}

static char *json_str_dup(const char *buf, const jsmntok_t *t)
{
	int len = t->end - t->start;
	char *s = malloc(len + 1);

	if (!s)
		return NULL;
	memcpy(s, &buf[t->start], len);
	s[len] = '\0';
	return s;
}

static uint64_t json_u64(char *buf, const jsmntok_t *t)
{
	char c = buf[t->end];
	uint64_t v;

	buf[t->end] = '\0';
	v = strtoull(&buf[t->start], NULL, 10);
	buf[t->end] = c;
	return v;
}

static int tok_end(jsmntok_t *t, int n, int i)
{
	/*
	 * Return the index just past the whole subtree rooted at token i, or
	 * -1 when i is out of range, the nesting exceeds PERF_DT_TOK_DEPTH or
	 * the subtree would run past the token array: a malformed document,
	 * which callers must treat as a parse failure rather than silently
	 * misparsing.  Iterative to avoid stack overflow on deeply nested
	 * JSON (the previous recursive version recursed without bound).
	 */
	int c = i + 1;
	struct { int remaining; int is_object; } stack[PERF_DT_TOK_DEPTH];
	int sp = 0;

	if (i < 0 || i >= n)
		return -1;

	if (t[i].type == JSMN_OBJECT || t[i].type == JSMN_ARRAY) {
		stack[sp].remaining = t[i].size;
		stack[sp].is_object = (t[i].type == JSMN_OBJECT);
		sp++;
	} else {
		return c; /* primitive: just itself */
	}

	while (sp > 0) {
		if (stack[sp - 1].remaining == 0) {
			sp--;
			continue;
		}
		/* An object entry is key (a primitive token) followed by value. */
		if (stack[sp - 1].is_object)
			c++;
		stack[sp - 1].remaining--;
		if (c >= n)
			return -1; /* subtree would run past the token array */
		if (t[c].type == JSMN_OBJECT || t[c].type == JSMN_ARRAY) {
			if (sp >= PERF_DT_TOK_DEPTH)
				return -1; /* nesting deeper than the bound */
			stack[sp].remaining = t[c].size;
			stack[sp].is_object = (t[c].type == JSMN_OBJECT);
			sp++;
			c++; /* move past the container token to its first child */
		} else {
			c++;
		}
	}
	return c;
}

static bool dso_name_eq(const char *a, const char *b)
{
	if (!a || !b)
		return !a && !b;
	return strcmp(a, b) == 0;
}

/*
 * DSO identity: the build ID when both sides carry one (the same binary
 * shows up under different paths: perf's build-id cache, /lib/modules,
 * ...), falling back to the long name when either side lacks a build ID.
 * Whichever half is missing on the existing entry is adopted from the
 * new one, so a name-only entry later meets its build ID.
 */
uint32_t perf_dt_profile__find_or_add_dso(struct perf_dt_profile *p,
					  const char *long_name,
					  const char *build_id)
{
	size_t i;

	for (i = 0; i < p->nr_dsos; i++) {
		struct perf_dt_dso *d = &p->dsos[i];

		if (build_id && d->build_id) {
			if (strcmp(build_id, d->build_id) == 0)
				return (uint32_t)i;
			continue;	/* same name or not: different binary */
		}
		if (!dso_name_eq(long_name, d->long_name))
			continue;
		if (build_id && !d->build_id)
			d->build_id = strdup(build_id);
		if (long_name && !d->long_name)
			d->long_name = strdup(long_name);
		return (uint32_t)i;
	}

	if (p->nr_dsos == p->alloc_dsos) {
		size_t n = p->alloc_dsos ? p->alloc_dsos * 2 : 4;
		struct perf_dt_dso *d = realloc(p->dsos, n * sizeof(*d));

		if (!d)
			return UINT32_MAX;
		p->dsos = d;
		p->alloc_dsos = n;
	}
	p->dsos[p->nr_dsos].long_name = long_name ? strdup(long_name) : NULL;
	p->dsos[p->nr_dsos].build_id = build_id ? strdup(build_id) : NULL;
	return (uint32_t)p->nr_dsos++;
}

struct perf_dt_type *perf_dt_profile__add_type(struct perf_dt_profile *p,
					       uint32_t dso, const char *name,
					       uint32_t cln, uint32_t size)
{
	if (p->nr_types == p->alloc_types) {
		size_t n = p->alloc_types ? p->alloc_types * 2 : 8;
		struct perf_dt_type *t = realloc(p->types, n * sizeof(*t));

		if (!t)
			return NULL;
		p->types = t;
		p->alloc_types = n;
	}
	p->types[p->nr_types].name = strdup(name);
	if (!p->types[p->nr_types].name)
		return NULL;
	p->types[p->nr_types].dso = dso;
	p->types[p->nr_types].cacheline_size = cln;
	p->types[p->nr_types].size = size;
	p->types[p->nr_types].accesses = NULL;
	p->types[p->nr_types].nr_accesses = 0;
	p->types[p->nr_types].alloc_accesses = 0;
	p->types[p->nr_types].warned_size = false;
	p->types[p->nr_types].warned_unmatched = false;
	p->types[p->nr_types].warned_bid = false;
	return &p->types[p->nr_types++];
}

struct perf_dt_type *perf_dt_profile__find_or_add_type(struct perf_dt_profile *p,
						       uint32_t dso, const char *name,
						       uint32_t cln, uint32_t size)
{
	size_t i;

	for (i = 0; i < p->nr_types; i++) {
		struct perf_dt_type *t = &p->types[i];

		if (t->dso != dso || strcmp(t->name, name) != 0)
			continue;
		/*
		 * Same (DSO, name): a size of 0 on either side means
		 * "unspecified" and merges, but different nonzero sizes
		 * are different types.  perf emits one object per (DSO,
		 * type), yet different types can share a generic name
		 * (char[], u8[], ...) at different sizes.
		 */
		if (size && t->size && t->size != size)
			continue;
		if (size && !t->size)
			t->size = size;
		if (cln && !t->cacheline_size)
			t->cacheline_size = cln;
		return t;
	}
	return perf_dt_profile__add_type(p, dso, name, cln, size);
}

/*
 * Growing one of the profile arrays failed: the access is dropped, so the
 * profile that gets printed is incomplete.  Say it once instead of silently
 * under-reporting the traffic, and stay quiet on the drops that follow.
 */
static void perf_dt__oom_dropping(const char *what)
{
	static bool warned;

	if (warned)
		return;
	warned = true;
	fprintf(stderr, "perf_dt: out of memory, dropping %s: the profile will be incomplete\n",
		what);
}

void perf_dt_type__add_access(struct perf_dt_type *dt, uint64_t offset,
			      uint64_t nr, uint64_t period, uint64_t ts,
			      uint32_t cpu, uint64_t inst, bool wr)
{
	if (dt->nr_accesses == dt->alloc_accesses) {
		size_t n = dt->alloc_accesses ? dt->alloc_accesses * 2 : 64;
		struct perf_dt_access *a = realloc(dt->accesses, n * sizeof(*a));

		if (!a) {
			perf_dt__oom_dropping("accesses");
			return;
		}
		dt->accesses = a;
		dt->alloc_accesses = n;
	}
	dt->accesses[dt->nr_accesses].offset = offset;
	dt->accesses[dt->nr_accesses].nr = nr ? nr : 1;
	dt->accesses[dt->nr_accesses].period = period;
	dt->accesses[dt->nr_accesses].timestamp = ts;
	dt->accesses[dt->nr_accesses].cpu = cpu;
	dt->accesses[dt->nr_accesses].instance = inst;
	dt->accesses[dt->nr_accesses].is_write = wr;
	dt->nr_accesses++;
}

/* Release the currently loaded profile, if any. */
static void perf_dt_profile__free(void)
{
	if (!perf_dt_profile)
		return;
	for (size_t t = 0; t < perf_dt_profile->nr_types; t++) {
		free(perf_dt_profile->types[t].name);
		free(perf_dt_profile->types[t].accesses);
	}
	for (size_t d = 0; d < perf_dt_profile->nr_dsos; d++) {
		free(perf_dt_profile->dsos[d].long_name);
		free(perf_dt_profile->dsos[d].build_id);
	}
	zfree(&perf_dt_profile->dsos);
	zfree(&perf_dt_profile->types);
	zfree(&perf_dt_profile);
}

/*
 * Parse the "histograms" array produced by perf report/annotate --data-type-json.
 *
 * Each event object carries the aggregate totals and a per-offset "samples"
 * array.  Perf counts loads and stores in separate per-direction counters, so
 * every sample carries both directions:
 *
 *   { "event":..., "total_samples":<u64>, "total_period":<u64>,
 *     "samples":[
 *       { "offset":<int>, "nr_samples_load":<int>, "nr_samples_store":<int>,
 *         "period_load":<u64>, "period_store":<u64> }, ... ] }
 *
 * We turn each nonzero direction into a perf_dt_access with is_write set
 * accordingly and zeroed timestamp/cpu/instance, which gives hot-field
 * highlighting with a read/write breakdown but cannot drive false-sharing
 * detection (no per-sample temporal/spatial signal).
 *
 * Per-sample analysis (timestamp, cpu, instance) for false-sharing detection
 * requires the CTF backend: perf mem record + perf data convert --to-ctf.
 */
static int parse_histograms(struct perf_dt_type *dt, char *buf,
			    jsmntok_t *toks, int n, int hidx)
{
	int e = hidx + 1;
	int hend = tok_end(toks, n, hidx);

	if (hend < 0)
		return -1;

	for (; e < hend; ) {
		int sidx = -1;
		int k2 = e + 1;
		int eend = tok_end(toks, n, e);

		if (eend < 0)
			return -1;
		/* The documented shape is an object with key/value pairs. */
		if (toks[e].type != JSMN_OBJECT)
			return -1;

		for (; k2 < eend; ) {
			int v = k2 + 1;
			int vend = tok_end(toks, n, v);

			if (vend < 0)
				return -1;

			if (json_key_eq(buf, &toks[k2], "samples"))
				sidx = v;
			k2 = vend;
		}

		if (sidx >= 0 && toks[sidx].type == JSMN_ARRAY) {
			int s = sidx + 1;
			int send = tok_end(toks, n, sidx);

			if (send < 0)
				return -1;

			for (; s < send; ) {
				uint64_t off = 0;
				uint64_t nr_l = 0, nr_s = 0;
				uint64_t per_l = 0, per_s = 0;
				int k3 = s + 1;
				int sobj = tok_end(toks, n, s);

				if (sobj < 0)
					return -1;
				if (toks[s].type != JSMN_OBJECT)
					return -1;

				for (; k3 < sobj; ) {
					int v = k3 + 1;
					int vend = tok_end(toks, n, v);

					if (vend < 0)
						return -1;

					if (json_key_eq(buf, &toks[k3], "offset"))
						off = json_u64(buf, &toks[v]);
					else if (json_key_eq(buf, &toks[k3], "nr_samples_load"))
						nr_l = json_u64(buf, &toks[v]);
					else if (json_key_eq(buf, &toks[k3], "nr_samples_store"))
						nr_s = json_u64(buf, &toks[v]);
					else if (json_key_eq(buf, &toks[k3], "period_load"))
						per_l = json_u64(buf, &toks[v]);
					else if (json_key_eq(buf, &toks[k3], "period_store"))
						per_s = json_u64(buf, &toks[v]);
					k3 = vend;
				}
				if (nr_l)
					perf_dt_type__add_access(dt, off, nr_l,
								 per_l, 0, 0, 0, false);
				if (nr_s)
					perf_dt_type__add_access(dt, off, nr_s,
								 per_s, 0, 0, 0, true);
				s = sobj;
			}
		}
		e = eend;
	}
	return 0;
}

/*
 * Parse one type object, inside a "dsos" entry:
 *
 *   { "type": "struct task_struct", "size": <int>,
 *     "members": [ ... ],
 *     "histograms": [ ... ] }
 *
 * The DSO identity comes from the enclosing "dsos" entry (dso_index) and
 * the default cacheline size from the "machine" entry (cln); the member
 * tree is not used, the members are read from the DWARF/BTF of the binary
 * being analyzed.
 */
static int parse_type(struct perf_dt_profile *p, char *buf,
		      jsmntok_t *toks, int n, int idx, uint32_t dso_index,
		      uint32_t cln)
{
	char *type_name = NULL;
	uint32_t dt_size = 0;
	int hidx = -1;
	int k = idx + 1;
	int oend = tok_end(toks, n, idx);

	if (oend < 0)
		return -1;
	if (toks[idx].type != JSMN_OBJECT)
		return -1;

	for (; k < oend; ) {
		int v = k + 1;
		int vend = tok_end(toks, n, v);

		if (vend < 0) {
			free(type_name);
			return -1;
		}

		if (json_key_eq(buf, &toks[k], "type")) {
			free(type_name);
			type_name = json_str_dup(buf, &toks[v]);
		} else if (json_key_eq(buf, &toks[k], "size")) {
			dt_size = (uint32_t)json_u64(buf, &toks[v]);
		} else if (json_key_eq(buf, &toks[k], "histograms")) {
			hidx = v;
		}
		k = vend;
	}

	if (!type_name)
		return 0;

	{
		size_t off = 0;

		if (strncmp(type_name, "struct ", 7) == 0)
			off = 7;
		else if (strncmp(type_name, "union ", 6) == 0)
			off = 6;
		if (off)
			memmove(type_name, type_name + off, strlen(type_name + off) + 1);
	}

	{
		struct perf_dt_type *dt;

		dt = perf_dt_profile__find_or_add_type(p, dso_index, type_name,
						       cln, dt_size);
		free(type_name);	/* find_or_add_type strdups it */
		if (!dt)
			return -1;

		if (hidx >= 0 && toks[hidx].type == JSMN_ARRAY)
			return parse_histograms(dt, buf, toks, n, hidx);
	}
	return 0;
}

/*
 * Parse one "dsos" entry, the DSO identity shared by the types it carries:
 *
 *   { "dso": <path or null>, "build_id": <hex string or null>,
 *     "types": [ <type object>, ... ] }
 */
static int parse_dso(struct perf_dt_profile *p, char *buf,
		     jsmntok_t *toks, int n, int idx, uint32_t cln)
{
	char *dso_name = NULL;
	char *build_id = NULL;
	uint32_t dso_index;
	int tidx = -1;
	int k = idx + 1;
	int oend = tok_end(toks, n, idx);

	if (oend < 0)
		return -1;
	if (toks[idx].type != JSMN_OBJECT)
		return -1;

	for (; k < oend; ) {
		int v = k + 1;
		int vend = tok_end(toks, n, v);

		if (vend < 0) {
			free(dso_name);
			free(build_id);
			return -1;
		}

		if (json_key_eq(buf, &toks[k], "dso")) {
			free(dso_name);
			/* null (a jsmn primitive) or absent: unknown DSO */
			if (toks[v].type == JSMN_STRING)
				dso_name = json_str_dup(buf, &toks[v]);
		} else if (json_key_eq(buf, &toks[k], "build_id")) {
			free(build_id);
			if (toks[v].type == JSMN_STRING)
				build_id = json_str_dup(buf, &toks[v]);
		} else if (json_key_eq(buf, &toks[k], "types")) {
			tidx = v;
		}
		k = vend;
	}

	dso_index = perf_dt_profile__find_or_add_dso(p, dso_name, build_id);
	free(dso_name);
	free(build_id);
	if (dso_index == UINT32_MAX)
		return -1;

	if (tidx < 0 || toks[tidx].type != JSMN_ARRAY)
		return 0;

	{
		int t = tidx + 1;
		int tend = tok_end(toks, n, tidx);

		if (tend < 0)
			return -1;

		while (t < tend) {
			int tnext = tok_end(toks, n, t);

			if (tnext < 0)
				return -1;
			if (parse_type(p, buf, toks, n, t, dso_index, cln) < 0)
				return -1;
			t = tnext;
		}
	}
	return 0;
}

/*
 * The "machine" entry describes the machine the profile was captured on;
 * what pahole needs from it so far is the cacheline size the histograms
 * were collected with, which is what groups the offsets into cachelines.
 */
static uint32_t parse_machine(char *buf, jsmntok_t *toks, int n, int idx,
			      uint32_t cln)
{
	int k = idx + 1;
	int oend = tok_end(toks, n, idx);

	if (oend < 0)
		return cln;

	for (; k < oend; ) {
		int v = k + 1;
		int vend = tok_end(toks, n, v);

		if (vend < 0)
			return cln;

		if (json_key_eq(buf, &toks[k], "cacheline_size")) {
			uint32_t sz = (uint32_t)json_u64(buf, &toks[v]);

			if (sz)
				cln = sz;
		}
		k = vend;
	}
	return cln;
}

int perf_dt_profile__load_json(const char *path)
{
	FILE *fp = fopen(path, "rb");
	long len;
	char *buf;
	jsmn_parser parser;
	jsmntok_t *toks;
	int n;

	if (!fp) {
		fprintf(stderr, "perf_dt_json: cannot open '%s': %s\n",
			path, strerror(errno));
		return -1;
	}
	fseek(fp, 0, SEEK_END);
	len = ftell(fp);
	fseek(fp, 0, SEEK_SET);
	if (len < 0) {
		fclose(fp);
		return -1;
	}
	buf = malloc(len + 1);
	if (!buf) {
		fclose(fp);
		return -1;
	}
	if (fread(buf, 1, len, fp) != (size_t)len) {
		fprintf(stderr, "perf_dt_json: short read of '%s'\n", path);
		free(buf);
		fclose(fp);
		return -1;
	}
	fclose(fp);
	buf[len] = '\0';

	jsmn_init(&parser);
	n = jsmn_parse(&parser, buf, len, NULL, 0);
	if (n <= 0) {
		fprintf(stderr, "perf_dt_json: failed to parse '%s' (jsmn %d)\n",
			path, n);
		free(buf);
		return -1;
	}
	toks = malloc(sizeof(*toks) * n);
	if (!toks) {
		free(buf);
		return -1;
	}
	jsmn_init(&parser);
	n = jsmn_parse(&parser, buf, len, toks, n);
	if (n <= 0) {
		fprintf(stderr, "perf_dt_json: parse error in '%s' (jsmn %d)\n",
			path, n);
		free(toks);
		free(buf);
		return -1;
	}

	perf_dt_profile__free();
	perf_dt_profile = zalloc(sizeof(*perf_dt_profile));
	if (!perf_dt_profile) {
		free(toks);
		free(buf);
		return -1;
	}

	if (toks[0].type == JSMN_OBJECT) {
		uint32_t cln = 64;
		int k = 1, kend = tok_end(toks, n, 0);

		if (kend < 0)
			goto depth_err;

		/*
		 * The machine entry carries the cacheline size the
		 * histograms were collected with, the default for all the
		 * types; scan for it first, "machine" can come after
		 * "dsos" in the object.
		 */
		for (k = 1; k < kend; ) {
			int v = k + 1;
			int vend = tok_end(toks, n, v);

			if (vend < 0)
				goto depth_err;
			if (json_key_eq(buf, &toks[k], "machine") &&
			    toks[v].type == JSMN_OBJECT)
				cln = parse_machine(buf, toks, n, v, cln);
			k = vend;
		}

		for (k = 1; k < kend; ) {
			int v = k + 1;
			int vend = tok_end(toks, n, v);

			if (vend < 0)
				goto depth_err;
			if (json_key_eq(buf, &toks[k], "dsos") &&
			    toks[v].type == JSMN_ARRAY) {
				int d = v + 1;
				int dend = vend;

				while (d < dend) {
					int dnext = tok_end(toks, n, d);

					if (dnext < 0)
						goto depth_err;
					if (parse_dso(perf_dt_profile, buf, toks, n, d, cln) < 0)
						goto depth_err;
					d = dnext;
				}
			}
			k = vend;
		}
	} else {
		fprintf(stderr, "perf_dt_json: top-level JSON is not an object"
				" (an old format profile? regenerate it with a"
				" current perf)\n");
		perf_dt_profile__free();
		free(buf);
		free(toks);
		return -1;
	}

	/*
	 * An object with no types carrying samples would load as an empty
	 * profile and, with the default filter, print nothing and exit 0:
	 * fail loudly instead, like a non-object top level.
	 */
	{
		bool empty = true;

		for (size_t t = 0; t < perf_dt_profile->nr_types; t++) {
			if (perf_dt_profile->types[t].nr_accesses) {
				empty = false;
				break;
			}
		}
		if (empty) {
			fprintf(stderr, "perf_dt_json: empty profile '%s'"
					" (no types with hits)\n", path);
			perf_dt_profile__free();
			free(buf);
			free(toks);
			return -1;
		}
	}

	/* buf was only needed during parsing; type names are strdup'd */
	free(buf);
	free(toks);
	return 0;

depth_err:
	fprintf(stderr, "perf_dt_json: unexpected structure in '%s' (not a"
			" data-type profile document, or nested deeper than"
			" %d levels?)\n", path, PERF_DT_TOK_DEPTH);
	perf_dt_profile__free();
	free(buf);
	free(toks);
	return -1;
}

#ifndef HAVE_LIBBABELTRACE2
int perf_dt_profile__load_ctf(const char *path)
{
	(void)path;
	fprintf(stderr,
		"perf_dt: built without libbabeltrace2, cannot read CTF ('%s')\n",
		path);
	return -1;
}
#endif

int perf_dt_profile__load(const char *path)
{
	struct stat st;

	if (stat(path, &st) == 0 && S_ISDIR(st.st_mode))
		return perf_dt_profile__load_ctf(path);
	return perf_dt_profile__load_json(path);
}

/* Hex buffer for a build ID: raw bytes * 2 + NUL (ELF notes are 20 or 32). */
#define PERF_DT_BID_HEX 65

/* The cu's raw ELF-note build ID as lowercase hex; false when absent. */
static bool cu_build_id_hex(const struct cu *cu, char *bf, size_t sz)
{
	int i;

	if (cu->build_id_len <= 0)
		return false;
	for (i = 0; i < cu->build_id_len; i++) {
		if (sz < 3)
			return false;
		sprintf(bf, "%02x", cu->build_id[i]);
		bf += 2;
		sz -= 2;
	}
	*bf = '\0';
	return true;
}

/*
 * Find the profile entry for a class being printed from cu.
 *
 * The build ID is the binary identity: when both the entry's DSO and the
 * cu carry one, a disagreement means the samples were collected on a
 * different binary -- the type name (and even the size) may match while
 * the member layout differs, so annotating would silently attribute the
 * samples to the wrong members.  That is an error, not a warning: the
 * type is skipped.  A missing build ID on either side (stripped binary,
 * --no-buildid, CTF backend, a producer predating the field) means
 * "unverified": fall back to name+size matching, warning once per type.
 *
 * With several same-name entries (multiple DSOs), the one whose build ID
 * matches the cu wins; mismatching ones are only skipped silently then.
 *
 * When warn is false (the print filter under --quiet) the mismatch is
 * silent: the caller only asks whether anything is worth printing, and a
 * warning there would escape the --quiet gate the annotation path honors.
 */
static struct perf_dt_type *profile__find_type_for_cu(struct perf_dt_profile *p,
						      const char *name,
						      const struct cu *cu,
						      uint32_t class_size,
						      bool *unverified,
						      bool warn)
{
	struct perf_dt_type *fallback = NULL, *mismatch = NULL;
	char cu_bid[PERF_DT_BID_HEX];
	bool have_cu_bid;
	size_t i;

	*unverified = false;
	have_cu_bid = cu_build_id_hex(cu, cu_bid, sizeof(cu_bid));

	for (i = 0; i < p->nr_types; i++) {
		struct perf_dt_type *t = &p->types[i];
		const struct perf_dt_dso *dso;

		if (strcmp(t->name, name) != 0 || !t->nr_accesses)
			continue;
		dso = &p->dsos[t->dso];
		if (have_cu_bid && dso->build_id) {
			if (strcmp(dso->build_id, cu_bid) == 0)
				return t;	/* verified */
			if (!mismatch)
				mismatch = t;
			continue;
		}
		if (!fallback)
			fallback = t;
	}

	if (mismatch) {
		/*
		 * Every entry carrying a build ID disagrees with the binary
		 * being annotated: the profile came from a different build.
		 * Loud, once per type.
		 */
		const struct perf_dt_dso *dso = &p->dsos[mismatch->dso];

		if (!mismatch->warned_bid && warn) {
			fprintf(stderr,
				"perf_dt: %s: profile build ID %s (DSO %s) != binary build ID %s, skipping its annotation (profile taken on another binary?)\n",
				name, dso->build_id,
				dso->long_name ?: "?", cu_bid);
			mismatch->warned_bid = true;
		}
		return NULL;
	}

	if (!fallback)
		return NULL;

	*unverified = true;
	/* Among unverified entries, prefer the one whose size matches. */
	if (fallback->size && class_size && fallback->size != class_size) {
		for (i = 0; i < p->nr_types; i++) {
			struct perf_dt_type *t = &p->types[i];

			if (strcmp(t->name, name) == 0 &&
			    t->nr_accesses && t->size == class_size)
				return t;
		}
	}
	return fallback;
}

bool perf_dt_profile__loaded(void)
{
	return perf_dt_profile != NULL;
}

bool perf_dt_profile__class_has_hits(const char *name, const struct cu *cu,
				     uint32_t class_size, bool warn)
{
	struct perf_dt_profile *p = perf_dt_profile;
	bool unverified;

	/* No profile loaded: not one class has hits. */
	if (!p)
		return false;

	/* Anonymous classes can't be keyed by name in the profile. */
	if (!name)
		return false;

	return profile__find_type_for_cu(p, name, cu, class_size,
					 &unverified, warn) != NULL;
}

/*
 * How far apart two accesses may be and still count as interfering, in
 * nanoseconds.  A sample is a point in time, so what the analyses ask is
 * not whether two accesses intersected, but whether they happened close
 * enough for one to have cost the other a coherence operation:
 *
 *   false sharing   10us  the other CPU's next access to a line that a
 *                         write invalidated comes as often as that thread
 *                         runs, which is a matter of the sample spacing of
 *                         the two threads, not of how long either access
 *                         lasted;
 *   cacheline group  1us  members one code path walks together are
 *                         microseconds apart at most.
 *
 * Settable with --perf-data-type-fs-window and --perf-data-type-group-window
 * (microseconds); zero asks for accesses carrying the same timestamp.
 */
#define PERF_DT_FS_WINDOW_DEFAULT	(10ULL * 1000)
#define PERF_DT_GROUP_WINDOW_DEFAULT	(1ULL * 1000)

static uint64_t perf_dt_fs_window    = PERF_DT_FS_WINDOW_DEFAULT;
static uint64_t perf_dt_group_window = PERF_DT_GROUP_WINDOW_DEFAULT;

void perf_dt_set_false_sharing_window(uint64_t usec)
{
	perf_dt_fs_window = usec * 1000;
}

void perf_dt_set_group_window(uint64_t usec)
{
	perf_dt_group_window = usec * 1000;
}

struct perf_dt_occ {
	uint64_t	instance;
	uint32_t	cpu;
	uint64_t	tmin;
	uint64_t	tmax;
	bool		is_write;
	uint64_t	nr;
};

struct meminfo {
	uint32_t		off;
	uint32_t		size;
	const char		*nm;
	uint64_t		nr_reads;
	uint64_t		nr_writes;
	uint64_t		period_reads;
	uint64_t		period_writes;
	uint32_t		ci;
	struct perf_dt_occ	*occ;
	size_t			n_occ;
	size_t			alloc_occ;
};

static void mi_add_occ(struct meminfo *m, uint64_t inst, uint32_t cpu,
		       uint64_t ts, bool wr, uint64_t nr)
{
	if (m->n_occ == m->alloc_occ) {
		size_t n = m->alloc_occ ? m->alloc_occ * 2 : 8;
		struct perf_dt_occ *o = realloc(m->occ, n * sizeof(*o));

		if (!o) {
			perf_dt__oom_dropping("per-sample occurrences");
			return;
		}
		m->occ = o;
		m->alloc_occ = n;
	}
	m->occ[m->n_occ].instance = inst;
	m->occ[m->n_occ].cpu = cpu;
	m->occ[m->n_occ].tmin = ts;
	m->occ[m->n_occ].tmax = ts;
	m->occ[m->n_occ].is_write = wr;
	m->occ[m->n_occ].nr = nr ? nr : 1;
	m->n_occ++;
}

/*
 * Call cb() for every pair of occurrences of mx and my that are within
 * window of each other, stopping when it returns non-zero, which is then
 * what this returns.
 *
 * The occurrences of a member are points in time (tmin == tmax) appended in
 * the order the profile delivered them, which for a CTF trace is timestamp
 * order, as its muxer merges the per-CPU streams that way.  So the
 * candidates for each occurrence of mx are a contiguous run of my that only
 * ever moves forward: a sweep instead of the cross product, which is what
 * keeps a trace with millions of samples analyzable.
 *
 * An occurrence with no timestamp (0, as in the aggregate JSON profiles)
 * cannot be placed in time, so it neither gets skipped nor ends a run:
 * unknown timestamps cannot disprove co-occurrence.
 */
typedef int (*occ_pair_fn)(const struct perf_dt_occ *a,
			   const struct perf_dt_occ *b, void *priv);

static int occ_for_each_pair(const struct meminfo *mx, const struct meminfo *my,
			     uint64_t window, occ_pair_fn cb, void *priv)
{
	size_t lo = 0;

	for (size_t ox = 0; ox < mx->n_occ; ox++) {
		const struct perf_dt_occ *a = &mx->occ[ox];

		while (lo < my->n_occ && a->tmin && my->occ[lo].tmax &&
		       my->occ[lo].tmax + window < a->tmin)
			lo++;

		for (size_t oy = lo; oy < my->n_occ; oy++) {
			const struct perf_dt_occ *b = &my->occ[oy];
			int ret;

			if (a->tmin && b->tmin && b->tmin > a->tmax + window)
				break;

			ret = cb(a, b, priv);
			if (ret)
				return ret;
		}
	}

	return 0;
}

/*
 * True sharing: processors referencing genuinely shared data.  Here: two
 * members of the same instance co-accessed within the group window with at
 * least one side reading.  A cacheline that is only read remains in the
 * Shared state in every CPU's cache, staying cached for longer and avoiding
 * memory traffic; the same benefit applies when a field and the lock
 * protecting it travel together (Documentation/kernel-hacking/
 * false-sharing.rst).  This is what the cacheline-group suggestion looks
 * for, on different cachelines.
 */
static int co_accessed_pair(const struct perf_dt_occ *a,
			    const struct perf_dt_occ *b,
			    void *priv __maybe_unused)
{
	/* Two writers is the false sharing case, not co-access. */
	if (a->is_write && b->is_write)
		return 0;

	/* Co-access is about one instance, so both sides must carry its id. */
	return a->instance && b->instance && a->instance == b->instance;
}

static bool members_co_accessed(const struct meminfo *mx, const struct meminfo *my)
{
	return occ_for_each_pair(mx, my, perf_dt_group_window,
				 co_accessed_pair, NULL) != 0;
}

/*
 * False sharing: processors referencing *different* data objects within the
 * same coherence block (cacheline) induce "unnecessary" coherence operations
 * (Bolosky & Scott, 1993), because the coherence protocol does not
 * distinguish individual words within a line: a write to any word
 * invalidates the entire line in every other cache.
 *
 * The kernel documentation's canonical example
 * (Documentation/kernel-hacking/false-sharing.rst, "struct foo" with
 * refcount/name) is one CPU writing a member that another CPU only reads,
 * but write-write is at least as expensive: two CPUs writing *different*
 * members of the same line ping-pong the line in Exclusive state in both
 * directions, every write taking it away from the other CPU.
 *
 * So a FALSE SHARING flag requires conflicting accesses to *different*
 * members of the same cacheline by distinct CPUs within the false sharing
 * window, at least one of them a write.  Pairs are only ever built from
 * different members, so two CPUs writing the *same* member (true sharing
 * of a hot field) never reaches this predicate.
 *
 * Confirmed when both accesses carry a matching instance id (same
 * allocation); when one or both lack an instance id it is merely suspected
 * (profiles with partial address info).  Mismatching instance ids are
 * different allocations (different physical lines), so they stay silent.
 *
 * Requires CTF per-sample data (timestamp/cpu/instance/is_write).  JSON
 * aggregate data carries only per-direction read/write totals but has no
 * per-cpu or per-instance signal (all cpu=0, instance=0), so we explicitly
 * skip it: the a->cpu == b->cpu check would accidentally suppress it, but we
 * guard on has_per_sample instead of relying on that accident.
 */
enum { FS_NONE = 0, FS_SUSPECT, FS_CONFIRMED };

struct fs_pair {
	int	result;
};

static int false_sharing_occ_pair(const struct perf_dt_occ *a,
				  const struct perf_dt_occ *b, void *priv)
{
	struct fs_pair *st = priv;

	/* Conflicting accesses: at least one of them a write. */
	if (!a->is_write && !b->is_write)
		return 0;

	/* A core does not invalidate itself, and SMT siblings share L1D. */
	if (a->cpu == b->cpu)
		return 0;

	if (a->instance && b->instance) {
		/* Different allocations are different physical lines. */
		if (a->instance != b->instance)
			return 0;

		st->result = FS_CONFIRMED;
		return 1;
	}

	/* Without an instance id on both sides it can only be suspected. */
	st->result = FS_SUSPECT;
	return 0;
}

static int false_sharing_pair(const struct meminfo *mx, const struct meminfo *my)
{
	struct fs_pair st = { .result = FS_NONE, };

	occ_for_each_pair(mx, my, perf_dt_fs_window, false_sharing_occ_pair, &st);

	return st.result;
}

static size_t cacheline__fprintf_false_sharing(FILE *fp,
					       const struct meminfo *mi,
					       size_t nmem, uint32_t ci,
					       int indent, bool has_per_sample)
{
	int fs = FS_NONE;
	size_t x, y, printed = 0;
	size_t conf_x = 0, conf_y = 0;

	if (!has_per_sample)
		return 0;

	for (x = 0; x < nmem; x++) {
		if (mi[x].ci != ci)
			continue;
		for (y = x + 1; y < nmem; y++) {
			int r;

			if (mi[y].ci != ci)
				continue;
			/* covers read-write, write-read and write-write */
			r = false_sharing_pair(&mi[x], &mi[y]);
			if (r > fs) {
				fs = r;
				conf_x = x;
				conf_y = y;
			}
			if (fs == FS_CONFIRMED)
				break;
		}
		if (fs == FS_CONFIRMED)
			break;
	}

	if (fs == FS_NONE)
		return 0;

	printed += fprintf(fp, "\n%.*s   >>> %sFALSE SHARING: cacheline %u:",
			   indent, tabs, fs == FS_SUSPECT ? "SUSPECTED " : "",
			   ci);
	printed += fprintf(fp, " %s / %s",
			   mi[conf_x].nm ?: "<anon>", mi[conf_y].nm ?: "<anon>");
	return printed;
}

/*
 * Cacheline-group suggestions: members on different cachelines that are
 * co-accessed on the same instance within overlapping time windows, with at
 * least one side reading (true sharing, see members_co_accessed()).  Moving
 * them onto the same cacheline keeps read-mostly data cached together
 * (Shared state), avoiding memory traffic.  Requires CTF per-sample data;
 * callers must check has_per_sample first.
 */
static size_t fprintf_group_hints(FILE *fp, const struct meminfo *mi,
				  size_t nmem, int indent)
{
	size_t printed = 0;

	for (size_t x = 0; x < nmem; x++) {
		for (size_t y = x + 1; y < nmem; y++) {
			if (mi[y].ci == mi[x].ci)
				continue;
			if (!mi[x].nr_reads && !mi[y].nr_reads)
				continue;
			if (members_co_accessed(&mi[x], &mi[y])) {
				printed += fprintf(fp, "\n%.*s   >>> GROUP (true sharing): %s / %s",
						   indent, tabs,
						   mi[x].nm ?: "<anon>", mi[y].nm ?: "<anon>");
				printed += fprintf(fp, " -- consider same cacheline");
			}
		}
	}
	return printed;
}

size_t perf_dt_profile__fprintf_block(FILE *fp, struct class *class,
				      const struct cu *cu, int indent)
{
	struct perf_dt_profile *p = perf_dt_profile;
	struct perf_dt_type *dt;
	const char *name = class__name(class);
	struct class_member *pos;
	size_t nmem = 0, i, printed = 0;
	struct meminfo *mi;
	uint64_t unmatched = 0;
	bool has_per_sample = false;
	bool unverified = false;

	if (!p || !name)
		return 0;
	dt = profile__find_type_for_cu(p, name, cu, class__size(class),
				       &unverified, true);
	if (!dt)
		return 0;

	type__for_each_member(&class->type, pos)
		nmem++;
	if (nmem == 0)
		return 0;
	mi = calloc(nmem, sizeof(*mi));
	if (!mi)
		return 0;

	i = 0;
	type__for_each_member(&class->type, pos) {
		mi[i].off = pos->byte_offset;
		mi[i].size = pos->byte_size;
		mi[i].nm = class_member__name(pos);
		i++;
	}

	{
		uint32_t cln = dt->cacheline_size ? dt->cacheline_size : 64;

		for (i = 0; i < nmem; i++)
			mi[i].ci = mi[i].off / cln;
	}

	/*
	 * For a normal struct members don't overlap, so the first member whose
	 * byte range contains the offset is the match.  When the profiled type
	 * itself is a union every member sits at offset 0 spanning the whole
	 * union, so the first match would always land on member 0; prefer the
	 * smallest containing member (the most specific union field).  Only
	 * the outermost type is tested: a struct that embeds an anonymous
	 * union (e.g. struct sk_buff_head) still aggregates offsets into the
	 * anonymous member's range onto that member.  Bitfields share an
	 * exact byte range and cannot be disambiguated from the
	 * byte-granular offset alone, so they still aggregate on that range's
	 * first member -- that would need bit_offset data.
	 */
	bool is_union = tag__is_union(class__tag(class));

	/* aggregate accesses onto members */
	for (size_t a = 0; a < dt->nr_accesses; a++) {
		const struct perf_dt_access *ax = &dt->accesses[a];
		size_t match = nmem; /* no match */

		if (ax->timestamp || ax->cpu || ax->instance)
			has_per_sample = true;

		for (i = 0; i < nmem; i++) {
			if (ax->offset >= mi[i].off &&
			    ax->offset < mi[i].off + mi[i].size) {
				if (!is_union) {
					match = i;
					break;
				}
				if (match == nmem || mi[i].size < mi[match].size)
					match = i;
			}
		}

		if (match != nmem) {
			struct meminfo *m = &mi[match];

			if (ax->is_write) {
				m->nr_writes += ax->nr;
				m->period_writes += ax->period;
				mi_add_occ(m, ax->instance, ax->cpu,
					   ax->timestamp, true, ax->nr);
			} else {
				m->nr_reads += ax->nr;
				m->period_reads += ax->period;
				mi_add_occ(m, ax->instance, ax->cpu,
					   ax->timestamp, false, ax->nr);
			}
		} else {
			unmatched += ax->nr;
		}
	}

	{
		bool any_hot = false;
		uint32_t cln = dt->cacheline_size ? dt->cacheline_size : 64;

		for (i = 0; i < nmem; i++) {
			if (mi[i].nr_reads || mi[i].nr_writes) {
				any_hot = true;
				break;
			}
		}
		if (!any_hot) {
			if (unmatched && !dt->warned_unmatched) {
				fprintf(stderr,
					"perf_dt: %s: %llu samples did not match any member (wrong vmlinux?)\n",
					name, (unsigned long long)unmatched);
				dt->warned_unmatched = true;
			}
			free(mi);
			return 0;
		}

		/*
		 * The JSON "size" flags a vmlinux/DWARF mismatch: if the profiled
		 * type size disagrees with the BTF/DWARF class size, the profile
		 * was collected against a different kernel image.  Only warn once
		 * per type (not per CU / per class__fprintf call) and only when we
		 * are actually going to emit an annotation.
		 */
		if (dt->size && class__size(class) &&
		    dt->size != class__size(class) && !dt->warned_size) {
			fprintf(stderr,
				"perf_dt: %s: JSON type size %u != vmlinux class size %u (vmlinux mismatch?)\n",
				name, dt->size, class__size(class));
			dt->warned_size = true;
		}

		/*
		 * Unverified: no build ID on either side to prove the profile
		 * came from this binary, so name+size matching stands in.
		 */
		if (unverified && !dt->warned_bid) {
			fprintf(stderr,
				"perf_dt: %s: no build ID to verify the profile against this binary, matching by name+size (unverified)\n",
				name);
			dt->warned_bid = true;
		}

		/*
		 * nr_reads/nr_writes count samples, not normalized events.
		 * When loads use ldlat= filtering (e.g. ldlat=30), nr_reads
		 * only counts loads exceeding that latency threshold, while
		 * nr_writes counts all sampled stores.  period_reads and
		 * period_writes estimate the underlying event count (making
		 * different sampling periods comparable), but the ldlat
		 * selection bias remains: L1 hits are absent from the data
		 * entirely, regardless of period.
		 */
		printed += fprintf(fp, "\n%.*s/* perf data-type profile (cachelines of %u bytes,"
				      " cachelines without hits omitted):",
				  indent, tabs, cln);

		/*
		 * The members are in offset order, hence ci is non-decreasing and a
		 * cacheline's members are contiguous in mi.  Only cachelines where at
		 * least one member was accessed are printed: a compact summary of the
		 * traffic, with the idle members of the printed cachelines kept as
		 * context.  Cachelines with no hits can't have false sharing, as that
		 * needs two members with accesses on the same cacheline, so skipping
		 * them skips the check too.
		 */
		for (i = 0; i < nmem; ) {
			uint32_t ci = mi[i].ci;
			size_t j, start = i;
			bool has_hits = false;

			while (i < nmem && mi[i].ci == ci) {
				if (mi[i].nr_reads || mi[i].nr_writes)
					has_hits = true;
				i++;
			}

			if (!has_hits)
				continue;

			printed += fprintf(fp, "\n%.*s   cacheline %u [%u-%u]:",
					  indent, tabs, ci,
					  ci * cln, ci * cln + cln - 1);

			for (j = start; j < i; j++) {
				printed += fprintf(fp, "\n%.*s     +%-4u %-28s sz=%-4u",
						  indent, tabs, mi[j].off,
						  mi[j].nm ?: "<anon>", mi[j].size);
				if (mi[j].nr_reads)
					printed += fprintf(fp, " nr_reads=%-5llu period_reads=%llu",
							  (unsigned long long)mi[j].nr_reads,
							  (unsigned long long)mi[j].period_reads);
				if (mi[j].nr_writes)
					printed += fprintf(fp, " nr_writes=%-5llu period_writes=%llu",
							  (unsigned long long)mi[j].nr_writes,
							  (unsigned long long)mi[j].period_writes);
			}

			printed += cacheline__fprintf_false_sharing(fp, mi, nmem, ci,
								   indent, has_per_sample);
		}

		/* Cross-cacheline grouping hints require CTF per-sample data */
		if (has_per_sample)
			printed += fprintf_group_hints(fp, mi, nmem, indent);

		printed += fprintf(fp, " */\n");
	}

	if (unmatched && !dt->warned_unmatched) {
		fprintf(stderr,
			"perf_dt: %s: %llu samples did not match any member\n",
			name, (unsigned long long)unmatched);
		dt->warned_unmatched = true;
	}

	for (i = 0; i < nmem; i++)
		zfree(&mi[i].occ);
	zfree(&mi);
	return printed;
}
