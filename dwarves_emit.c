/*
  SPDX-License-Identifier: GPL-2.0-only

  Copyright (C) 2006 Mandriva Conectiva S.A.
  Copyright (C) 2006 Arnaldo Carvalho de Melo <acme@mandriva.com>
  Copyright (C) 2007 Red Hat Inc.
  Copyright (C) 2007 Arnaldo Carvalho de Melo <acme@redhat.com>
*/

#include <string.h>

#include "list.h"
#include "dwarves_emit.h"
#include "dwarves.h"

static void type__emit_template_pack_param(const struct type *ctype,
					   const struct cu *cu, FILE *fp)
{
	struct template_parameter_pack *pack = ctype->template_parameter_pack;

	if (list_empty(&pack->params)) {
		fprintf(fp, "typename... %s", pack->name ?: "");
		return;
	}

	struct tag *first_param = list_first_entry(&pack->params, struct tag, node);

	if (first_param->tag == DW_TAG_template_type_parameter) {
		fprintf(fp, "typename... %s", pack->name ?: "");
	} else if (first_param->tag == DW_TAG_template_value_parameter) {
		struct template_value_param *vp = (struct template_value_param *)first_param;
		char type_name[128];
		struct tag *ptype = cu__type(cu, vp->tag.type);

		if (ptype == NULL) {
			fprintf(fp, "typename... %s", pack->name ?: "");
		} else {
			fprintf(fp, "%s... %s",
				tag__name(ptype, cu, type_name, sizeof(type_name), NULL),
				pack->name ?: "");
		}
	} else {
		fprintf(fp, "typename... %s", pack->name ?: "");
	}
}

/**
 * type__emit_template_fwd_decl - emit a C++ primary template forward declaration
 * @ctype: the type whose template parameters to emit
 * @cu: the compilation unit (needed to resolve parameter types)
 * @fp: output file
 *
 * For a type like "FixedArray<int, 10>" with template parameters T=int, N=10,
 * this emits:
 *
 *   template<typename T, int N>
 *   struct FixedArray;
 *
 * This forward declaration is required before an explicit specialization
 * (template<> struct FixedArray<int, 10> { ... };) can appear in valid C++.
 *
 * The parameter list is built from the structured DWARF template parameter
 * DIEs rather than from the instantiated name, so we get the original
 * parameter names (T, N, Ts) and kinds (typename vs value type).
 *
 * Handles DW_TAG_template_type_parameter ("typename T"),
 * DW_TAG_template_value_parameter ("int N"), and
 * DW_TAG_template_parameter_pack ("typename... Ts" or "int... Ns").
 *
 * Returns true if the primary was emitted, false if a pre-condition failed
 * (unresolvable base name or value parameter type).  When false, callers must
 * not emit a template<> specialization prefix — that would produce invalid C++.
 */
