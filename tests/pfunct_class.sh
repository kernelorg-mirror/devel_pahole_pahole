#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Test pfunct --class and --expand_types options.
#
# Covers cu_class_iterator() (19 lines) and
# function__emit_type_definitions() (36 lines) in pfunct.c,
# both at 0% coverage.
#
# pfunct --class=name lists functions that have a parameter of the
# given struct/class type.  cu_class_iterator walks each CU's
# functions and checks parameter types against the target.
#
# pfunct --expand_types emits type definitions alongside function
# prototypes, exercising function__emit_type_definitions().

. "$(dirname "$0")/test_lib.sh"

outdir=$(make_tmpdir)
trap cleanup EXIT

title_log "pfunct --class and --expand_types."

CC=${CC:-gcc}
if ! command -v "${CC%% *}" > /dev/null 2>&1; then
	info_log "skip: $CC not available"
	test_skip
fi

if ! command -v pfunct > /dev/null 2>&1; then
	info_log "skip: pfunct not available"
	test_skip
fi

cat > "$outdir/pfunct_class_test.c" <<'EOF'
struct device {
	int id;
	char name[32];
};

struct config {
	int version;
	int flags;
};

int device_init(struct device *dev, int id) {
	dev->id = id;
	return 0;
}

int device_reset(struct device *dev) {
	dev->id = 0;
	return 0;
}

int config_load(struct config *cfg) {
	cfg->version = 1;
	return 0;
}

/* Takes both types */
int device_configure(struct device *dev, struct config *cfg) {
	dev->id = cfg->version;
	return 0;
}

/* Takes neither */
int get_version(void) {
	return 42;
}
EOF

if ! $CC -g -c -o "$outdir/pfunct_class_test.o" "$outdir/pfunct_class_test.c" 2>"$outdir/cc.log"; then
	info_log "compilation failed:"
	info_log "$(cat "$outdir/cc.log")"
	test_fail
fi

obj="$outdir/pfunct_class_test.o"

# --class=device should list functions with struct device parameter
output=$(pfunct --class=device "$obj" 2>/dev/null)

if [ -z "$output" ]; then
	error_log "FAIL: pfunct --class=device produced no output"
	test_fail
fi

# Should include device_init, device_reset, device_configure
if ! echo "$output" | grep -q "device_init"; then
	error_log "FAIL: --class=device missing device_init"
	test_fail
fi

if ! echo "$output" | grep -q "device_reset"; then
	error_log "FAIL: --class=device missing device_reset"
	test_fail
fi

if ! echo "$output" | grep -q "device_configure"; then
	error_log "FAIL: --class=device missing device_configure"
	test_fail
fi

# Should NOT include config_load or get_version
if echo "$output" | grep -q "config_load"; then
	error_log "FAIL: --class=device incorrectly includes config_load"
	test_fail
fi

if echo "$output" | grep -q "get_version"; then
	error_log "FAIL: --class=device incorrectly includes get_version"
	test_fail
fi

info_log "   pfunct --class=device: ok"

# --class=config should list config_load and device_configure only
output=$(pfunct --class=config "$obj" 2>/dev/null)

if [ -z "$output" ]; then
	error_log "FAIL: pfunct --class=config produced no output"
	test_fail
fi

if ! echo "$output" | grep -q "config_load"; then
	error_log "FAIL: --class=config missing config_load"
	test_fail
fi

if ! echo "$output" | grep -q "device_configure"; then
	error_log "FAIL: --class=config missing device_configure"
	test_fail
fi

info_log "   pfunct --class=config: ok"

# --class with a non-existent struct should produce no output
output=$(pfunct --class=nonexistent "$obj" 2>/dev/null)
rc=$?

if [ $rc -gt 128 ]; then
	error_log "FAIL: pfunct --class=nonexistent crashed (signal)"
	test_fail
fi

if [ -n "$output" ]; then
	error_log "FAIL: --class=nonexistent should produce no output"
	test_fail
fi

info_log "   pfunct --class=nonexistent: ok (empty)"

# --expand_types (-b) emits type definitions alongside function
# prototypes.  Currently only works without --class (combining
# them silently ignores --expand_types — see TODO #34).
output=$(pfunct --expand_types "$obj" 2>/dev/null)

if [ -z "$output" ]; then
	error_log "FAIL: pfunct --expand_types produced no output"
	test_fail
fi

if ! echo "$output" | grep -q "struct device"; then
	error_log "FAIL: --expand_types missing struct device definition"
	test_fail
fi

if ! echo "$output" | grep -q "struct config"; then
	error_log "FAIL: --expand_types missing struct config definition"
	test_fail
fi

if ! echo "$output" | grep -q "device_init"; then
	error_log "FAIL: --expand_types missing device_init prototype"
	test_fail
fi

info_log "   pfunct --expand_types: ok"

test_pass
