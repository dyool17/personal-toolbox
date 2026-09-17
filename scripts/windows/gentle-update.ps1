#requires -Version 7.0
<#
.SYNOPSIS
    gentle-update — refresh every local development tool in one command (Windows 11 port).

.DESCRIPTION
    Windows equivalent of the bash `gentle-update` script. Same groups, same
    reasoning, same "one failing tool never stops the rest" contract.

    Groups, because they track deliberately different things:

      agents     AI coding agents, each through its own updater -> latest stable.
                 Claude Code, Codex, OpenCode, Pi. (herdr is included here too —
                 see the Windows note below.)
      toolchain  Gentleman source builds pinned to the tip of main.
                 gentle-ai, engram, gentle-pi, then `gentle-ai sync`.
      plugins    Claude Code marketplaces and installed plugins.
      packages   Global package managers and standalone binaries.
                 npm globals, pnpm globals, moshi-hook, mise itself.
      runtimes   Language runtimes managed by mise. NOT part of `all` — see below.

    Agents run before the toolchain so gentle-pi is rebuilt against an already
    current Pi, and so `gentle-ai sync` observes the final agent configuration.

    `runtimes` is opt-in on purpose. mise installs each runtime into its own
    directory and npm globals do not carry across Node versions, so bumping Node
    silently orphans every globally installed CLI. Run it when you are ready to
    reinstall those, not as part of a routine refresh.

    Windows-specific notes (verified before writing this port, not assumed):

    - claude/codex/opencode/pi/mise/moshi-hook are the same Node/Go/Rust CLIs on
      Windows and expose the identical subcommands used here (`claude update`,
      `codex update`, `opencode upgrade`, `pi update --self`,
      `pi update --extensions`, `mise upgrade`/`mise self-update`,
      `moshi-hook update`). Nothing had to be swapped for a store-manager
      equivalent (winget/scoop/choco) because these tools ship their own
      updater on every platform including Windows.
    - herdr now has GA native Windows support (its own daemon over ConPTY, no
      WSL/SSH relay required for local sessions) per herdr.dev/docs/windows-beta,
      so `herdr update` runs the same as on Linux/macOS.
    - moshi-hook's own docs mark Windows support "experimental" (Authenticode
      signing still pending, "stable path on Windows is still WSL"). It is kept
      in the `packages` group like the original, but failures here are more
      likely on Windows and are reported, never treated as fatal.
    - `go install ...@main` behaves identically; only the destination changes:
      GOBIN defaults to `%USERPROFILE%\go\bin` on Windows (vs `$GOPATH/bin` on
      Unix), and binaries get a `.exe` suffix.

.PARAMETER Target
    One of: all, agents, toolchain, plugins, packages, runtimes. Defaults to all.

.EXAMPLE
    .\gentle-update.ps1
    .\gentle-update.ps1 -Target toolchain
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('all', 'agents', 'toolchain', 'plugins', 'packages', 'runtimes')]
    [string]$Target = 'all'
)

$ErrorActionPreference = 'Stop'

# Same destination Gentleman tools already assume exists on this machine —
# keep Go-built binaries next to everything else instead of scattering them
# across %USERPROFILE%\go\bin.
$BinDir = if ($env:GENTLE_UPDATE_BIN_DIR) { $env:GENTLE_UPDATE_BIN_DIR } else { Join-Path $env:USERPROFILE '.local\bin' }

$GentleAiPkg  = 'github.com/gentleman-programming/gentle-ai/v3/cmd/gentle-ai@main'
$EngramPkg    = 'github.com/Gentleman-Programming/engram/v2/cmd/engram@main'
# gentle-pi's GitHub repo was renamed to gentle-shell (still the same npm
# package, "gentle-pi"; GitHub 301-redirects the old URL, but Pi resolves the
# checkout directory from the URL it's given, so track the canonical name).
$GentlePiPkg      = 'git:github.com/Gentleman-Programming/gentle-shell@main'
$GentlePiCheckout = Join-Path $env:USERPROFILE '.pi\agent\git\github.com\Gentleman-Programming\gentle-shell'

