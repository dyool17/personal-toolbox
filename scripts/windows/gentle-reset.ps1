#requires -Version 7.0
<#
.SYNOPSIS
    gentle-reset — restart every local tool from a clean slate, without data loss (Windows 11 port).

.DESCRIPTION
    Windows equivalent of the bash `gentle-reset` script. Companion to
    gentle-update.ps1: where update installs new builds, this clears the stale
    state and long-lived processes that keep the old ones alive.

    Groups:

      state    Bookkeeping that outlived the process which wrote it.
               engram's unclosed session rows, leftover upgrade staging dirs.
      caches   Regenerable package-manager caches and agent scratchpads.
      daemons  Long-lived servers, stopped so the next launch picks up whatever
               `update` installs.
      update   Delegates to gentle-update.ps1.

    Order matters. State and caches are cleaned first, daemons stop next so
    their binaries can be replaced, and `update` runs last so every process
    started afterwards loads the new builds.

    NEVER touched, because none of it is garbage:

      $env:LOCALAPPDATA\qmd\models   Multi-GB of downloaded embedding models.
                                      Deleting them forces a full re-download.
      $env:LOCALAPPDATA\puppeteer    The Chrome build chrome-devtools-mcp drives.
      $env:LOCALAPPDATA\go-build     Content-addressed, so a stale entry can
                                      never produce a wrong binary. Clearing it
                                      only costs rebuild time.
      %USERPROFILE%\.claude\projects Session transcripts — the source for
                                      `claude --resume`.
      Any config, credential, or database file.

    MCP servers (qmd, codegraph, context7, chrome-devtools, engram mcp) are
    children of the agent that spawned them and exit with it. Close your agents
    instead of killing those individually.

    Windows-specific notes (verified before writing this port, not assumed):

    - herdr has GA native Windows support with its own daemon over ConPTY
      (herdr.dev/docs/windows-beta), so `herdr session list/stop` and
      `herdr server stop` work the same as on Linux/macOS — no WSL relay
      needed for local sessions. What Windows does NOT have is mosh or a
      mosh-server process, so the orphan-reaping logic that walks
      `pgrep -x herdr` + its mosh-server parent has no Windows equivalent to
      reap: a lingering herdr.exe process is just killed directly with
      Stop-Process, there's no separate transport process to chase.
    - engram honors LOCALAPPDATA as its Windows cache root (same code path
      that honors XDG_CACHE_HOME on Linux/macOS), so upgrade staging
      directories live under `$env:LOCALAPPDATA\engram-upgrade-*` instead of
      `~/.cache/engram-upgrade-*`.
    - Claude Code's per-session scratchpad is per-OS-temp-dir, not a Unix
      `/tmp/claude-$(id -u)` convention — ported to
      `$env:LOCALAPPDATA\Temp\claude-<username>` (Windows has no persistent
      UID, so the account name is the stable per-user key instead).
    - `df -h --output=avail` has no single builtin match; `Get-PSDrive` on the
      home drive reports free space in bytes, which is what's used here.
    - There is no `hash -r` equivalent to drop: Windows re-resolves PATH per
      process, so that step is simply omitted rather than translated.

.PARAMETER Target
    One of: all, state, caches, daemons, update. Defaults to all.

.PARAMETER DryRun
    Print every mutation without performing it.

.PARAMETER Force
    Kill herdr.exe processes that survive a graceful server stop.

.EXAMPLE
    .\gentle-reset.ps1
    .\gentle-reset.ps1 -Target caches -DryRun
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('all', 'state', 'caches', 'daemons', 'update')]
    [string]$Target = 'all',

    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

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

# Perform one mutation, or describe it under -DryRun.
function Invoke-Mutation {
    param([scriptblock]$Action, [string]$Description)
    if ($DryRun) {
        Write-Host "  would run: $Description" -ForegroundColor DarkGray
        return
    }
    & $Action
}

# Run one reset step. Records failures instead of aborting the run, and skips
# cleanly when the tool is not installed on this machine.
function Invoke-Step {
    param([string]$Name, [string]$Binary, [scriptblock]$Action)

    if ($Binary -ne '-' -and -not (Get-Command $Binary -ErrorAction SilentlyContinue)) {
        Add-Skip "$Name — not installed ('$Binary' is not on PATH)"
        return
    }

    Write-Host "`n$Name" -ForegroundColor White
    try {
        & $Action
        Write-Ok $Name
    } catch {
        $Failed.Add($Name)
        Write-Warn "$Name — failed ($_)"
    }
}

