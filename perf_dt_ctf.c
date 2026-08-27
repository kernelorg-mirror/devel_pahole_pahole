/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * perf_dt_ctf.c - consume perf's data-type profiling CTF trace in pahole.
 *
 * perf emits the trace with:
 *     perf mem record -a --sample-cpu -- <workload>
 *     perf data convert --to-ctf=./ctf.dir --data-type -i perf.data
 *
 * --data-type is what makes the converter resolve the data type of every
 * memory sample and add these fields to the CTF "perf_sample" event
 * payload (a perf-side series, not upstream yet: a converter without it
 * emits only perf_ip, perf_tid, perf_pid, perf_id, perf_period and
 * perf_data_src).  The expected layout:
 *
 *     perf_sample_type          string   e.g. "struct sock", empty when
 *                                        the sample could not be resolved
 *     perf_sample_type_offset   uint64   member offset within the type
 *     perf_sample_is_write      uint64   1 == store, 0 == load
 *     perf_sample_cpu           uint64   originating CPU
 *     perf_sample_addr          uint64   data address (instance identity)
 *     perf_sample_dso_id        uint64   index into the perf_dso_info table
 *
 * plus the per-sample period, in the perf_period field the converter
 * emits when PERF_SAMPLE_PERIOD was requested (and, in --data-type mode,
 * from the attr's fixed period when it was not), so the aggregated view
 * (period_reads/period_writes) matches the JSON backend's.  DSO
 * identity travels in a one-per-DSO side event instead of in every
 * record, so the stream stays compact:
 *
 *     perf_dso_info: id (uint64), long_name (string),
 *                    build_id (string, empty when absent)
 *
 * A trace converted without --data-type carries none of these fields, and
 * one whose samples never resolved carries them with an empty type name;
 * both leave the profile empty, and perf_dt_profile__load_ctf() then fails
 * saying which of the two it was, instead of silently producing an empty
 * annotation.
 *
 * The sample timestamp comes from the event's default clock snapshot, so we
 * get per-access ordering for free.  See perf's tools/perf/util/data-convert-bt.c.
 *
 * Unlike the JSON backend (aggregate histograms for hot-field highlighting),
 * CTF carries per-sample data that enables:
 *   - False-sharing detection: conflicting accesses (at least one a write)
 *     to different members of the same cacheline by different CPUs
 *   - Cacheline-group suggestions: co-accessed fields across cachelines
 *
 * Reads the trace with libbabeltrace2 (the same library perf links to write it).
 */

#ifdef HAVE_LIBBABELTRACE2

#include <babeltrace2/babeltrace.h>
#include <babeltrace2/plugin/plugin-loading.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>

#include "dwarves.h"
#include "perf_dt.h"

/* Profile being filled (single-threaded load). */
static struct perf_dt_profile *g_ctf_profile;
/* Message iterator, created lazily on the first consume call. */
static bt_message_iterator *g_ctf_iter;

/* perf_dso_info table: perf's DSO ids -> profile DSO indices. */
struct ctf_dso_id {
	uint64_t	perf_id;
	uint32_t	idx;
};
static struct ctf_dso_id *g_ctf_dso_ids;
static size_t g_ctf_nr_dso_ids;
static size_t g_ctf_alloc_dso_ids;

/* Sample events seen: zero of them means the trace carries no
 * perf_sample_type field at all, i.e. it was not converted with
 * 'perf data convert --data-type'.
 */
static uint64_t g_ctf_nr_samples;

static uint64_t ctf_u64(const bt_field *f)
{
	if (!f)
		return 0;
	return bt_field_integer_unsigned_get_value(f);
}

/* Remember that perf's DSO id 'perf_id' is the profile's DSO 'idx'. */
static void ctf_dso_id__add(uint64_t perf_id, uint32_t idx)
{
	if (g_ctf_nr_dso_ids == g_ctf_alloc_dso_ids) {
		size_t n = g_ctf_alloc_dso_ids ? g_ctf_alloc_dso_ids * 2 : 4;
		struct ctf_dso_id *d = realloc(g_ctf_dso_ids, n * sizeof(*d));

		if (!d) {
			perf_dt__oom_dropping("CTF DSO ids");
			return;
		}
		g_ctf_dso_ids = d;
		g_ctf_alloc_dso_ids = n;
	}
	g_ctf_dso_ids[g_ctf_nr_dso_ids].perf_id = perf_id;
	g_ctf_dso_ids[g_ctf_nr_dso_ids].idx = idx;
	g_ctf_nr_dso_ids++;
}

static uint32_t ctf_dso_id__find(uint64_t perf_id)
{
	size_t i;

	for (i = 0; i < g_ctf_nr_dso_ids; i++)
		if (g_ctf_dso_ids[i].perf_id == perf_id)
			return g_ctf_dso_ids[i].idx;
	return UINT32_MAX;
}

/* Whether the field is there and is a string field. */
static bool ctf_is_string(const bt_field *f)
{
	return f && bt_field_class_get_type(bt_field_borrow_class_const(f)) ==
		    BT_FIELD_CLASS_TYPE_STRING;
}

/*
 * A perf_dso_info side event: one per DSO the converter resolved types in,
 * carrying the same identity as the JSON backend's "dso"/"build_id" fields
 * (an empty build_id string means the DSO has none).  Recorded in the
 * perf-id -> profile-DSO map so perf_sample records can reference it.
 */
static void process_dso_info(const bt_field *payload)
{
	const bt_field *f_id, *f_name, *f_bid;
	const char *long_name, *build_id = NULL;
	uint32_t idx;

	f_name = bt_field_structure_borrow_member_field_by_name_const(
			payload, "long_name");
	if (!ctf_is_string(f_name))
		return;
	f_id = bt_field_structure_borrow_member_field_by_name_const(
			payload, "id");
	long_name = bt_field_string_get_value(f_name);
	if (!long_name)
		return;

	f_bid = bt_field_structure_borrow_member_field_by_name_const(
			payload, "build_id");
	if (ctf_is_string(f_bid)) {
		build_id = bt_field_string_get_value(f_bid);
		if (build_id && !*build_id)
			build_id = NULL;
	}

	idx = perf_dt_profile__find_or_add_dso(g_ctf_profile, long_name,
					       build_id);
	if (idx != UINT32_MAX)
		ctf_dso_id__add(ctf_u64(f_id), idx);
}

/*
 * The DSO a perf_sample record was resolved in: the perf_dso_info entry its
 * perf_sample_dso_id references.  Absent field or unknown id (the trace
 * predates perf_dso_info, or its side event hasn't been seen yet) means one
 * unknown DSO: no build ID, so annotating falls back to name+size matching,
 * unverified.
 */
static uint32_t sample_dso(const bt_field *payload)
{
	const bt_field *f_dso_id = bt_field_structure_borrow_member_field_by_name_const(
					payload, "perf_sample_dso_id");
	uint32_t idx = ctf_dso_id__find(ctf_u64(f_dso_id));

	if (f_dso_id && idx != UINT32_MAX)
		return idx;
	return perf_dt_profile__find_or_add_dso(g_ctf_profile, NULL, NULL);
}

static void strip_kind_prefix(char *name)
{
	size_t off = 0;

	if (strncmp(name, "struct ", 7) == 0)
		off = 7;
	else if (strncmp(name, "union ", 6) == 0)
		off = 6;
	if (off)
		memmove(name, name + off, strlen(name + off) + 1);
}

static void process_event(const bt_message *msg)
{
	const bt_event *ev;
	const bt_field *payload, *f_type, *f_off, *f_wr, *f_cpu, *f_addr,
		       *f_period;
	const bt_clock_snapshot *cs;
	uint64_t off = 0, wr = 0, addr = 0, period = 0;
	uint32_t cpu = 0;
	int64_t ts = 0;
	const char *type_str;
	char *name;

	ev = bt_message_event_borrow_event_const(msg);
	payload = bt_event_borrow_payload_field_const(ev);
	if (!payload)
		return;

	f_type = bt_field_structure_borrow_member_field_by_name_const(
				payload, "perf_sample_type");
	if (!f_type) {
		/* Not a perf_sample event: maybe a perf_dso_info side event. */
		process_dso_info(payload);
		return;
	}
	type_str = bt_field_string_get_value(f_type);
	g_ctf_nr_samples++;
	/*
	 * An empty name is how perf's converter marks a sample it could not
	 * resolve (no debug info for that DSO, an instruction without a
	 * memory operand): skipping it keeps the trace a faithful, lossless
	 * conversion of perf.data while the profile stays free of nameless
	 * types, and a trace where nothing resolved is then the loud
	 * empty-profile error instead of a silent, empty annotation.
	 */
	if (!type_str || !*type_str)
		return;

	f_off  = bt_field_structure_borrow_member_field_by_name_const(
				payload, "perf_sample_type_offset");
	f_wr   = bt_field_structure_borrow_member_field_by_name_const(
				payload, "perf_sample_is_write");
	f_cpu  = bt_field_structure_borrow_member_field_by_name_const(
				payload, "perf_sample_cpu");
	f_addr = bt_field_structure_borrow_member_field_by_name_const(
				payload, "perf_sample_addr");
	f_period = bt_field_structure_borrow_member_field_by_name_const(
				payload, "perf_period");

	off  = ctf_u64(f_off);
	wr   = ctf_u64(f_wr);
	cpu  = (uint32_t)ctf_u64(f_cpu);
	addr = ctf_u64(f_addr);
	/* The converter emits it when PERF_SAMPLE_PERIOD was requested. */
	period = ctf_u64(f_period);
	cs = bt_message_event_borrow_default_clock_snapshot_const(msg);
	if (!cs || bt_clock_snapshot_get_ns_from_origin(cs, &ts) !=
	    BT_CLOCK_SNAPSHOT_GET_NS_FROM_ORIGIN_STATUS_OK)
		ts = 0;

	name = strdup(type_str);
	if (name) {
		/* Instance identity: base ~= addr - offset, so
		 * records hitting the same allocation share it
		 * (plan B1); addr == 0 means unknown, and an addr
		 * not past the offset can't be a base either, so
		 * treat it as unknown instead of wrapping around
		 * to a bogus instance.
		 */
		uint64_t inst = addr > off ? addr - off : 0;
		uint32_t dso = sample_dso(payload);

		strip_kind_prefix(name);
		if (dso != UINT32_MAX) {
			struct perf_dt_type *dt;

			/*
			 * Cacheline size to group on: unlike the JSON
			 * profile, a CTF stream carries no "machine" entry,
			 * so the x86 64 is assumed; when the per-sample
			 * fields land in perf the trace (or its
			 * environment) should say which size the data was
			 * collected with.
			 */
			dt = perf_dt_profile__find_or_add_type(g_ctf_profile,
							       dso, name, 64, 0);
			if (dt)
				perf_dt_type__add_access(dt, off, 1, period,
							 (uint64_t)ts, cpu,
							 inst, wr != 0);
		}
		free(name);
	}
}

static bt_component_class_sink_consume_method_status
sink_consume(bt_self_component_sink *self_comp)
{
	bt_message_array_const msgs;
	uint64_t count, i;
	bt_message_iterator_next_status next_st;

	if (!g_ctf_iter) {
		bt_self_component_port_input *in =
			bt_self_component_sink_borrow_input_port_by_index(self_comp, 0);
		bt_message_iterator_create_from_sink_component_status cs;

		if (!in)
			return BT_COMPONENT_CLASS_SINK_CONSUME_METHOD_STATUS_ERROR;
		cs = bt_message_iterator_create_from_sink_component(self_comp,
								   in, &g_ctf_iter);
		if (cs != BT_MESSAGE_ITERATOR_CREATE_FROM_SINK_COMPONENT_STATUS_OK)
			return BT_COMPONENT_CLASS_SINK_CONSUME_METHOD_STATUS_ERROR;
	}

	next_st = bt_message_iterator_next(g_ctf_iter, &msgs, &count);
	if (next_st == BT_MESSAGE_ITERATOR_NEXT_STATUS_END)
		return BT_COMPONENT_CLASS_SINK_CONSUME_METHOD_STATUS_END;
	if (next_st != BT_MESSAGE_ITERATOR_NEXT_STATUS_OK)
		return BT_COMPONENT_CLASS_SINK_CONSUME_METHOD_STATUS_ERROR;

	for (i = 0; i < count; i++) {
		const bt_message *msg = msgs[i];

		if (bt_message_get_type(msg) == BT_MESSAGE_TYPE_EVENT)
			process_event(msg);
		bt_message_put_ref(msg);
	}
	return BT_COMPONENT_CLASS_SINK_CONSUME_METHOD_STATUS_OK;
}

static bt_component_class_initialize_method_status
sink_init(bt_self_component_sink *self_comp,
	  bt_self_component_sink_configuration *config,
	  const bt_value *params, void *initialize_method_data)
{
	(void)config; (void)params; (void)initialize_method_data;

	/* The ctf.fs source names ports after the stream, so we connect by
	 * object, but our input port still needs a stable identity: index 0.
	 */
	return bt_self_component_sink_add_input_port(self_comp, "in", NULL,
						     NULL) ==
	       BT_SELF_COMPONENT_ADD_PORT_STATUS_OK ?
	       BT_COMPONENT_CLASS_INITIALIZE_METHOD_STATUS_OK :
	       BT_COMPONENT_CLASS_INITIALIZE_METHOD_STATUS_ERROR;
}

int perf_dt_profile__load_ctf(const char *dir)
{
	bt_graph *graph;
	bt_value *inputs, *src_params, *sink_params;
	const bt_component_source *src = NULL;
	const bt_component_sink *sink = NULL;
	bt_component_class_sink *sink_class;
	const bt_port_output *out;
	const bt_port_input *in;
	uint64_t nr_out_ports, p;
	bt_graph_add_component_status add_st;
	bt_graph_connect_ports_status conn_st;
	bt_graph_run_status run_st;
	int ret = -1;
	/* Suppress the generic "failed to read" message: the empty-profile
	 * path prints its own, more specific one.
	 */
	bool empty_profile = false;

	g_ctf_profile = zalloc(sizeof(*g_ctf_profile));
	g_ctf_iter = NULL;
	if (!g_ctf_profile)
		return -1;

	graph = bt_graph_create(0);
	if (!graph)
		goto out_free;

	inputs = bt_value_array_create();
	bt_value_array_append_string_element(inputs, dir);
	src_params = bt_value_map_create();
	bt_value_map_insert_entry(src_params, "inputs", inputs);

	{
		const bt_plugin *plugin = NULL;
		const bt_component_class_source *cc = NULL;

		bt_plugin_find("ctf", BT_TRUE, BT_TRUE, BT_TRUE, BT_TRUE,
			       BT_FALSE, &plugin);
		if (plugin)
			cc = bt_plugin_borrow_source_component_class_by_name_const(
					plugin, "fs");
		if (cc)
			add_st = bt_graph_add_source_component(graph, cc, "fs",
							       src_params,
							       BT_LOGGING_LEVEL_NONE,
							       &src);
		else
			add_st = BT_GRAPH_ADD_COMPONENT_STATUS_ERROR;
		if (plugin)
			bt_plugin_put_ref(plugin);
	}
	/* The source component holds its own references from here on,
	 * whether or not the add succeeded.
	 */
	bt_value_put_ref(src_params);
	bt_value_put_ref(inputs);
	if (add_st != BT_GRAPH_ADD_COMPONENT_STATUS_OK)
		goto out_graph;

	sink_class = bt_component_class_sink_create("pahole-ctf-sink",
						    sink_consume);
	if (!sink_class)
		goto out_graph;
	bt_component_class_sink_set_initialize_method(sink_class, sink_init);
	sink_params = bt_value_map_create();
	add_st = bt_graph_add_sink_component(graph, sink_class, "sink",
					     sink_params, BT_LOGGING_LEVEL_NONE,
					     &sink);
	/* The sink component holds its own references from here on. */
	bt_value_put_ref(sink_params);
	bt_component_class_sink_put_ref(sink_class);
	if (add_st != BT_GRAPH_ADD_COMPONENT_STATUS_OK)
		goto out_graph;

	in  = bt_component_sink_borrow_input_port_by_name_const(sink, "in");
	if (!in)
		goto out_graph;

	/* Connect every stream the trace has.  One output port goes straight
	 * to the sink; several go through utils.muxer to merge them.
	 */
	nr_out_ports = bt_component_source_get_output_port_count(src);
	out = bt_component_source_borrow_output_port_by_index_const(src, 0);
	if (!out)
		goto out_graph;

	if (nr_out_ports == 1) {
		conn_st = bt_graph_connect_ports(graph, out, in, NULL);
		if (conn_st != BT_GRAPH_CONNECT_PORTS_STATUS_OK)
			goto out_graph;
	} else {
		const bt_plugin *uplugin = NULL;
		const bt_component_class_filter *ucc = NULL;
		const bt_component_filter *muxer = NULL;

		bt_plugin_find("utils", BT_TRUE, BT_TRUE, BT_TRUE, BT_TRUE,
			       BT_FALSE, &uplugin);
		if (uplugin)
			ucc = bt_plugin_borrow_filter_component_class_by_name_const(
					uplugin, "muxer");
		if (!ucc) {
			if (uplugin)
				bt_plugin_put_ref(uplugin);
			goto out_graph;
		}
		add_st = bt_graph_add_filter_component(graph, ucc, "muxer",
						       NULL,
						       BT_LOGGING_LEVEL_NONE,
						       &muxer);
		bt_plugin_put_ref(uplugin);
		if (add_st != BT_GRAPH_ADD_COMPONENT_STATUS_OK)
			goto out_graph;

		/*
		 * utils.muxer adds a new input port whenever its last one
		 * gets connected, so the next free port is always the last
		 * one; re-query the count each round instead of relying on
		 * that grow-on-connect behavior.
		 */
		for (p = 0; p < nr_out_ports; p++) {
			const bt_port_input *min;
			uint64_t nr_in = bt_component_filter_get_input_port_count(muxer);

			if (nr_in == 0)
				goto out_graph;
			min = bt_component_filter_borrow_input_port_by_index_const(muxer, nr_in - 1);
			if (!min)
				goto out_graph;
			out = bt_component_source_borrow_output_port_by_index_const(src, p);
			if (!out)
				goto out_graph;
			conn_st = bt_graph_connect_ports(graph, out, min, NULL);
			if (conn_st != BT_GRAPH_CONNECT_PORTS_STATUS_OK)
				goto out_graph;
		}
		/* Merge the muxed streams back into the sink's single input. */
		out = bt_component_filter_borrow_output_port_by_index_const(muxer, 0);
		if (!out)
			goto out_graph;
		conn_st = bt_graph_connect_ports(graph, out, in, NULL);
		if (conn_st != BT_GRAPH_CONNECT_PORTS_STATUS_OK)
			goto out_graph;
	}

	run_st = bt_graph_run(graph);
	if (g_ctf_iter) {
		bt_message_iterator_put_ref(g_ctf_iter);
		g_ctf_iter = NULL;
	}
	if (run_st != BT_GRAPH_RUN_STATUS_OK)
		goto out_graph;

	/*
	 * An empty profile has two causes worth telling apart: a trace
	 * converted without 'perf data convert --data-type' carries no
	 * perf_sample_type field at all, and one converted with it whose
	 * samples never resolved carries that field empty in every record.
	 * Failing loudly with the reason beats silently annotating nothing.
	 */
	if (g_ctf_profile->nr_types == 0) {
		if (g_ctf_nr_samples == 0)
			fprintf(stderr,
				"perf_dt_ctf: '%s' has no perf_sample_type fields: convert perf.data with 'perf data convert --to-ctf=DIR --data-type'\n",
				dir);
		else
			fprintf(stderr,
				"perf_dt_ctf: '%s' has %" PRIu64 " samples but none with a resolved data type: the profiled binaries need debug info, and the samples a data address ('perf mem record', or 'perf record -d --sample-cpu')\n",
				dir, g_ctf_nr_samples);
		ret = -1;
		empty_profile = true;
	} else {
		perf_dt_profile__set(g_ctf_profile);
		g_ctf_profile = NULL;
		ret = 0;
	}

out_graph:
	bt_graph_put_ref(graph);
	if (ret != 0 && !empty_profile)
		fprintf(stderr, "perf_dt_ctf: failed to read CTF trace '%s'\n",
			dir);
out_free:
	/*
	 * Also reached on success: g_ctf_profile is NULL there, its
	 * ownership transferred by perf_dt_profile__set(), so only the
	 * perf-id -> profile-DSO map is left to release.
	 */
	perf_dt_profile__delete(g_ctf_profile);
	g_ctf_profile = NULL;
	g_ctf_nr_dso_ids = 0;
	g_ctf_alloc_dso_ids = 0;
	zfree(&g_ctf_dso_ids);
	return ret;
}

#endif /* HAVE_LIBBABELTRACE2 */