$Failed  = New-Object System.Collections.Generic.List[string]
$Skipped = New-Object System.Collections.Generic.List[string]

function Write-Bold    { param($Text) Write-Host "`n$Text" -ForegroundColor White }
function Write-Heading { param($Text) Write-Host "`n── $Text ──" -ForegroundColor Magenta }
function Write-Ok      { param($Text) Write-Host "✓ $Text" -ForegroundColor Green }
function Write-Warn    { param($Text) Write-Host "! $Text" -ForegroundColor Yellow }

function Add-Skip {
    param([string]$Reason)
    $Skipped.Add($Reason)
    Write-Warn $Reason
}

# Run one update step. Records failures instead of aborting the run, and skips
# cleanly when the tool is not installed on this machine.
function Invoke-Step {
    param(
        [string]$Name,
        [string]$Binary,
        [scriptblock]$Action
    )

    if ($Binary -ne '-' -and -not (Get-Command $Binary -ErrorAction SilentlyContinue)) {
        Add-Skip "$Name — not installed ('$Binary' is not on PATH)"
        return
    }

    Write-Host "`n$Name" -ForegroundColor White
    try {
        & $Action
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
        Write-Ok $Name
    } catch {
        $Failed.Add($Name)
        Write-Warn "$Name — update failed ($_)"
    }
}

function Get-VersionOf {
    param([string]$Binary)
    if (-not (Get-Command $Binary -ErrorAction SilentlyContinue)) { return '—' }
    try {
        $out = & $Binary --version 2>$null | Select-Object -First 1
        if ($out) { return $out.ToString().Trim() } else { return 'unknown' }
    } catch { return 'unknown' }
}

function Get-GentlePiCommit {
    if (-not (Test-Path $GentlePiCheckout)) { return '—' }
    try {
        Push-Location $GentlePiCheckout
        $out = git log -1 --format='%h %cs' 2>$null
        Pop-Location
        if ($out) { return $out } else { return 'unknown' }
    } catch { return 'unknown' }
}

function Show-Versions {
    foreach ($t in 'claude', 'codex', 'opencode', 'pi', 'herdr', 'gentle-ai', 'engram', 'mise', 'qmd') {
        '  {0,-12} {1}' -f $t, (Get-VersionOf $t)
    }
    '  {0,-12} {1}' -f 'gentle-pi', (Get-GentlePiCommit)
}

# --- toolchain ---------------------------------------------------------------

# Build a Go binary from main into $BinDir, keeping one rolling backup.
# GOBIN is set explicitly (same override the bash version relies on) so this
# never depends on %USERPROFILE%\go\bin being on PATH.
function Install-FromMain {
    param([string]$Name, [string]$Pkg)

    $target = Join-Path $BinDir "$Name.exe"
    if (Test-Path $target) {
        Copy-Item $target "$target.prev" -Force
    }

    # A throwaway working directory keeps the build out of any local Go module.
    $workdir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $workdir | Out-Null
    try {
        Push-Location $workdir
        $env:GOBIN = $BinDir
        $env:GOFLAGS = ''
        go install $Pkg
        $status = $LASTEXITCODE
        Pop-Location
    } finally {
        Remove-Item -Recurse -Force $workdir -ErrorAction SilentlyContinue
    }
    if ($status -ne 0) { throw "go install failed for $Pkg" }

    # Remove copies in earlier PATH directories that would shadow $BinDir.
    $gopathBin = Join-Path (go env GOPATH) 'bin'
    if ($gopathBin -ne $BinDir) {
        $shadow = Join-Path $gopathBin "$Name.exe"
        if (Test-Path $shadow) { Remove-Item $shadow -Force }
    }
}