# Delete one regenerable path, reporting what it was worth.
function Clear-Reclaimable {
    param([string]$Label, [string]$Path)
    if (-not (Test-Path $Path)) {
        Add-Skip "$Label — nothing at $Path"
        return
    }
    $size = (Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    $sizeText = if ($size) { '{0:N1} MB' -f ($size / 1MB) } else { '?' }
    Write-Host "  $Path ($sizeText)"
    Invoke-Mutation -Description "Remove-Item -Recurse -Force $Path" -Action { Remove-Item -Recurse -Force $Path }
}

function Get-HomeFreeSpace {
    $drive = (Get-Item $env:USERPROFILE).PSDrive.Name
    $free = (Get-PSDrive -Name $drive -ErrorAction SilentlyContinue).Free
    if ($null -eq $free) { return '?' }
    return '{0:N1} GB' -f ($free / 1GB)
}

# --- state -------------------------------------------------------------------

# engram refuses to save while a project has session rows left open by a
# crashed or killed agent. The leak checker is the supported way to close them.
function Reset-EngramSessions {
    if (-not (Get-Command engram-leak-check -ErrorAction SilentlyContinue)) {
        Add-Skip 'engram sessions — engram-leak-check is not on PATH'
        return
    }
    Invoke-Mutation -Description 'engram-leak-check --fix' -Action { engram-leak-check --fix }
}

# Upgrade staging directories are named after the version they staged, so any
# directory not matching the installed build is finished work. engram honors
# LOCALAPPDATA as its Windows cache root, mirroring ~/.cache on Unix.
function Reset-EngramUpgradeStaging {
    $found = $false
    $pattern = Join-Path $env:LOCALAPPDATA 'engram-upgrade-*'
    foreach ($dir in Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue) {
        $found = $true
        Clear-Reclaimable -Label 'engram upgrade staging' -Path $dir.FullName
    }
    if (-not $found) { Add-Skip 'engram upgrade staging — none left behind' }
}

# --- caches ------------------------------------------------------------------

function Reset-NpmCaches {
    npm cache clean --force
    if ($LASTEXITCODE -ne 0) { throw 'npm cache clean failed' }
    Clear-Reclaimable -Label 'npx package cache' -Path (Join-Path $env:LOCALAPPDATA 'npm-cache\_npx')
}

function Reset-PnpmStore {
    Invoke-Mutation -Description 'pnpm store prune' -Action { pnpm store prune }
}

# Agent scratchpads are recreated per session. Only safe once the agents that
# own them have exited, which is why this group runs before `daemons`. Windows
# has no per-UID temp dir the way Unix has /tmp/claude-$(id -u); the account
# name is the closest stable per-user key under the OS temp root.
function Reset-AgentScratchpads {
    $path = Join-Path $env:LOCALAPPDATA "Temp\claude-$env:USERNAME"
    Clear-Reclaimable -Label 'agent scratchpads' -Path $path
}

# --- daemons -----------------------------------------------------------------

# Windows has no mosh-server to chase: herdr's native Windows daemon runs over
# ConPTY directly, so a surviving herdr.exe is the whole orphan, not a parent
# of one. Anything still alive after a graceful stop is genuinely orphaned, so
# it is reported rather than killed unless -Force says otherwise.
function Clear-HerdrOrphans {
    $procs = Get-Process herdr -ErrorAction SilentlyContinue
    if (-not $procs) {
        Write-Ok 'no herdr processes left'
        return
    }

    if (-not $Force) {
        Add-Skip "herdr — $($procs.Count) process(es) survived the stop ($(($procs.Id) -join ', ')); re-run with -Force"
        return
    }

    foreach ($proc in $procs) {
        Write-Host "  killing herdr $($proc.Id)"
        Invoke-Mutation -Description "Stop-Process -Id $($proc.Id) -Force" -Action { Stop-Process -Id $proc.Id -Force }
    }
}

function Stop-Herdr {
    $sessions = (herdr session list 2>$null) | Select-Object -Skip 1 |
        ForEach-Object { ($_ -split '\s+') } |
        Where-Object { $_[1] -eq 'running' } |
        ForEach-Object { $_[0] }

    foreach ($name in $sessions) {
        if (-not $name) { continue }
        Write-Host "  stopping session $name"
        Invoke-Mutation -Description "herdr session stop $name" -Action { herdr session stop $name }
    }

    Invoke-Mutation -Description 'herdr server stop' -Action { herdr server stop }
    if (-not $DryRun) { Start-Sleep -Seconds 2 }
    Clear-HerdrOrphans
}

# `engram serve` has no stop subcommand; it is restarted on demand by whatever
# next needs the HTTP API.
function Stop-EngramServe {
    $proc = Get-Process | Where-Object { $_.Path -like '*engram*' -and (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine -like '*serve*' } -ErrorAction SilentlyContinue
    if (-not $proc) {
        Add-Skip 'engram serve — not running'
        return
    }
    Invoke-Mutation -Description 'Stop-Process (engram serve)' -Action { $proc | Stop-Process -Force }
    Write-Ok 'engram serve stopped — it restarts on demand'
}

# --- main --------------------------------------------------------------------

function Test-Wants {
    param([string]$Group)
    return ($Target -eq 'all') -or ($Target -eq $Group)
}

# herdr will not stop its own server from inside one of its sessions, so that
# one step is reported as skipped rather than aborting the whole run. A dry
# run applies the same rule so it predicts what the real run will actually do.
$InHerdr = [bool]$env:HERDR_ENV

if ($DryRun) { Write-Bold 'Dry run — nothing will be changed' }

$FreeBefore = Get-HomeFreeSpace

if (Test-Wants 'state') {
    Write-Heading 'Stale state'
    Invoke-Step -Name 'engram sessions'        -Binary '-' -Action { Reset-EngramSessions }
    Invoke-Step -Name 'engram upgrade staging' -Binary '-' -Action { Reset-EngramUpgradeStaging }
}

if (Test-Wants 'caches') {
    Write-Heading 'Regenerable caches'
    Invoke-Step -Name 'npm caches'        -Binary 'npm'  -Action { Reset-NpmCaches }
    Invoke-Step -Name 'pnpm store'        -Binary 'pnpm' -Action { Reset-PnpmStore }
    Invoke-Step -Name 'agent scratchpads' -Binary '-'    -Action { Reset-AgentScratchpads }
}

if (Test-Wants 'daemons') {
    Write-Heading 'Long-lived daemons'
    if ($InHerdr) {
        Add-Skip 'herdr — NOT reset: this shell is inside a herdr session (HERDR_ENV is set)'
        Write-Warn '  herdr cannot stop its own server from within one of its sessions.'
        Write-Warn '  Every other step still ran. To reset herdr too: detach, then run'
        Write-Warn "  'gentle-reset.ps1 daemons' from the shell you land in."
    } else {
        Invoke-Step -Name 'herdr' -Binary 'herdr' -Action { Stop-Herdr }
    }
    Invoke-Step -Name 'engram serve' -Binary 'engram' -Action { Stop-EngramServe }
}

if (Test-Wants 'update') {
    Write-Heading 'Updates'
    $updateScript = Join-Path $PSScriptRoot 'gentle-update.ps1'
    Invoke-Step -Name 'gentle-update' -Binary '-' -Action {
        Invoke-Mutation -Description $updateScript -Action { & $updateScript }
    }
}

if ($Skipped.Count -gt 0) {
    Write-Bold 'Skipped'
    $Skipped | ForEach-Object { "  • $_" }
}

Write-Bold 'Disk'
"  available on $($env:USERPROFILE)'s drive: $FreeBefore -> $(Get-HomeFreeSpace)"

if ($Failed.Count -gt 0) {
    Write-Bold 'Failed'
    $Failed | ForEach-Object { "  • $_" }
    exit 1
}

if ($DryRun) {
    Write-Bold 'Dry run complete — nothing was changed. Drop -DryRun to apply.'
} elseif ($InHerdr -and (Test-Wants 'daemons')) {
    Write-Bold 'Done — but herdr is still running the build it started with.'
    Write-Host "  Detach and run 'gentle-reset.ps1 daemons' to pick up the new one."
} else {
    Write-Bold 'Done — start herdr, then your agents, so they load the new builds.'
}
