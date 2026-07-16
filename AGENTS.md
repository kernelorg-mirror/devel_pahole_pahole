# AI Coding Agent Instructions

This file contains instructions for AI coding agents (Claude, GitHub Copilot, Cursor, etc.) working on pahole.

## Commit Message Format

Follow Linux kernel commit message conventions with agent-specific trailers.

### Trailer Format

Use `Assisted-by:` trailer with the agent name and model, followed by `Signed-off-by:`:

```
Assisted-by: Claude:claude-sonnet-4-5
Signed-off-by: Arnaldo Carvalho de Melo <acme@redhat.com>
```

For other agents:
```
Assisted-by: GitHub-Copilot:gpt-4
Signed-off-by: Arnaldo Carvalho de Melo <acme@redhat.com>
```

### Important Rules

- **DO NOT** use `Co-Authored-By:` for AI agents — use `Assisted-by:` instead
- `Assisted-by:` goes first, then `Signed-off-by:` immediately after
- For human co-authors, use kernel's `Co-developed-by:` / `Signed-off-by:` pair
- The model name should reflect the actual model being used (e.g., claude-sonnet-4-5, claude-opus-4-7, gpt-4)

### Example Commit Message

```
btf_encoder: Fix memory leak in error path

When btf_encoder__new() fails to allocate the encoder structure,
it calls btf_encoder__delete() which tries to free uninitialized
pointers. Initialize all pointers to NULL before any allocation.

Before: crashes on allocation failure with double-free
After: cleanly returns NULL on allocation failure

Assisted-by: Claude:claude-sonnet-4-5
Signed-off-by: Arnaldo Carvalho de Melo <acme@redhat.com>
```

## Why This Format?

pahole follows Linux kernel development practices. The kernel uses `Assisted-by:` for
non-human contributors and `Co-developed-by:` for human co-authors. This distinction
is important for proper attribution and tooling that processes commit metadata.

## Model Names Reference

When creating commits, use the actual model name:

- Claude Sonnet 4.5: `claude-sonnet-4-5`
- Claude Sonnet 4.6: `claude-sonnet-4-6`
- Claude Opus 4.6: `claude-opus-4-6`
- Claude Opus 4.7: `claude-opus-4-7`
- Claude Haiku 4.5: `claude-haiku-4-5`
- GitHub Copilot: `gpt-4` or `gpt-3.5-turbo` (check current model)
- Cursor: (check current model)

Update this list as new models become available.
