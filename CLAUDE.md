# Claude Code Instructions for pahole

This file is automatically loaded at the start of each Claude Code session.

## Required Reading

Always read these files at session start:

- **AGENTS.md**: AI assistant commit message format, testing requirements, and patch amendment workflow
- **CONTRIBUTING**: Contribution guidelines and development process (if exists)

## Project Context

pahole is a DWARF/BTF analysis tool from the dwarves package. It follows Linux kernel development practices including commit message format, patch-based workflow, and coding style.

## Session Startup

At the start of each session:
1. Read AGENTS.md for commit format and workflow rules
2. Check current branch and recent commits with `git log --oneline -20`
3. If working on a patch series, understand the series structure before making changes

## Key Principles

- **Amend changes to existing patches**: When modifying code, find and amend the relevant patch in the series (see AGENTS.md for process)
- **Test before committing**: Run `tests/tests` with appropriate PATH setup
- **Follow commit message format**: Use kernel-style messages with before/after numbers and `Assisted-by:` trailer
- **One concept per patch**: Don't mix mechanical changes with logic changes

See AGENTS.md for detailed requirements.