static bool type__emit_template_fwd_decl(struct type *ctype,
					  const struct cu *cu, FILE *fp)
{
	char base_name[256];
	bool first = true;

	if (ctype->primary_template_emitted)
		return true;

	if (type__base_name(ctype, base_name, sizeof(base_name)) == NULL)
		return false;

	/* Bail if any value param type can't be resolved — emitting
	 * "void N" would produce uncompilable output. */
	struct template_value_param *check;
	list_for_each_entry(check, &ctype->template_value_params, tag.node) {
		if (cu__type(cu, check->tag.type) == NULL)
			return false;
	}

	/* Same check for value params inside a parameter pack */
	struct template_parameter_pack *pack_check = ctype->template_parameter_pack;
	if (pack_check != NULL && !list_empty(&pack_check->params)) {
		struct tag *first_param = list_first_entry(&pack_check->params,
							   struct tag, node);
		if (first_param->tag == DW_TAG_template_value_parameter) {
			struct template_value_param *vp =
				(struct template_value_param *)first_param;
			if (cu__type(cu, vp->tag.type) == NULL)
				return false;
		}
	}

	fputs("template<", fp);

	/*
	 * Merge-iterate type params, value params, and pack in declaration
	 * order.  DWARF stores them as separate tag types, so they land on
	 * separate lists, but the decl_order field (set during DWARF loading)
	 * preserves the original declaration order across all three.
	 */
	struct template_type_param *ttp = list_empty(&ctype->template_type_params) ? NULL :
		list_first_entry(&ctype->template_type_params, struct template_type_param, tag.node);
	struct template_value_param *tvp = list_empty(&ctype->template_value_params) ? NULL :
		list_first_entry(&ctype->template_value_params, struct template_value_param, tag.node);
	struct template_parameter_pack *pack = ctype->template_parameter_pack;
	bool pack_emitted = (pack == NULL);

	while (ttp != NULL || tvp != NULL || !pack_emitted) {
		uint16_t ttp_ord = ttp ? ttp->decl_order : UINT16_MAX;
		uint16_t tvp_ord = tvp ? tvp->decl_order : UINT16_MAX;
		uint16_t pack_ord = !pack_emitted ? pack->decl_order : UINT16_MAX;

		if (!first)
			fputs(", ", fp);

		if (ttp != NULL && ttp_ord <= tvp_ord && ttp_ord <= pack_ord) {
			fprintf(fp, "typename %s", ttp->name ?: "");
			ttp = (ttp->tag.node.next == &ctype->template_type_params) ? NULL :
				list_next_entry(ttp, tag.node);
		} else if (tvp != NULL && tvp_ord <= ttp_ord && tvp_ord <= pack_ord) {
			char type_name[128];
			struct tag *ptype = cu__type(cu, tvp->tag.type);

			fprintf(fp, "%s %s",
				tag__name(ptype, cu, type_name, sizeof(type_name), NULL),
				tvp->name ?: "");
			tvp = (tvp->tag.node.next == &ctype->template_value_params) ? NULL :
				list_next_entry(tvp, tag.node);
		} else {
			type__emit_template_pack_param(ctype, cu, fp);
			pack_emitted = true;
		}

		first = false;
	}

	fprintf(fp, ">\n%s %s;\n\n",
		tag__is_union(&ctype->namespace.tag) ? "union" : "struct",
		base_name);

	ctype->primary_template_emitted = 1;
	return true;
}

void type_emissions__init(struct type_emissions *emissions, struct conf_fprintf *conf_fprintf)
{
	INIT_LIST_HEAD(&emissions->base_type_definitions);
	INIT_LIST_HEAD(&emissions->definitions);
	INIT_LIST_HEAD(&emissions->fwd_decls);
	emissions->conf_fprintf = conf_fprintf;
}

static void type_emissions__add_definition(struct type_emissions *emissions,
					   struct type *type)
{
	type->definition_emitted = 1;
	if (!list_empty(&type->node))
		list_del(&type->node);
	list_add_tail(&type->node, &emissions->definitions);
}

static void type_emissions__add_fwd_decl(struct type_emissions *emissions,
					 struct type *type)
{
	type->fwd_decl_emitted = 1;
	if (list_empty(&type->node))
		list_add_tail(&type->node, &emissions->fwd_decls);
}

struct type *type_emissions__find_definition(const struct type_emissions *emissions,
					     uint16_t tag, const char *name)
{
	struct type *pos;

	if (name == NULL)
		return NULL;

	list_for_each_entry(pos, &emissions->definitions, node)
		if (type__tag(pos)->tag == tag &&
		    type__name(pos) != NULL &&
		    strcmp(type__name(pos), name) == 0)
			return pos;

	return NULL;
}

static bool type__can_have_shadow_definition(struct type *type)
{
	struct tag *tag = type__tag(type);

	return tag__is_struct(tag) || tag__is_union(tag) || tag__is_enumeration(tag);
}

// Find if 'struct foo' is defined with a pre-existing 'enum foo', 'union foo', etc
struct type *type_emissions__find_shadow_definition(const struct type_emissions *emissions,
						    uint16_t tag, const char *name)
{
	struct type *pos;

	if (name == NULL)
		return NULL;

	list_for_each_entry(pos, &emissions->definitions, node) {
		if (type__tag(pos)->tag != tag &&
		    type__name(pos) != NULL &&
		    type__can_have_shadow_definition(pos) &&
		    strcmp(type__name(pos), name) == 0)
			return pos;
	}

	return NULL;
}

static struct type *type_emissions__find_fwd_decl(const struct type_emissions *emissions,
						  const char *name)
{
	struct type *pos;

	if (name == NULL)
		return NULL;

	list_for_each_entry(pos, &emissions->fwd_decls, node) {
		const char *curr_name = type__name(pos);

		if (curr_name && strcmp(curr_name, name) == 0)
			return pos;
	}

	return NULL;
}