# gentle-pi can be pinned to a locally built gentle-ai through a registration
# file, and it refuses to fall back silently while that override is declared.
# Rebuilding gentle-ai into $BinDir removes the shadowing copy the override may
# still name, so repair a *broken* override here. An override whose binary
# still exists is a deliberate choice and is never redirected.
function Sync-GentleAiDevOverride {
    $configHome = if ($env:GENTLE_PI_CONFIG_HOME) { $env:GENTLE_PI_CONFIG_HOME } else { Join-Path $env:USERPROFILE '.pi\gentle-ai' }
    $file   = Join-Path $configHome 'dev-binary.json'
    $target = Join-Path $BinDir 'gentle-ai.exe'

    if (-not (Test-Path $file)) { return }
    if (-not (Test-Path $target)) { return }

    $json = Get-Content $file -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $json -or -not $json.path) { return }
    if (Test-Path $json.path) { return }

    @{ schema = 'gentle-pi.dev-binary/v1'; path = $target } | ConvertTo-Json | Set-Content $file
    Write-Ok "repaired gentle-pi dev binary override -> $target"
}

function Update-GentlePi {
    pi update --extension $GentlePiPkg
    if ($LASTEXITCODE -eq 0) { return }
    Write-Warn "falling back to a fresh install of $GentlePiPkg"
    pi install $GentlePiPkg
}

# --- agents ------------------------------------------------------------------

function Update-Herdr {
    if (-not (Get-Command herdr -ErrorAction SilentlyContinue)) {
        Add-Skip 'herdr — not installed'
        return
    }
    # herdr's Windows daemon is the same GA build as Linux/macOS (native
    # ConPTY, no WSL relay for local sessions), so no special-casing is
    # needed the way the bash version special-cases running inside herdr —
    # HERDR_ENV means the same thing here.
    if ($env:HERDR_ENV) {
        Add-Skip "herdr — run 'herdr update' from a terminal outside herdr"
        return
    }
    Invoke-Step -Name 'herdr' -Binary 'herdr' -Action { herdr update }
}

# --- plugins -----------------------------------------------------------------

function Update-ClaudePlugins {
    claude plugin marketplace update
    if ($LASTEXITCODE -ne 0) { throw 'marketplace update failed' }

    $status = 0
    $plugins = (claude plugin list 2>$null) | Select-String -Pattern '[A-Za-z0-9_-]+@[A-Za-z0-9_-]+' -AllMatches |
        ForEach-Object { $_.Matches.Value }
    foreach ($plugin in $plugins) {
        if (-not $plugin) { continue }
        Write-Host "  updating $plugin"
        claude plugin update $plugin
        if ($LASTEXITCODE -ne 0) { $status = 1 }
    }
    if ($status -ne 0) { throw 'one or more plugin updates failed' }
}

# --- packages ----------------------------------------------------------------

# npm and corepack can both claim the `pnpm`/`pnpx` shims on Windows the same
# way they fight over symlinks on Unix; on Windows this shows up as npm's
# global shim `.cmd`/`.ps1` files getting rewritten. Detect and restore them
# the same way the bash version restores the Unix symlinks.
function Restore-PnpmBins {
    try {
        $npmBin = Split-Path (Get-Command npm).Source -Parent
    } catch { return }
    $pkg = Join-Path $npmBin '..\node_modules\pnpm'
    if (-not (Test-Path $pkg)) { return }

    foreach ($name in 'pnpm', 'pnpx') {
        $shim = Join-Path $npmBin "$name.cmd"
        if ((Test-Path $shim) -and (Get-Content $shim -Raw) -match 'corepack') {
            npm install -g pnpm --force
            Write-Ok "restored '$name' to the installed pnpm (corepack had claimed it)"
            break
        }
    }
}

function Update-NpmGlobals {
    npm update -g
    if ($LASTEXITCODE -ne 0) { throw 'npm update -g failed' }
    Restore-PnpmBins
}

