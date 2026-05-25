# Terminal Agent Tools Guideline

## Purpose
Define how agents use terminal tools to inspect, modify, package, and verify the repository without wasting context, hiding risk, or bypassing repo safety rules.

Core rule: map cheaply, search narrowly, read only what is needed, edit minimally, verify with focused evidence.

This guideline does not replace:
- `AGENTS.md` global role routing and .NET/NuGet safety
- role skills under `.opencode/skills/**`

---

## Tool availability check

Before relying on optional tools, diagnose what is actually installed. Do not install missing tools automatically.

PowerShell:

```powershell
$tools = @(
  "rg","fd","ast-grep","sg","jq","yq","bat","delta",
  "tokei","scc","hyperfine","sd","shellcheck",
  "just","eza","dust","repomix"
)

foreach ($tool in $tools) {
  Get-Command $tool -ErrorAction SilentlyContinue | Select-Object Name, Source
}
```

Bash:

```bash
for tool in rg fd ast-grep sg jq yq bat delta tokei scc hyperfine sd shellcheck just eza dust repomix; do
  command -v "$tool" >/dev/null 2>&1 && echo "ok: $tool" || echo "missing: $tool"
done
```

If a tool is missing, use a fallback path instead of installing it automatically.

---

## Operating sequence
Use this order unless the task is already scoped to exact files:

```text
repo state
  -> stack and boundary detection
  -> targeted text/file search
  -> semantic search when syntax matters
  -> bounded reading
  -> minimal edit
  -> focused verification
  -> optional context package
  -> evidence summary
```

Rationale: run structural search (`ast-grep`) before reading files when a syntax pattern can narrow candidates. This reduces what must be read and avoids opening large files speculatively.

Do not begin by opening broad files or packaging the whole repository.

---

## Repository state and boundaries
Start with a bounded identity pass:

```bash
git status --short
git branch --show-current
fd -d 2 -t f 'package\.json|pnpm-workspace\.yaml|.*\.slnx?|.*\.csproj|pyproject\.toml|go\.mod|Cargo\.toml|docker-compose\.ya?ml|Dockerfile|justfile|Makefile|README\.md'
```

`fd` patterns are regex, not glob. Escape literal dots and use `.*` for wildcard prefixes. Pass `--glob` only when the pattern intentionally uses glob syntax.

Use size/tree tools only when they reduce later reads:

```bash
tokei .
scc .
eza --tree --level=2 --git-ignore
dust -d 2
```

Summarize the result. Do not paste long command output.

---

## Search before reading
Prefer cheap search and candidate discovery:

```bash
rg "SearchTerm" -n -C 3 src tests docs
fd Handler src tests
```

Use structural search when syntax matters or regex would be fragile:

```bash
sg -p 'public async Task<$T> $M($P) { $$$BODY }' -l csharp
sg -p 'console.log($A)' -l ts
```

Use single quotes to prevent `$` from being interpreted as shell variable expansion. Prefer `ast-grep` in narrative documentation for Linux portability; `sg` is an alias available on Windows via Scoop and is equivalent.

When using Pi tools, prefer `ast_grep_search` for semantic code patterns and `lsp_navigation` / `lsp_diagnostics` for IDE-grade symbol and diagnostic checks.

### Tool selection matrix

Use the cheapest tool that answers the question.

| Need | First tool | Escalate to | Avoid |
|---|---|---|---|
| Find files by name/type | `fd` | `eza --tree --level=2` | full tree dumps |
| Find text, symbols, routes, config keys | `rg` | `bat --line-range` | reading full files |
| Find code shape, API misuse, refactor pattern | `ast-grep` | custom AST rule | regex-only refactors |
| Inspect JSON | `jq` | targeted file read | full JSON dumps |
| Inspect YAML/TOML/XML-ish configs | `yq` | targeted file read | regex YAML edits |
| Inspect diff scope | `git diff --stat` | `git diff \| delta` | full diff first |
| Detect repo size/noise | `tokei` / `scc` | `dust -d 2` | packaging repo prematurely |
| Edit repeated literal safely | `sd` after `rg` | manual edit | broad semantic regex |
| Validate shell scripts | `shellcheck` | inspect script manually | executing unknown scripts |
| Run repo tasks | `just --list` | inspect recipe, then run target | blind `just check` |
| Benchmark alternatives | `hyperfine` | profiler/tool-specific benchmark | premature benchmarking |
| Package context for another agent | `repomix` | compressed/diff pack | whole-repo dump |

### Command portability

- Prefer `ast-grep` over `sg` in documentation. `sg` may conflict with `setgroups` on Linux; both names refer to the same tool.
- Use single quotes around `ast-grep`/`sg` patterns that contain `$` to prevent shell expansion.
- Treat `fd` patterns as regex unless `--glob` is explicitly passed.
- Use PowerShell examples only when the repo policy targets Windows; otherwise prefer shell-neutral commands.
- If a command depends on a tool that may be absent, check availability first and use a fallback.

---