static int enumeration__emit_definitions(struct tag *tag, const struct cu *cu,
					 struct type_emissions *emissions,
					 const struct conf_fprintf *conf,
					 FILE *fp)
{
	struct type *etype = tag__type(tag);

	/* Have we already emitted this in this CU? */
	if (etype->definition_emitted)
		return 0;

	/* Ok, lets look at the previous CUs: */
	if (type_emissions__find_definition(emissions, DW_TAG_enumeration_type, type__name(etype)) != NULL) {
		/*
		 * Yes, so lets mark it visited on this CU too,
		 * to speed up the lookup.
		 */
		etype->definition_emitted = 1;
		return 0;
	}

	/* Rust enum methods (DW_TAG_subprogram) are valid for pretty-printing
	 * but produce uncompilable C; suppress them in the emit path. */
	struct conf_fprintf econf = *conf;
	econf.skip_enum_subprograms = 1;
	enumeration__fprintf(tag, cu, &econf, fp);
	fputs(";\n", fp);

	// See comment on enumeration__fprintf(), it seems this happens with DWARF as well
	// or BTF doesn't have type->declaration set because DWARF didn't have it set.
	// But we consider type->nr_members == 0 as just a forward declaration, so don't
	// mark it as defined because we may need it to __really__ printf it later.
	if (etype->nr_members != 0)
		type_emissions__add_definition(emissions, etype);
	return 1;
}

static int tag__emit_definitions(struct tag *tag, struct cu *cu,
				 struct type_emissions *emissions, FILE *fp);

static int typedef__emit_definitions(struct tag *tdef, struct cu *cu,
				     struct type_emissions *emissions, FILE *fp)
{
	struct type *def = tag__type(tdef);
	struct tag *type, *ptr_type;

	/* Have we already emitted this in this CU? */
	if (def->definition_emitted)
		return 0;

	/* Ok, lets look at the previous CUs: */
	if (type_emissions__find_definition(emissions, DW_TAG_typedef, type__name(def)) != NULL) {
		/*
		 * Yes, so lets mark it visited on this CU too,
		 * to speed up the lookup.
		 */
		def->definition_emitted = 1;
		return 0;
	}

	type = cu__type(cu, tdef->type);
	if (type == NULL) // void
		goto emit;

	switch (type->tag) {
	case DW_TAG_atomic_type:
		type = cu__type(cu, tdef->type);
		if (type)
			tag__emit_definitions(type, cu, emissions, fp);
		else
			fprintf(stderr, "%s: couldn't find the type pointed from _Atomic for '%s'\n", __func__, type__name(def));
		break;
	case DW_TAG_array_type:
		tag__emit_definitions(type, cu, emissions, fp);
		break;
	case DW_TAG_typedef:
		typedef__emit_definitions(type, cu, emissions, fp);
		break;
	case DW_TAG_pointer_type:
		ptr_type = cu__type(cu, type->type);
		/* void ** can make ptr_type be NULL */
		if (ptr_type == NULL)
			break;
		if (ptr_type->tag == DW_TAG_typedef) {
			typedef__emit_definitions(ptr_type, cu, emissions, fp);
			break;
		} else if (ptr_type->tag != DW_TAG_subroutine_type)
			break;
		type = ptr_type;
		/* Fall thru */
	case DW_TAG_subroutine_type:
		ftype__emit_definitions(tag__ftype(type), cu, emissions, fp);
		break;
	case DW_TAG_enumeration_type: {
		struct type *ctype = tag__type(type);
		struct conf_fprintf conf = {
			.suffix = NULL,
		};

		if (type__name(ctype) == NULL) {
			fputs("typedef ", fp);
			conf.suffix = type__name(def);
			enumeration__emit_definitions(type, cu, emissions, &conf, fp);
			goto out;
		} else
			enumeration__emit_definitions(type, cu, emissions, &conf, fp);
	}
		break;
	case DW_TAG_structure_type:
	case DW_TAG_union_type: {
		struct type *ctype = tag__type(type);

		if (type__name(ctype) == NULL) {
			type__emit_definitions(type__tag(ctype), cu, emissions, fp);
			type__emit(type__tag(ctype), cu, "typedef", type__name(def), emissions, fp);
			goto out;
		} else if (type__emit_definitions(type, cu, emissions, fp))
			type__emit(type, cu, NULL, NULL, emissions, fp);
	}
	}

