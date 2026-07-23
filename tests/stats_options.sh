#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright © 2026 Red Hat Inc, Arnaldo Carvalho de Melo <acme@redhat.com>
#
# Test --nr_methods, --nr_definitions, --hole_size_ge, --class_name_len,
# --word_size, and --supported_btf_features options.

. "$(dirname "$0")/test_lib.sh"
outdir=$(make_tmpdir)

trap cleanup EXIT

title_log "Statistics and filtering options."

TAB=$(printf '\t')
CC=${CC:-gcc}
if ! command -v "${CC%% *}" > /dev/null 2>&1; then
	info_log "skip: $CC not available"
	test_skip
fi

src=$(make_tmpsrc)
obj=$(make_tmpobj)

cat > "$src" << 'EOF'
struct device {
	int	type;
	void	*priv;
};

int device_init(struct device *dev) { dev->type = 0; return 0; }
void device_destroy(struct device *dev) { dev->priv = (void *)0; }

struct holey {
	int	a;
	char	b;
	int	c;
	char	d;
};

struct with_ptrs {
	int	type;
	void	*ptr1;
	char	name;
	void	*ptr2;
};

struct device g1;
struct holey g2;
struct with_ptrs g3;
EOF

if ! $CC -g -c -o "$obj" "$src" 2>/dev/null; then
	error_log "FAIL: compilation failed"
	test_fail
fi

# --supported_btf_features: no input file needed
if ! output=$(pahole --supported_btf_features 2>/dev/null) || [ -z "$output" ]; then
	error_log "FAIL: --supported_btf_features failed or empty"
	test_fail
fi
info_log "--supported_btf_features: ok"

# --nr_methods: device has exactly 2 methods
output=$(pahole -m "$obj" 2>/dev/null)
if ! echo "$output" | grep -q "^device${TAB}2$"; then
	error_log "FAIL: --nr_methods expected 'device 2', got: $(echo "$output" | grep device)"
	test_fail
fi
info_log "--nr_methods: ok"

# --nr_definitions: each struct should have exactly 1 definition
output=$(pahole -T "$obj" 2>/dev/null)
if ! echo "$output" | grep -q "^device${TAB}1$"; then
	error_log "FAIL: --nr_definitions expected 'device 1', got: $(echo "$output" | grep device)"
	test_fail
fi
if ! echo "$output" | grep -q "^holey${TAB}1$"; then
	error_log "FAIL: --nr_definitions expected 'holey 1', got: $(echo "$output" | grep holey)"
	test_fail
fi
info_log "--nr_definitions: ok"

# --hole_size_ge: holey has a 3-byte hole
output=$(pahole -z 3 "$obj" 2>/dev/null)
if ! echo "$output" | grep -q "holey"; then
	error_log "FAIL: --hole_size_ge 3 did not list holey"
	test_fail
fi
info_log "--hole_size_ge: ok"

# --class_name_len: device=6 chars, holey=5 chars
output=$(pahole -N "$obj" 2>/dev/null)
if ! echo "$output" | grep -q "^device${TAB}6$"; then
	error_log "FAIL: --class_name_len expected 'device 6', got: $(echo "$output" | grep device)"
	test_fail
fi
if ! echo "$output" | grep -q "^holey${TAB}5$"; then
	error_log "FAIL: --class_name_len expected 'holey 5', got: $(echo "$output" | grep holey)"
	test_fail
fi
info_log "--class_name_len: ok"

# --word_size: force 8-byte and 4-byte pointer sizes and compare
output=$(pahole --sizes -w 8 -C with_ptrs "$obj" 2>/dev/null)
size_64=$(echo "$output" | awk '{print $2}')
output=$(pahole --sizes -w 4 -C with_ptrs "$obj" 2>/dev/null)
size_32=$(echo "$output" | awk '{print $2}')
if [ "$size_64" != "32" ]; then
	error_log "FAIL: --sizes --word_size=8 with_ptrs expected 32, got: $size_64"
	test_fail
fi
if [ "$size_32" != "16" ]; then
	error_log "FAIL: --sizes --word_size=4 with_ptrs expected 16, got: $size_32"
	test_fail
fi
info_log "--word_size: ok"

test_pass
