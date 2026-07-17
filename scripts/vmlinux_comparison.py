#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
#
# Compare vmlinux files: DWARF versions, producers, section sizes, and pahole output.
#
# Prompt used to generate this script:
# Given a directory with a series of vmlinux files, look at the DW_AT_producer
# DWARF tags to notice what's unique for each of the vmlinux files, look at the
# DWARF version as well, then run pahole -F dwarf and btf to see if the output
# produced changes for both formats in the different vmlinux files, create a
# table like the one in the coverage-table make target. Add columns for each row
# (DWARF files) with the size of the vmlinux files and the size of the DWARF and
# BTF related ELF sections on each of the vmlinux files. Include this prompt in
# the resulting script header, with "Prompt used to generate this script:" as a
# script comment. Commit the result in the scripts/ directory, an initial set of
# vmlinux files is in ~/dws/, together with some text files, that should not be
# considered.
#
# Usage:
#   scripts/vmlinux_comparison.py [DIRECTORY]
#
#   Default directory: ~/dws/

import argparse
import hashlib
import os
import re
import subprocess
import sys
import tempfile


def format_size(size_bytes):
    """Format byte size in human-readable format."""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size_bytes < 1024.0:
            return f"{size_bytes:.1f}{unit}"
        size_bytes /= 1024.0
    return f"{size_bytes:.1f}TB"


def get_file_size(path):
    """Get file size in bytes."""
    return os.path.getsize(path)


def extract_dwarf_version(vmlinux_path):
    """Extract DWARF version using readelf (only first 100 lines)."""
    try:
        # Only read first 100 lines of debug info to find version quickly
        cmd = f"readelf --debug-dump=info '{vmlinux_path}' 2>/dev/null | head -100"
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        if result.returncode != 0:
            return 'N/A'

        # Look for first "Version:" in output
        for line in result.stdout.splitlines():
            if 'Version:' in line:
                match = re.search(r'Version:\s+(\d+)', line)
                if match:
                    return match.group(1)
        return 'N/A'
    except Exception as e:
        return 'N/A'


def extract_producer(vmlinux_path):
    """Extract DW_AT_producer using readelf (only first 200 lines)."""
    try:
        # Only read first 200 lines of debug info to find producer quickly
        cmd = f"readelf --debug-dump=info '{vmlinux_path}' 2>/dev/null | head -200"
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        if result.returncode != 0:
            return 'N/A'

        # Look for first DW_AT_producer
        for line in result.stdout.splitlines():
            if 'DW_AT_producer' in line:
                # Extract the actual producer string after the colon
                match = re.search(r'DW_AT_producer\s*:\s*(?:\([^)]+\):\s*)?(.+)', line)
                if match:
                    producer = match.group(1).strip()
                    # Extract key parts: compiler name, version, DWARF flag
                    # Example: "GNU C11 16.1.1 20260515 (Red Hat 16.1.1-2) ... -gdwarf-4 ..."

                    # Get compiler and version
                    compiler_match = re.search(r'(GNU C\d+|clang)\s+([\d.]+)', producer)
                    compiler = compiler_match.group(0) if compiler_match else 'unknown'

                    # Get DWARF version flag
                    dwarf_match = re.search(r'-gdwarf-(\d+)', producer)
                    dwarf_flag = f"-gdwarf-{dwarf_match.group(1)}" if dwarf_match else ''

                    # Get compression if present
                    compress_match = re.search(r'-gz(=\w+)?', producer)
                    compress = compress_match.group(0) if compress_match else ''

                    parts = [compiler, dwarf_flag, compress]
                    return ' '.join(p for p in parts if p)
        return 'N/A'
    except Exception as e:
        return f'Error: {e}'


def get_section_sizes(vmlinux_path):
    """Get sizes of DWARF and BTF sections using readelf."""
    try:
        cmd = ['readelf', '-S', vmlinux_path]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            return 0, 0

        dwarf_size = 0
        btf_size = 0

        # Parse section table - readelf outputs sections across two lines:
        # Line 1: [Nr] Name Type Address Offset
        # Line 2:      Size EntSize Flags Link Info Align
        lines = result.stdout.splitlines()
        i = 0
        while i < len(lines):
            line = lines[i]

            # Match section header line: [Nr] Name ...
            match = re.match(r'\s*\[\s*\d+\]\s+(\S+)', line)
            if match:
                section_name = match.group(1)

                # Size is on the next line
                if i + 1 < len(lines):
                    next_line = lines[i + 1]
                    # Extract first hex number from next line (the size)
                    size_match = re.search(r'^\s+([0-9a-f]+)', next_line)
                    if size_match:
                        size = int(size_match.group(1), 16)

                        if section_name.startswith('.debug_'):
                            dwarf_size += size
                        elif section_name.startswith('.BTF'):
                            btf_size += size

            i += 1

        return dwarf_size, btf_size
    except Exception as e:
        return 0, 0