	/*
	 * Recheck if the typedef was emitted, as there are cases, like
	 * wait_queue_t in the Linux kernel, that is against struct
	 * __wait_queue, that has a wait_queue_func_t member, a function
	 * typedef that has as one of its parameters a... wait_queue_t, that
	 * will thus be emitted before the function typedef, making a no go to
	 * redefine the typedef after struct __wait_queue.
	 */
emit:
	if (!def->definition_emitted) {
		typedef__fprintf(tdef, cu, NULL, fp);
		fputs(";\n", fp);
	}
out:
	type_emissions__add_definition(emissions, def);
	return 1;
}

static int type__emit_fwd_decl(struct type *ctype, const struct cu *cu,
			       struct type_emissions *emissions, FILE *fp)
{
	/* Have we already emitted this in this CU? */
	if (ctype->fwd_decl_emitted)
		return 0;

	const char *name = type__name(ctype);
	if (name == NULL)
		return 0;

	/* Ok, lets look at the previous CUs: */
	if (type_emissions__find_fwd_decl(emissions, name) != NULL) {
		/*
		 * Yes, so lets mark it visited on this CU too,
		 * to speed up the lookup.
		 */
		ctype->fwd_decl_emitted = 1;
		return 0;
	}

	if (strchr(name, '<') &&
	    emissions->conf_fprintf &&
	    emissions->conf_fprintf->emit_template_declarations) {
		/*
		 * C++ requires the primary template to be declared
		 * before any explicit specialization.  If we can't
		 * reconstruct the primary, skip this declaration
		 * entirely — both "struct Foo<int>;" and
		 * "template<> struct Foo<int>;" are ill-formed
		 * without a preceding primary template.
		 */
		if (cu == NULL || !type__has_template_params(ctype) ||
		    !type__emit_template_fwd_decl(ctype, cu, fp)) {
			fprintf(fp, "/* skipped: primary template for %s not reconstructible */\n",
				name);
			ctype->fwd_decl_emitted = 1;
			return 0;
		}
		fputs("template<> ", fp);
	}

	fprintf(fp, "%s %s;\n",
		tag__is_union(&ctype->namespace.tag) ? "union" : "struct",
		name);
	type_emissions__add_fwd_decl(emissions, ctype);
	return 1;
}

static struct base_type *base_type_emissions__find_definition(const struct type_emissions *emissions, const char *name)
{
	struct base_type *pos;

	if (name == NULL)
		return NULL;

	list_for_each_entry(pos, &emissions->base_type_definitions, node)
		if (strcmp(__base_type__name(pos), name) == 0)
			return pos;

	return NULL;
}

static void base_type_emissions__add_definition(struct type_emissions *emissions, struct base_type *type)
{
	type->definition_emitted = 1;
	if (!list_empty(&type->node))
		list_del(&type->node);
	list_add_tail(&type->node, &emissions->base_type_definitions);
}

static const char *base_type__stdint2simple(const char *name)
{
	if (strcmp(name, "int32_t") == 0)
		return "int";
	if (strcmp(name, "int16_t") == 0)
		return "short";
	if (strcmp(name, "int8_t") == 0)
		return "char";
	if (strcmp(name, "int64_t") == 0)
		return "long";
	return name;
}

static int base_type__emit_definitions(struct base_type *type, struct type_emissions *emissions, FILE *fp)
{
#define base_type__prefix "atomic_"
	const size_t prefixlen = sizeof(base_type__prefix) - 1;
	const char *name = __base_type__name(type);

	// See if it was already emitted in this CU
	if (type->definition_emitted)
		return 0;

	// We're only emitting for "atomic_" prefixed base types
	if (strncmp(name, base_type__prefix, prefixlen) != 0)
		return 0;

	// See if it was already emitted in another CU
	if (base_type_emissions__find_definition(emissions, name)) {
		type->definition_emitted = 1;
		return 0;
	}

	const char *non_atomic_name = name + prefixlen;

	fputs("typedef _Atomic", fp);

	if (non_atomic_name[0] == 's' &&
	    non_atomic_name[1] != 'i' && non_atomic_name[1] != 'h') // exclude atomic_size_t and atomic_short
		fprintf(fp, " signed %s", non_atomic_name + 1);
	else if (non_atomic_name[0] == 'l' && non_atomic_name[1] == 'l')
		fprintf(fp, " long long");
	else if (non_atomic_name[0] == 'u') {
		fprintf(fp, " unsigned");
		if (non_atomic_name[1] == 'l') {
			fprintf(fp, " long");
			if (non_atomic_name[2] == 'l')
				fprintf(fp, " long");
		} else
			fprintf(fp, " %s", base_type__stdint2simple(non_atomic_name + 1));
	} else if (non_atomic_name[0] == 'b')
		fprintf(fp, " _Bool");
	else
		fprintf(fp, " %s", base_type__stdint2simple(non_atomic_name));

	fprintf(fp, " %s;\n", name);

	base_type_emissions__add_definition(emissions, type);
	return 1;

#undef base_type__prefix
}

