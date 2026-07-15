# Test Dependencies and Self-Sufficiency

The pahole test suite is designed to be portable across distributions and
environments. Tests automatically handle missing dependencies in two ways:

## 1. Skip gracefully when tools/files are unavailable

Tests that require specific system resources (vmlinux, bpftool, etc.) check
for availability and skip with an informative message rather than fail.

## 2. Build dependencies from source on-demand

For tools where source is readily available, tests automatically fetch and
build what they need rather than assuming distro packages provide it.

### perf with debug info

Tests that need perf with DWARF debug info use `get_perf_with_debug()` from
test_lib.sh. This function:

1. Checks if system perf has debug info (via `file` command)
2. If not, downloads perf tarball (~3MB) and builds with DEBUG=1
3. Caches the build in `/tmp/pahole-test-perf-cache` for reuse across tests
4. Returns the path to a usable perf binary

Uses kernel.org's perf-specific tarballs (see HOWTO.build.perf) rather than
cloning the full kernel tree for efficiency.

This ensures tests work on:
- Fedora/RHEL with debuginfo packages via debuginfod
- Debian/Ubuntu with -dbgsym packages
- Alpine/musl systems with no debug packages
- Any distro by building from source as fallback

Tests use software events (task-clock) instead of hardware performance
counters for container compatibility (containers typically lack access to
hardware PMU).

**Container restrictions**: Some containers block the perf_event_open syscall
entirely via seccomp or missing capabilities (CAP_PERFMON, CAP_SYS_ADMIN).
Tests detect this ("Operation not permitted") and skip gracefully rather
than fail. To enable in such containers, run with --privileged, add
SYS_ADMIN capability, or adjust seccomp policy.

Set `PERF_CACHE_DIR` to override the cache location.

## Adding new dependencies

When adding tests that need external tools:

1. Check if available (command -v, file existence)
2. If missing and source is accessible, build it (like get_perf_with_debug)
3. If missing and cannot build, skip with clear reason
4. Never fail tests due to missing optional dependencies
5. Document the dependency in this file

## Environment variables

- `VMLINUX`: Path to vmlinux file for tests requiring it (default: auto-detect via pahole)
- `PERF_CACHE_DIR`: Override perf build cache location (default: /tmp/pahole-test-perf-cache)
- `CC`: Override C compiler (default: gcc)
- `CLANG`: Override clang compiler (default: clang)
- `BTF_FUNCTIONS_QUICK`: Use smaller test set for btf_functions.sh in CI

## Command line options

The `tests` runner accepts the following options:

```bash
tests --vmlinux /path/to/vmlinux    # Specify vmlinux file for tests
tests --help                         # Show usage information
```

Equivalently, use the VMLINUX environment variable:

```bash
VMLINUX=/boot/vmlinux-6.11.0 tests
```