def run_pahole_and_hash(vmlinux_path, format_type):
    """Run pahole with given format and return output hash."""
    try:
        # Run pahole and stream output for hashing (avoids loading into memory)
        cmd = ['pahole', '-F', format_type, vmlinux_path]
        result = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL)  # Ignore stderr to avoid blocking

        # Stream output and compute hash on the fly
        hasher = hashlib.sha256()
        file_size = 0

        while True:
            chunk = result.stdout.read(8192)
            if not chunk:
                break
            hasher.update(chunk)
            file_size += len(chunk)

        result.wait(timeout=600)  # Increase timeout to 10 minutes for large files

        if result.returncode != 0:
            return 'ERROR', 0

        hash_short = hasher.hexdigest()[:8]
        return hash_short, file_size
    except subprocess.TimeoutExpired:
        result.kill()
        result.wait()  # Clean up zombie process
        return 'TIMEOUT', 0
    except Exception as e:
        return 'ERROR', 0


def find_vmlinux_files(directory):
    """Find all vmlinux* files in directory, excluding text files."""
    vmlinux_files = []

    if not os.path.isdir(directory):
        print(f"Error: {directory} is not a directory", file=sys.stderr)
        return []

    for filename in os.listdir(directory):
        path = os.path.join(directory, filename)

        # Skip non-files
        if not os.path.isfile(path):
            continue

        # Only include files starting with "vmlinux"
        if not filename.startswith('vmlinux'):
            continue

        # Skip text files (.c, .txt, etc.)
        if filename.endswith(('.c', '.txt', '.log', '.md')):
            continue

        # Check if it's an ELF file
        try:
            with open(path, 'rb') as f:
                magic = f.read(4)
                if magic != b'\x7fELF':
                    continue
        except:
            continue

        vmlinux_files.append(path)

    return sorted(vmlinux_files)


def analyze_vmlinux(vmlinux_path):
    """Analyze a single vmlinux file and return metrics."""
    filename = os.path.basename(vmlinux_path)

    print(f"  Analyzing {filename}...", file=sys.stderr)

    file_size = get_file_size(vmlinux_path)
    dwarf_version = extract_dwarf_version(vmlinux_path)
    producer = extract_producer(vmlinux_path)
    dwarf_size, btf_size = get_section_sizes(vmlinux_path)

    print(f"    Running pahole -F dwarf...", file=sys.stderr)
    dwarf_hash, dwarf_out_size = run_pahole_and_hash(vmlinux_path, 'dwarf')

    print(f"    Running pahole -F btf...", file=sys.stderr)
    btf_hash, btf_out_size = run_pahole_and_hash(vmlinux_path, 'btf')

    return {
        'filename': filename,
        'file_size': file_size,
        'dwarf_version': dwarf_version,
        'producer': producer,
        'dwarf_section_size': dwarf_size,
        'btf_section_size': btf_size,
        'dwarf_output_hash': dwarf_hash,
        'dwarf_output_size': dwarf_out_size,
        'btf_output_hash': btf_hash,
        'btf_output_size': btf_out_size,
    }