static int tag__emit_definitions(struct tag *tag, struct cu *cu,
				 struct type_emissions *emissions, FILE *fp)
{
	struct tag *type = cu__type(cu, tag->type);
	int pointer = 0;

	if (type == NULL)
		return 0;
next_indirection:
	switch (type->tag) {
	case DW_TAG_base_type:
		if (emissions->conf_fprintf && emissions->conf_fprintf->skip_emitting_atomic_typedefs)
			return 0;
		return base_type__emit_definitions(tag__base_type(type), emissions, fp);
	case DW_TAG_pointer_type:
	case DW_TAG_reference_type:
		pointer = 1;
		/* Fall thru */
	case DW_TAG_array_type:
	case DW_TAG_const_type:
	case DW_TAG_volatile_type:
	case DW_TAG_atomic_type:
		type = cu__type(cu, type->type);
		if (type == NULL)
			return 0;
		goto next_indirection;
	case DW_TAG_typedef:
		return typedef__emit_definitions(type, cu, emissions, fp);
	case DW_TAG_enumeration_type:
		if (type__name(tag__type(type)) != NULL) {
			struct conf_fprintf conf = {
				.suffix = NULL,
			};
			return enumeration__emit_definitions(type, cu, emissions, &conf, fp);
		}
		break;
	case DW_TAG_structure_type:
	case DW_TAG_union_type:
		if (pointer) {
			/*
			 * Struct defined inline, no name, need to have its
			 * members types emitted.
			 */
			if (type__name(tag__type(type)) == NULL)
				type__emit_definitions(type, cu, emissions, fp);

			return type__emit_fwd_decl(tag__type(type), cu, emissions, fp);
		}
		if (type__emit_definitions(type, cu, emissions, fp))
			type__emit(type, cu, NULL, NULL, emissions, fp);
		return 1;
	case DW_TAG_subroutine_type:
		return ftype__emit_definitions(tag__ftype(type), cu,
					       emissions, fp);
	}

	return 0;
}

int ftype__emit_definitions(struct ftype *ftype, struct cu *cu,
			    struct type_emissions *emissions, FILE *fp)
{
	struct parameter *pos;
	/* First check the function return type */
	int printed = tag__emit_definitions(&ftype->tag, cu, emissions, fp);

	/* Then its parameters */
	list_for_each_entry(pos, &ftype->parms, tag.node)
		if (tag__emit_definitions(&pos->tag, cu, emissions, fp))
			printed = 1;

	if (printed)
		fputc('\n', fp);
	return printed;
}

int type__emit_definitions(struct tag *tag, struct cu *cu,
			   struct type_emissions *emissions, FILE *fp)
{
	struct type *ctype = tag__type(tag);
	struct class_member *pos;

	if (ctype->definition_emitted)
		return 0;

	/* Ok, lets look at the previous CUs: */
	if (type_emissions__find_definition(emissions, tag->tag, type__name(ctype)) != NULL) {
		ctype->definition_emitted = 1;
		return 0;
	}

	if (tag__is_typedef(tag))
		return typedef__emit_definitions(tag, cu, emissions, fp);

