---
name: terminal-agent-tools
description: "Trigger: terminal tools, terminal workflow, repo inspection, tool selection, bounded reads, safe edits, repomix, context packaging, verification. Load the repository terminal-tools guideline first; use this skill as fallback when no guideline exists."
license: Apache-2.0
compatibility: opencode
metadata:
  author: dyool
  version: "1.2"
  project: agnostic
  role: terminal-agent-workflow
---

# Terminal Agent Tools

## Activation Contract

Use this skill when an agent must inspect, modify, review, package, or verify a repository through terminal tools.

Typical triggers:

- terminal workflow
- repo inspection
- tool selection
- bounded file reads
- safe edits
- focused verification
- Repomix / AI context packaging
- `fd`, `rg`, `ast-grep`, `bat`, `jq`, `yq`, `sd`, `delta`, `just`, `gh`, `tokei`, `scc`, `eza`, `dust`, `shellcheck`, `typos`, `hyperfine`

This skill governs **how** to use terminal tools efficiently and safely. It does not decide domain ownership, architecture policy, testing policy, security policy, or business-specific evidence requirements.

Repository-local instructions always win.

---

## Required Guideline Lookup

Before terminal-driven work, read the repository terminal-tools guideline if present.

Look for these files, in order:

```text
docs/guidelines/terminal-tools.guideline.md
docs/ai-guidelines/terminal-tools.guideline.md
docs/guidelines/terminal-tools.md
AGENTS.md
CLAUDE.md
CODEX.md
.opencode/AGENTS.md
```

If a terminal-tools guideline exists, follow it.

If no guideline exists, use the fallback rules in this skill.

Do not copy guideline contents into task reports. Reference the file path used.

---

## Fallback Core Rule

Map cheaply, search narrowly, read only what is needed, edit minimally, verify with focused evidence, and summarize with paths and commands.

Do not begin by opening broad files or packaging the whole repository.

---

## Fallback Operating Sequence

Use this sequence unless the task already names exact files:

```text
repo state
  -> stack and boundary detection
  -> targeted file/text search
  -> semantic search when syntax matters
  -> bounded reading
  -> minimal edit
  -> focused verification
  -> optional context package
  -> evidence summary
```

---

## Fallback Hard Rules

- Check repository state before edits.
- Search before broad file reads.
- Read bounded snippets unless the whole file is the artifact under review.
- Inspect package/task definitions before running project scripts.
- Never run dependency installs casually.
- Never run remote scripts casually.
- Never run unknown project scripts without inspection.
- Never use `npx`, `pnpm dlx`, `bunx`, `curl | sh`, `irm | iex`, or equivalent remote execution as default behavior.
- Do not automatically install missing tools.
- Do not package dependency folders, VCS internals, build outputs, generated artifacts, lockfiles, binaries, or large snapshots by default.
- Preserve existing repository conventions unless the task explicitly requires changing them.
- Use the smallest command that can answer the question.

Default excluded paths/files:

```text
node_modules/**
.git/**
dist/**
build/**
coverage/**
.next/**
.nuxt/**
.svelte-kit/**
bin/**
obj/**
target/**
.artifacts/**
.vs/**
.idea/**
*.lock
package-lock.json
pnpm-lock.yaml
yarn.lock
Cargo.lock
go.sum
poetry.lock
uv.lock
*.min.js
*.map
generated clients
large snapshots
binary files
```

Lockfiles are in scope only for dependency, reproducibility, merge, supply-chain, or package-integrity work.

---

## Fallback Tool Selection

| Situation | Default action |
| --- | --- |
| Understand repo state | `git status --short`, branch info, shallow discovery |
| Locate files | `fd` |
| Locate symbols/text/routes/config/errors | `rg` |
| Match code structure | `ast-grep` / `sg` |
| Inspect JSON | `jq` |
| Inspect YAML/TOML/XML-ish config | `yq` |
| Read source safely | `bat --line-range` or harness read |
| Review diff scope | `git diff --stat` before full diffs |
| Review readable diff | `git diff -- path | delta` |
| Mechanical literal replacement | `sd` after confirming matches with `rg` |
| Repo size/language map | `tokei` / `scc` |
| Large/noisy directory detection | `dust -d 2` |
| Task runner discovery | inspect scripts, `just --list`, or equivalent |
| GitHub PR/issue/CI context | `gh`, only when remote context is relevant |
| Shell validation | `shellcheck` before execution |
| Typo scan | `typos` |
| Performance comparison | `hyperfine` only after correctness |
| AI handoff context | Repomix only after scoped discovery |
| Verification | narrowest repo-approved check |

---

## Fallback Command Patterns

Repo identity:

```bash
git status --short
git branch --show-current
fd -d 2 -t f 'package\.json|pnpm-workspace\.yaml|vite\.config\..*|tsconfig\.json|.*\.slnx?|.*\.csproj|pyproject\.toml|go\.mod|Cargo\.toml|docker-compose\.ya?ml|Dockerfile|justfile|Makefile|README\.md'
```

Targeted search:

```bash
rg 'SearchTerm' -n -C 3 src tests docs
fd Handler src tests
ast-grep -p 'console.log($A)' -l ts
```

Bounded reading:

```bash
bat --line-range 1:160 path/to/file
rg 'SearchTerm' path/to/file -n -C 5
```

Script inspection before execution:

```bash
jq '.scripts' package.json
bat --line-range 1:200 path/to/script.sh
shellcheck path/to/script.sh
just --list
```

Diff review:

```bash
git diff --stat
git diff -- path/to/file
git diff -- path/to/file | delta
```

Repomix, only after scoped discovery:

```bash
pnpm exec repomix --include "src/**/*,tests/**/*" --include-diffs -o .ai/repomix-diff.xml
rg -l 'SearchTerm' src tests | pnpm exec repomix --stdin -o .ai/repomix-selected.xml
```

Before sharing generated packages:

```bash
rg -i 'password|secret|token|apikey|api_key|private key|connectionstring|connection string' .ai/
rg 'node_modules|dist/|build/|coverage|\.env|bin/|obj/' .ai/
```

---

## Interactive Tools Policy

Avoid interactive tools in autonomous agent runs unless explicitly requested or the session is truly interactive.

Human-first tools:

- `fzf`
- `lazygit`
- `neovim`
- `less`
- `starship`

Prefer non-interactive equivalents for agent work.

---

## Output Contract

A terminal-agent report must include:

- guideline file used, or state that fallback rules were used
- commands used
- files inspected
- files changed, if any
- verification result or blocker
- risks and unresolved assumptions
- recommended next action

Keep reports compact and evidence-bearing. Prefer paths, symbols, commands, line ranges, test names, error excerpts, and blockers over broad prose.
