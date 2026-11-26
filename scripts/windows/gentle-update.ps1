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
      toolchain  Stable Gentleman releases: Gentle AI v5.0.0, latest Engram
                 v3, and the latest stable Gentle Shell v5 for an existing
                 npm-based Pi extension, then `gentle-ai sync`.
      plugins    Claude Code marketplaces and installed plugins.
      packages   Global package managers and standalone binaries.
                 npm globals, pnpm globals, moshi-hook, mise itself.
      runtimes   Language runtimes managed by mise. NOT part of `all` — see below.

    Agents run before the toolchain so `gentle-ai sync` observes the updated
    agent configuration. General Pi, npm, and pnpm updates leave Gentle Shell
    alone. Native launchers, legacy Git extensions, ambiguous installations,
    and unverifiable v5 releases require manual action. See:
    https://github.com/Gentleman-Programming/gentle-shell/releases
    After a Gentle Shell extension update, restart Pi and run `gentle-ai sync`.
    The Engram binary update does not restart or migrate its server.

    `runtimes` is opt-in on purpose. mise installs each runtime into its own
    directory and npm globals do not carry across Node versions, so bumping Node
    silently orphans every globally installed CLI. Run it when you are ready to
    reinstall those, not as part of a routine refresh.

    Windows-specific notes (verified before writing this port, not assumed):

    - claude/codex/opencode/pi/mise/moshi-hook are the same Node/Go/Rust CLIs on
      Windows and expose the identical subcommands used here (`claude update`,
      `codex update`, `opencode upgrade`, `pi update --self`,
      `pi update --extension <source>`, `mise upgrade`/`mise self-update`,
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
    - Gentle AI has no official Windows binary archive. The updater uses
      `go install` with the published version and matching module major.
      Go binaries get a `.exe` suffix.

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

# Bump the Gentle AI pin (and keep it in sync with Linux) for a new release.
$GentleAiPkg = 'github.com/gentleman-programming/gentle-ai/v5/cmd/gentle-ai@v5.0.0'
$EngramPkg = 'github.com/Gentleman-Programming/engram/v3/cmd/engram@latest'
$GentleShellReleases = 'https://github.com/Gentleman-Programming/gentle-shell/releases'
$NpmRegistry = 'https://registry.npmjs.org/'
$NpmNamePattern = '(?:@[A-Za-z0-9_][A-Za-z0-9._-]*/)?[A-Za-z0-9_][A-Za-z0-9._-]*'

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
# cleanly when the tool is not installed on this machine. ChecksExitCode actions
# throw on real failures themselves (for example, after a failed metadata lookup that can be skipped).
function Invoke-Step {
    param(
        [string]$Name,
        [string]$Binary,
        [scriptblock]$Action,
        [switch]$ChecksExitCode
    )

    if ($Binary -ne '-' -and -not (Get-Command $Binary -ErrorAction SilentlyContinue)) {
        Add-Skip "$Name — not installed ('$Binary' is not on PATH)"
        return
    }

    Write-Host "`n$Name" -ForegroundColor White
    try {
        & $Action
        if (-not $ChecksExitCode -and $LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
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

function Show-Versions {
    foreach ($t in 'claude', 'codex', 'opencode', 'pi', 'herdr', 'gentle-ai', 'engram', 'mise', 'qmd') {
        '  {0,-12} {1}' -f $t, (Get-VersionOf $t)
    }
    $shellVersion = Get-VersionOf 'gentle-shell'
    if (-not $shellVersion -or $shellVersion -eq 'unknown') { $shellVersion = '—' }
    '  {0,-12} {1}' -f 'gentle-pi', $shellVersion
}

# --- toolchain ---------------------------------------------------------------

# Build a Go release into $BinDir, keeping one rolling backup.
# GOBIN is set explicitly (same override the bash version relies on) so this
# never depends on %USERPROFILE%\go\bin being on PATH.
function Install-GoRelease {
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

function Add-GentleShellSkip {
    param([string]$Reason)
    Add-Skip "$Reason. Choose an official v5 release and follow its installation instructions: $GentleShellReleases"
}

function Get-PiPackages {
    $PSNativeCommandUseErrorActionPreference = $false
    # Inspect both scopes for conflicting sources. Approval is for this read-only
    # inventory only; updates must still use Pi's saved project trust.
    $lines = @(pi list --approve 2>&1)
    if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) { throw 'could not list Pi packages' }

    $scope = $null
    $entries = @()
    foreach ($raw in $lines) {
        $line = "$raw" -replace '\x1b\[[0-9;]*m', ''
        if ($line -eq 'User packages:') { $scope = 'User' }
        elseif ($line -eq 'Project packages:') { $scope = 'Project' }
        elseif ($line -eq 'No packages installed.' -and $lines.Count -eq 1) { return }
        elseif (-not $line.Trim()) { continue }
        elseif ($scope -and $line -match '^ {2}(\S.*?)(?: \(filtered\))?$') {
            $entries += [pscustomobject]@{ Scope = $scope; Source = $Matches[1]; InstalledPath = $null }
        } elseif ($entries.Count -gt 0 -and $line -match '^ {4}(\S.*)$' -and -not $entries[-1].InstalledPath) {
            $entries[-1].InstalledPath = $Matches[1]
        } else {
            throw 'unexpected output from pi list; Pi packages left unchanged'
        }
    }
    if ($entries.Count -eq 0) { throw 'no usable package list from Pi' }
    return $entries
}

function Test-GentleShellSource {
    param([string]$Source)
    $decoded = [uri]::UnescapeDataString($Source)
    if ($decoded -cmatch '^npm:') {
        return $decoded -match '(?:^|@)npm:\s*gentle-pi(?:@|$)|/gentle-pi/-/gentle-pi-'
    }
    return $decoded -match '(?:^|[/:\\])(?:gentle-shell|gentle-pi)(?:\.git)?(?:[/\\@#?]|$)'
}

function Update-GentlePi {
    $manual = "For an installer-managed launcher with upgrade support, run 'gentle-shell upgrade --channel release' manually; otherwise follow the official installer guidance: $GentleShellReleases/tag/v5.0.0"
    if (Get-Command gentle-shell -ErrorAction SilentlyContinue) {
        Add-Skip "gentle-pi — a Gentle Shell launcher is on PATH. $manual"
        return
    }
    if (-not (Get-Command pi -ErrorAction SilentlyContinue)) {
        Add-Skip "gentle-pi — standalone Pi is not on PATH. $manual"
        return
    }

    try {
        $shellPackages = @(foreach ($entry in (Get-PiPackages)) {
            # Pi reports the installed path for each scope, including local
            # aliases. Read only a drive-local package manifest, never execute it.
            if ($entry.InstalledPath -notmatch '^[A-Za-z]:[\\/]') { throw 'missing or non-local package path' }
            $manifestPath = Join-Path $entry.InstalledPath 'package.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
            if ($manifest -isnot [System.Collections.IDictionary] -or
                $manifest['name'] -isnot [string] -or $manifest['name'] -cnotmatch "^$NpmNamePattern\z") {
                throw 'no usable package identity'
            }
            if ($manifest.name -eq 'gentle-pi' -or (Test-GentleShellSource $entry.Source)) {
                if ($entry.Source -cmatch '^npm:gentle-pi(?:@|$)' -and $manifest.name -cne 'gentle-pi') {
                    throw 'Gentle Shell manifest disagrees with its npm source'
                }
                $entry
            }
        })
    } catch {
        Add-GentleShellSkip 'gentle-pi — unable to verify all Pi package identities; extension left unchanged'
        return
    }
    # Pi can replace the version of the same user npm package without adding
    # a second source. Git, project, custom pins and aliases need owner review.
    if ($shellPackages.Count -ne 1 -or $shellPackages[0].Scope -ne 'User' -or
        $shellPackages[0].Source -cnotmatch '^npm:gentle-pi(?:@(?:latest|[45](?:\.(?:0|[1-9]\d*)){0,2}))?$') {
        Add-GentleShellSkip 'gentle-pi — no unambiguous user npm extension; review Pi sources with pi list before changing them'
        return
    }

    $PSNativeCommandUseErrorActionPreference = $false
    $version = $null
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        try {
            $offline = npm config get offline 2>$null
            if ($LASTEXITCODE -ne 0 -or ($offline -join "`n").Trim() -cne 'false') {
                Add-GentleShellSkip 'gentle-pi — npm is offline or its offline setting could not be verified; extension left unchanged'
                return
            }
            # Request the registry directly: npm view can fall back to a stale
            # cache on a network error even with --prefer-online.
            $metadata = Invoke-RestMethod -Uri "${NpmRegistry}gentle-pi" -TimeoutSec 15 -MaximumRedirection 0 -Headers @{
                Accept = 'application/vnd.npm.install-v1+json'
                'Cache-Control' = 'no-cache'
            }
            if ($metadata.name -ceq 'gentle-pi') {
                $version = $metadata.versions.PSObject.Properties.Name |
                    Where-Object { $_ -cmatch '^5\.(0|[1-9]\d*)\.(0|[1-9]\d*)$' } |
                    ForEach-Object { [version]$_ } | Sort-Object -Descending | Select-Object -First 1
            }
        } catch { $version = $null }
    }
    if (-not $version) {
        Add-GentleShellSkip 'gentle-pi — could not verify a stable v5 release on npm; extension left unchanged'
        return
    }

    $source = "npm:gentle-pi@$version"
    $current = $shellPackages[0]
    if ($current.Source -match '^npm:gentle-pi@(5\.\d+\.\d+)$' -and ([version]$Matches[1]) -gt $version) {
        Add-Skip "gentle-pi — keeping newer configured source $($current.Source)"
        return
    }
    if ($current.Source -ceq $source) {
        Write-Host "  $source is already configured and installed"
        return
    }
    # Pi has no --registry option. Pass the same registry to its npm child;
    # a custom Pi package-manager command can override or ignore npm settings.
    $previousRegistry = $env:NPM_CONFIG_REGISTRY
    try {
        $env:NPM_CONFIG_REGISTRY = $NpmRegistry
        pi install $source --no-approve
        if ($LASTEXITCODE -ne 0) { throw "pi install failed for $source" }
    } finally {
        $env:NPM_CONFIG_REGISTRY = $previousRegistry
    }
    Write-Warn "Installed $source. Restart Pi, then run 'gentle-ai sync'."
}

function Update-PiExtensions {
    $PSNativeCommandUseErrorActionPreference = $false
    $packages = @(Get-PiPackages)
    $protected = @($packages | Where-Object { Test-GentleShellSource $_.Source })
    if ($protected.Count -gt 0) {
        Add-GentleShellSkip 'Pi extensions — Gentle Shell is handled separately by toolchain or its installation owner'
    }
    # Pi matches npm packages by name, not by pin, across both scopes. If an
    # alias is protected in either scope, do not pass its identity to Pi at all.
    $npmSourcePattern = "^npm:\s*($NpmNamePattern)(?:@.+)?\s*\z"
    $blockedNames = @($protected | ForEach-Object {
        if ($_.Source -cmatch $npmSourcePattern) { $Matches[1] }
    })
    $piCommand = Get-Command pi
    if ($piCommand.CommandType -eq 'Alias') { $piCommand = $piCommand.ResolvedCommand }
    $usesBatchShim = $piCommand.Path -match '\.(?:cmd|bat)$'
    $targets = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($package in $packages) {
        $source = $package.Source
        if (Test-GentleShellSource $source) { continue }
        if ($source -cmatch $npmSourcePattern) {
            if ($Matches[1] -in $blockedNames) { continue }
            $source = "npm:$($Matches[1])"
        } elseif ($source -cmatch '^(?:git:|(?:https?|ssh|git)://)') {
            # Allow URL escapes, not %VAR% syntax. Through a batch shim,
            # even two valid escapes can delimit a cmd.exe variable name.
            if ($source -cnotmatch '\A(?:[A-Za-z0-9._~:/@+#=\-]|%[0-9A-Fa-f]{2})+\z' -or
                ($usesBatchShim -and $source -match '%.*%')) {
                $quoted = ($source -replace '[\x00-\x1f\x7f]', '?').Replace("'", "''")
                Add-Skip "Pi extensions — Git source '$quoted' needs a manual update. Review the source, then use a native Pi executable or PowerShell shim: pi update --extension '$quoted'"
                continue
            }
        } else {
            continue  # Pi does not update local-path packages.
        }
        if (-not $targets.ContainsKey($source) -or $package.Scope -eq 'User') {
            $targets[$source] = $package.Scope
        }
    }

    $failed = @()
    foreach ($source in $targets.Keys) {
        $output = @(pi update --extension $source 2>&1)
        $status = $LASTEXITCODE
        if ($status -ne 0) {
            # Read-only inventory included project entries even when the saved
            # trust check used by update hides them.
            if ($targets[$source] -ne 'User' -and $output.Count -eq 1 -and
                ("$($output[0])" -replace '\x1b\[[0-9;]*m', '') -ceq "Error: No matching package found for $source") {
                continue
            }
            $failed += $source
        }
        $output | ForEach-Object { Write-Host "$_" }
    }
    if ($failed.Count -gt 0) { throw "Pi extension updates failed: $($failed -join ', ')" }
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

function Get-UpdatableGlobals {
    param([object[]]$Projects, [string]$Manager)
    $candidates = @()
    $excluded = @()
    foreach ($project in $Projects) {
        if ($project -isnot [System.Collections.IDictionary] -or $project.Contains('error')) {
            throw "$Manager did not return a usable global package list"
        }
        $deps = $project['dependencies']
        if ($null -eq $deps) { continue }
        if ($deps -isnot [System.Collections.IDictionary]) { throw "$Manager returned invalid global dependencies" }
        foreach ($name in $deps.psbase.Keys) {
            $pkg = $deps[$name]
            # npm --long reports the installed manifest name, including npm
            # aliases. pnpm reports the real package name under 'from' or 'name'.
            $identities = @(@($pkg.name, $pkg.from) | Where-Object { $_ -is [string] -and $_ -cmatch "^$NpmNamePattern\z" })
            if ($name -eq 'gentle-pi' -or 'gentle-pi' -in $identities) {
                Add-GentleShellSkip "$Manager globals — leaving '$name' to its installation owner"
                $excluded += $name
            } elseif ($name -cnotmatch "^$NpmNamePattern\z" -or $identities.Count -eq 0) {
                Add-Skip "$Manager globals — could not verify the identity of '$name'"
                $excluded += $name
            } else {
                $candidates += $name
            }
        }
    }
    $candidates | Where-Object { $_ -notin $excluded } | Select-Object -Unique
}

function Update-NpmGlobals {
    $json = npm ls -g --depth=0 --long --json
    if ($LASTEXITCODE -ne 0 -or -not $json) { throw 'npm ls did not return a usable global package list' }
    $listing = ($json -join "`n") | ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($listing -isnot [System.Collections.IDictionary]) { throw 'invalid npm global package list' }
    $names = @(Get-UpdatableGlobals -Projects @($listing) -Manager npm)
    if ($names.Count -eq 0) { return }
    npm update -g @names
    if ($LASTEXITCODE -ne 0) { throw 'npm update -g failed' }
    if ($names -contains 'pnpm') { Restore-PnpmBins }
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
    $json = pnpm ls -g --depth=0 --json
    if ($LASTEXITCODE -ne 0 -or -not $json) { throw 'pnpm ls did not return a usable global package list' }
    $listing = ($json -join "`n") | ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($listing -isnot [array]) { throw 'invalid pnpm global package list' }
    $names = @(Get-UpdatableGlobals -Projects $listing -Manager pnpm)
    if ($names.Count -eq 0) { return }
    pnpm update -g --latest @names
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
    Invoke-Step -Name 'Pi extensions'    -Binary 'pi'       -ChecksExitCode -Action { Update-PiExtensions }
    Update-Herdr
}

if (Test-Wants 'toolchain') {
    Write-Heading 'Gentleman toolchain (stable releases)'
    Invoke-Step -Name 'gentle-ai' -Binary 'go' -Action { Install-GoRelease -Name 'gentle-ai' -Pkg $GentleAiPkg }
    Invoke-Step -Name 'engram'    -Binary 'go' -Action { Install-GoRelease -Name 'engram'    -Pkg $EngramPkg }
    Sync-GentleAiDevOverride
    Invoke-Step -Name 'gentle-pi' -Binary '-' -ChecksExitCode -Action { Update-GentlePi }
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