	/*
	 * vmlinux.h:120298:8: error: ‘irte’ defined as wrong kind of tag
	 *
	 * If we have a 'struct foo' and we then find a 'union foo', which happens
	 * twice in the Linux kernel, for instance, then we need to disambiguate by
	 * adding a suffix to the second type with the same name.
	 *
	 * That is the strategy used in:
	 *
	 *    btf dump file /sys/kernel/btf/vmlinux format c > vmlinux.h
	 */
	if (type__can_have_shadow_definition(ctype)) {
		if (type_emissions__find_shadow_definition(emissions, tag->tag, type__name(ctype))) {
			ctype->suffix_disambiguation = 1;

			char *disambiguated_name;

			if (asprintf(&disambiguated_name, "%s__%u", type__name(ctype), ctype->suffix_disambiguation) == -1) {
				fprintf(stderr, "emit: Not enough memory to allocate disambiguated type name for '%s'\n",
					type__name(ctype));
			} else {
				// Will be deleted in type__delete() on noticing ctype->suffix_disambiguation != 0
				tag__namespace(tag)->name = disambiguated_name;

				// Now look again if it was emitted in a previous CU with the disambiguated name
				if (type_emissions__find_definition(emissions, tag->tag, type__name(ctype)) != NULL) {
					ctype->definition_emitted = 1;
					return 0;
				}
			}

		}
	}

	type_emissions__add_definition(emissions, ctype);

	type__check_structs_at_unnatural_alignments(ctype, cu);

	type__for_each_member(ctype, pos)
		if (tag__emit_definitions(&pos->tag, cu, emissions, fp))
			fputc('\n', fp);

	/*
	 * Resolve template value parameter types so that e.g. a
	 * custom enum used as a non-type parameter is defined
	 * before the template specialization that uses it.
	 */
	if (emissions->conf_fprintf &&
	    emissions->conf_fprintf->emit_template_declarations) {
		if (!list_empty(&ctype->template_value_params)) {
			struct template_value_param *tvp;
			type__for_each_template_value_param(ctype, tvp)
				if (tag__emit_definitions(&tvp->tag, cu, emissions, fp))
					fputc('\n', fp);
		}
		/* Also resolve value params inside template parameter packs */
		if (ctype->template_parameter_pack) {
			struct tag *param;
			list_for_each_entry(param, &ctype->template_parameter_pack->params, node)
				if (param->tag == DW_TAG_template_value_parameter)
					if (tag__emit_definitions(param, cu, emissions, fp))
						fputc('\n', fp);
		}
	}

	/*
	 * For C++ template instantiations, emit a primary template forward
	 * declaration before the explicit specialization body that the caller
	 * will print.  For example, for "FixedArray<int, 10>" this emits:
	 *
	 *   template<typename T, int N>
	 *   struct FixedArray;
	 *
	 * Without this, "template<> struct FixedArray<int, 10> { ... };" is
	 * not valid C++ — it requires a preceding primary template declaration.
	 *
	 * Gated on emit_template_declarations (set in --compile mode for C++
	 * CUs) so that non-compile output and C output remain unchanged.
	 */
	if (emissions->conf_fprintf &&
	    emissions->conf_fprintf->emit_template_declarations &&
	    type__has_template_params(ctype))
		type__emit_template_fwd_decl(ctype, cu, fp);

	return 1;
}

void type__emit(struct tag *tag, struct cu *cu,
		const char *prefix, const char *suffix,
		struct type_emissions *emissions, FILE *fp)
{
	struct type *ctype = tag__type(tag);

	if (type__name(ctype) != NULL ||
	    suffix != NULL || prefix != NULL) {
		struct conf_fprintf conf = {
			.prefix	    = prefix,
			.suffix	    = suffix,
			.emit_stats = 1,
		};

		if (emissions && emissions->conf_fprintf)
			conf.emit_template_declarations =
				emissions->conf_fprintf->emit_template_declarations;

		/*
		 * If the primary template wasn't reconstructible,
		 * suppress the body too — "struct Foo<int, 10> { };"
		 * is ill-formed without a preceding primary.  Match
		 * the fwd-decl bail policy for consistency.
		 */
		if (conf.emit_template_declarations &&
		    type__name(ctype) != NULL &&
		    strchr(type__name(ctype), '<') &&
		    type__has_template_params(ctype) &&
		    !ctype->primary_template_emitted) {
			fprintf(fp, "/* skipped: primary template for %s not reconstructible */\n",
				type__name(ctype));
			ctype->definition_emitted = 1;
			return;
		}

		tag__fprintf(tag, cu, &conf, fp);
		fputc('\n', fp);
	}
}