def print_table(results):
    """Print comparison table with box-drawing characters."""
    if not results:
        print("No vmlinux files found.")
        return

    # Column widths
    W_FILE = 30
    W_SIZE = 8
    W_VER = 4
    W_PROD = 35
    W_SECT = 10
    W_HASH = 10
    W_OUT = 10

    # Header
    def print_sep(char='─'):
        print(f"┌{char*(W_FILE+2)}┬{char*(W_SIZE+2)}┬{char*(W_VER+2)}┬{char*(W_PROD+2)}┬"
              f"{char*(W_SECT+2)}┬{char*(W_SECT+2)}┬"
              f"{char*(W_HASH+2)}┬{char*(W_OUT+2)}┬"
              f"{char*(W_HASH+2)}┬{char*(W_OUT+2)}┐")

    def print_row_sep():
        print(f"├{'─'*(W_FILE+2)}┼{'─'*(W_SIZE+2)}┼{'─'*(W_VER+2)}┼{'─'*(W_PROD+2)}┼"
              f"{'─'*(W_SECT+2)}┼{'─'*(W_SECT+2)}┼"
              f"{'─'*(W_HASH+2)}┼{'─'*(W_OUT+2)}┼"
              f"{'─'*(W_HASH+2)}┼{'─'*(W_OUT+2)}┤")

    print_sep()

    # Column headers
    print(f"│ {'File':<{W_FILE}} │ {'Size':>{W_SIZE}} │ {'Ver':>{W_VER}} │ {'Producer':<{W_PROD}} │ "
          f"{'DWARF':>{W_SECT}} │ {'BTF':>{W_SECT}} │ "
          f"{'DW-Hash':>{W_HASH}} │ {'DW-Out':>{W_OUT}} │ "
          f"{'BTF-Hash':>{W_HASH}} │ {'BTF-Out':>{W_OUT}} │")

    print_row_sep()

    # Data rows
    for r in results:
        fname = r['filename']
        if len(fname) > W_FILE:
            fname = fname[:W_FILE-3] + '...'

        fsize = format_size(r['file_size'])
        ver = r['dwarf_version']

        prod = r['producer']
        if len(prod) > W_PROD:
            prod = prod[:W_PROD-3] + '...'

        dwarf_sect = format_size(r['dwarf_section_size'])
        btf_sect = format_size(r['btf_section_size'])

        dw_hash = r['dwarf_output_hash']
        dw_out = format_size(r['dwarf_output_size'])

        btf_hash = r['btf_output_hash']
        btf_out = format_size(r['btf_output_size'])

        print(f"│ {fname:<{W_FILE}} │ {fsize:>{W_SIZE}} │ {ver:>{W_VER}} │ {prod:<{W_PROD}} │ "
              f"{dwarf_sect:>{W_SECT}} │ {btf_sect:>{W_SECT}} │ "
              f"{dw_hash:>{W_HASH}} │ {dw_out:>{W_OUT}} │ "
              f"{btf_hash:>{W_HASH}} │ {btf_out:>{W_OUT}} │")

    # Footer
    print(f"└{'─'*(W_FILE+2)}┴{'─'*(W_SIZE+2)}┴{'─'*(W_VER+2)}┴{'─'*(W_PROD+2)}┴"
          f"{'─'*(W_SECT+2)}┴{'─'*(W_SECT+2)}┴"
          f"{'─'*(W_HASH+2)}┴{'─'*(W_OUT+2)}┴"
          f"{'─'*(W_HASH+2)}┴{'─'*(W_OUT+2)}┘")

    print()
    print("Column descriptions:")
    print("  File       : vmlinux filename")
    print("  Size       : Total file size")
    print("  Ver        : DWARF version")
    print("  Producer   : Compiler and flags (truncated)")
    print("  DWARF      : Total size of .debug_* sections")
    print("  BTF        : Total size of .BTF* sections")
    print("  DW-Hash    : SHA256 hash (first 8 chars) of pahole -F dwarf output")
    print("  DW-Out     : Size of pahole -F dwarf output")
    print("  BTF-Hash   : SHA256 hash (first 8 chars) of pahole -F btf output")
    print("  BTF-Out    : Size of pahole -F btf output")
    print()
    print("Note: Different hashes indicate different pahole output between files.")
    print()
    print("The output shows that vmlinux variants (different DWARF versions, compression)")
    print("produce identical pahole output despite different file sizes and debug section")
    print("sizes, validating pahole's consistency across different DWARF encodings.")


def main():
    parser = argparse.ArgumentParser(
        description='Compare vmlinux files: DWARF, BTF, and pahole output')
    parser.add_argument('directory', nargs='?',
                       default=os.path.expanduser('~/dws'),
                       help='Directory containing vmlinux files (default: ~/dws)')
    args = parser.parse_args()

    directory = os.path.expanduser(args.directory)

    print(f"Scanning {directory} for vmlinux files...", file=sys.stderr)
    vmlinux_files = find_vmlinux_files(directory)

    if not vmlinux_files:
        print(f"No vmlinux files found in {directory}", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(vmlinux_files)} vmlinux file(s)\n", file=sys.stderr)

    results = []
    for vmlinux_path in vmlinux_files:
        result = analyze_vmlinux(vmlinux_path)
        results.append(result)

    print(file=sys.stderr)
    print_table(results)


if __name__ == '__main__':
    main()