## Bounded reading
Read whole files only when they are short or the file itself is the artifact under review.

Preferred terminal forms:

```bash
bat --line-range 1:160 path/to/file
rg "SearchTerm" path/to/file -n -C 5
```

Preferred Pi harness forms:
- `read` for targeted file reads
- `lsp_navigation` for definitions, references, hovers, document symbols, and diagnostics
- `bash` for discovery/search commands

Never read or package these by default:

```text
node_modules/**
.git/**
dist/**
build/**
coverage/**
bin/**
obj/**
.artifacts/**
.vs/**
.pi-lens/**
*.lock
package-lock.json
pnpm-lock.yaml
yarn.lock
skills-lock.json
packages.lock.json
*.min.js
*.map
generated clients
large snapshots
binary files
```

Lockfiles are in scope only for dependency, reproducibility, merge, or package-integrity work.

### Interactive tools policy

Agents must avoid interactive tools in autonomous runs. These tools expect a TTY, user input, or visual selection and will hang or error in non-interactive sessions:

- `fzf` → use non-interactive filters, `rg`, or `fd` instead
- `lazygit` → use `git status`, `git diff`, `git log` instead
- `nvim` / `vim` / `nano` → use `bat --line-range` or targeted `read` instead
- `less` → use direct command output or `bat` instead
- shell prompts, starship, or other interactive prompt frameworks → disable in agent sessions

If an interactive tool is the only way to complete a task, report the limitation and request guidance instead of launching the tool.

---

## Safe command policy
Do not run dependency or remote-execution commands casually:

```text
npm install
pnpm install
pnpm update
npm audit fix --force
npx
pnpm dlx
curl | sh
irm | iex
remote bootstrap scripts
unknown project scripts
```

Before running package scripts, inspect them:

```bash
jq ".scripts" package.json
```

Before running shell scripts, inspect them:

```bash
bat --line-range 1:200 path/to/script.sh
shellcheck path/to/script.sh
```

Before running task runners (just, make) or npm scripts, inspect their definitions first.

For all `dotnet` commands, follow the repo-local environment and `--no-restore` / `--no-build` rules in `AGENTS.md`. This guideline never relaxes those rules.

Do not fetch remote repository context (GitHub issues, PRs, CI runs) by default. uses Azure DevOps; avoid `gh` and similar GitHub-only tools unless the task explicitly involves a GitHub-hosted dependency or upstream.

---

## Edits and diffs
Before editing, identify the smallest file set.

Use:
- `edit` for precise Pi file changes
- `write` only for new files or deliberate full rewrites
- `sd` only for mechanical replacements after searching all affected occurrences
- `jq` / `yq` for JSON/YAML inspection and validation

Review change scope before details. Prefer `delta` as the diff pager when readability matters:

```bash
git diff --stat
git diff -- path/to/file
git diff -- path/to/file | delta
```

Do not use broad regex edits for semantic code changes.

---

## Verification
Run the narrowest meaningful verification first. Use `test-impact-map.json` and the test policy in `AGENTS.md` for the current proyect test selection.

Common focused checks:

```bash
# .NET: only with AGENTS.md repo-local env vars set
dotnet build --no-restore -v q --nologo
dotnet test <project> --no-build --nologo --tl:off -v q --logger "console;verbosity=quiet"

# JS/TS, after inspecting scripts
pnpm lint
pnpm test
pnpm build

# Shell scripts: static analysis before execution
shellcheck scripts/*.sh

# Task runner: discover safe commands when a justfile exists
just --list
just check

# Performance comparison: only after correctness is confirmed
hyperfine "command A" "command B"
```

If verification cannot run, report the blocker and the next smallest safe command.

---

## AI context packaging
Use Repomix only after discovery has identified a small relevant scope.

Use it for:
- focused handoff packages
- architecture snapshots over selected paths
- diff-aware review packs
- token budgeting before sending context to another model

Do not use it for first-pass exploration or whole-repo dumps.

Policy:
- do not install Repomix automatically
- prefer project-local `pnpm exec repomix` when installed
- avoid `npx` / `pnpm dlx` as an agent default
- write outputs under `.ai/`
- do not commit generated packages
- keep security checks enabled
- inspect generated output for secrets and noisy paths before sharing

Examples:

```bash
pnpm exec repomix --include "src/Proyect.Modules.Billing/**/*,tests/Proyect.Modules.Billing.Tests/**/*,tests/Proyect.IntegrationTests/Billing/**/*" -o .ai/repomix-billing.xml
rg -l "Invoice|Billing|Payment" src tests | pnpm exec repomix --stdin -o .ai/repomix-selected.xml
pnpm exec repomix --include "src/**/*,tests/**/*" --include-diffs -o .ai/repomix-diff.xml
```

---

## Output discipline
A terminal-agent task report must include:
- files inspected
- commands used
- changed files, if any
- verification run or why it was blocked
- risks or unresolved assumptions
- recommended next action

Keep reports evidence-bearing and compact. Prefer paths, symbols, commands, and blockers over prose.