function Update-PnpmGlobals {
    # Default global store on Windows; matches the bash version's guard for a
    # missing store instead of assuming pnpm is fully set up.
    $pnpmHome = if ($env:PNPM_HOME) { $env:PNPM_HOME } else { Join-Path $env:LOCALAPPDATA 'pnpm' }
    if (-not (Test-Path $pnpmHome)) {
        Add-Skip "pnpm globals — no global store at $pnpmHome"
        return
    }
    $env:PNPM_HOME = $pnpmHome
    $env:Path = "$pnpmHome;$env:Path"
    pnpm update -g --latest
    if ($LASTEXITCODE -ne 0) { throw 'pnpm update -g failed' }
}

# --- runtimes ----------------------------------------------------------------

function Update-Runtimes {
    Write-Warn 'mise installs each runtime in its own directory; npm globals do not'
    Write-Warn 'carry across Node versions. Reinstall your global CLIs afterwards.'
    mise upgrade --yes
    if ($LASTEXITCODE -ne 0) { throw 'mise upgrade failed' }
}

# --- main --------------------------------------------------------------------

function Test-Wants {
    param([string]$Group)
    return ($Target -eq 'all') -or ($Target -eq $Group)
}

New-Item -ItemType Directory -Path $BinDir -Force | Out-Null

Write-Bold 'Before'
Show-Versions

if (Test-Wants 'agents') {
    Write-Heading 'AI agents (latest stable)'
    Invoke-Step -Name 'Claude Code'      -Binary 'claude'   -Action { claude update }
    Invoke-Step -Name 'Codex'            -Binary 'codex'    -Action { codex update }
    Invoke-Step -Name 'OpenCode'         -Binary 'opencode' -Action { opencode upgrade }
    Invoke-Step -Name 'Pi'               -Binary 'pi'       -Action { pi update --self }
    Invoke-Step -Name 'Pi extensions'    -Binary 'pi'       -Action { pi update --extensions }
    Update-Herdr
}

if (Test-Wants 'toolchain') {
    Write-Heading 'Gentleman toolchain (tip of main)'
    Invoke-Step -Name 'gentle-ai' -Binary 'go' -Action { Install-FromMain -Name 'gentle-ai' -Pkg $GentleAiPkg }
    Invoke-Step -Name 'engram'    -Binary 'go' -Action { Install-FromMain -Name 'engram'    -Pkg $EngramPkg }
    Sync-GentleAiDevOverride
    Invoke-Step -Name 'gentle-pi' -Binary 'pi' -Action { Update-GentlePi }
    Invoke-Step -Name 'gentle-ai sync' -Binary 'gentle-ai' -Action { gentle-ai sync }
}

if (Test-Wants 'plugins') {
    Write-Heading 'Claude Code plugins'
    Invoke-Step -Name 'Claude Code plugins' -Binary 'claude' -Action { Update-ClaudePlugins }
}

if (Test-Wants 'packages') {
    Write-Heading 'Global packages'
    Invoke-Step -Name 'npm globals'  -Binary 'npm'        -Action { Update-NpmGlobals }
    Invoke-Step -Name 'pnpm globals' -Binary 'pnpm'       -Action { Update-PnpmGlobals }
    Invoke-Step -Name 'moshi-hook'   -Binary 'moshi-hook' -Action { moshi-hook update }
    Invoke-Step -Name 'mise'         -Binary 'mise'       -Action { mise self-update --yes }
}

# Opt-in only: never reached by `all`.
if ($Target -eq 'runtimes') {
    Write-Heading 'Language runtimes (mise)'
    Invoke-Step -Name 'mise runtimes' -Binary 'mise' -Action { Update-Runtimes }
}

# Windows resolves commands fresh from PATH per process; there is no shell
# hash table to clear the way `hash -r` clears bash's, so that step is simply
# dropped rather than ported.

Write-Bold 'After'
Show-Versions

if ($Skipped.Count -gt 0) {
    Write-Bold 'Skipped'
    $Skipped | ForEach-Object { "  • $_" }
}

if ($Failed.Count -gt 0) {
    Write-Bold 'Failed'
    $Failed | ForEach-Object { "  • $_" }
    Write-Host "`nRestart your agents once the failures above are resolved."
    exit 1
}

Write-Bold 'Done — restart Claude Code, Pi, and any open agent to load the new builds.'
