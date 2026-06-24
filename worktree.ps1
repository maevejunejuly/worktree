<#
.SYNOPSIS
  Manage git worktrees for parallel Claude Code phase development.

.DESCRIPTION
  Commands:
    (no args)       - interactive dashboard with arrow-key navigation
    start <branch>  - create worktree, symlink node_modules, copy env, launch claude
    done  <branch>  - remove worktree, prune git

.EXAMPLE
  worktree
  worktree start phase-14-foo
  worktree done  phase-14-foo

.NOTES
  Edit the CONFIG block below to adapt to another project.
  - Hosted DB (Supabase etc): all worktrees share the remote DB, no isolation needed
  - node_modules in repo root is junction-linked into each worktree (saves ~500 MB)
  - .env.local in repo root is copied into each worktree
  - PORT is derived deterministically from branch name (SHA-256 hash), stored in .env.worktree
  - Worktrees land at .claude/worktrees/<sanitized-branch>/ (already gitignored)
#>

param(
    [Parameter(Position = 0)]
    [string]$Command = '',

    [Parameter(Position = 1)]
    [string]$Branch = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# CONFIG - edit these for a different project
# ---------------------------------------------------------------------------
$RepoRoot     = (git rev-parse --show-toplevel).Trim()   # run from project root
$WorktreeBase = Join-Path $RepoRoot '.claude\worktrees'
$PortMin      = 3100   # deterministic port range: 3100-3999
$PortMax      = 3999
$EnvSource    = Join-Path $RepoRoot '.env.local'  # copied into each worktree
# ---------------------------------------------------------------------------

function Get-BranchPort([string]$name) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($name)
    $hash  = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    $num   = [System.BitConverter]::ToUInt32($hash, 0)
    return $PortMin + ($num % ($PortMax - $PortMin + 1))
}

function Get-WorktreeDirName([string]$branch) {
    return $branch -replace '[/\\]', '-'
}

function Resolve-WorktreePath([string]$branch) {
    return @{
        Path = Join-Path $WorktreeBase (Get-WorktreeDirName $branch)
        Port = Get-BranchPort $branch
    }
}

# Returns list of worktree info hashtables for phase worktrees only
function Get-PhaseWorktrees {
    $raw = git worktree list --porcelain
    $worktrees = @()
    $current = $null
    foreach ($line in $raw) {
        if ($line -match '^worktree (.+)') {
            if ($null -ne $current) { $worktrees += $current }
            $current = @{ Path = $matches[1].Trim(); Branch = ''; Head = '' }
        } elseif ($line -match '^branch refs/heads/(.+)') {
            $current.Branch = $matches[1].Trim()
        } elseif ($line -match '^HEAD ([0-9a-f]+)') {
            $current.Head = $matches[1].Substring(0, 7)
        }
    }
    if ($null -ne $current) { $worktrees += $current }

    $base = $WorktreeBase.Replace('\', '/').TrimEnd('/')
    return @($worktrees | Where-Object {
        $p = $_.Path.Replace('\', '/').TrimEnd('/')
        $p -like "$base*"
    })
}

# Extracts a value from a .env-style file
function Get-EnvValue([string]$file, [string]$key) {
    if (-not (Test-Path $file)) { return '' }
    $line = Get-Content $file | Where-Object { $_ -match "^$key=" } | Select-Object -First 1
    if ($line) { return ($line -split '=', 2)[1].Trim() }
    return ''
}

# Reads status info for one worktree
function Get-WtStatus($wt) {
    $wt = [hashtable]$wt
    $statusLines = @(git -C $wt.Path status --porcelain 2>$null)
    $changed     = @($statusLines | Where-Object { $_ -match '^[ MDARCU][MDARCU]|^[MDARCU] ' }).Count
    $untracked   = @($statusLines | Where-Object { $_ -match '^\?\?' }).Count

    $envLocal = Join-Path $wt.Path '.env.local'
    $dbUrl    = Get-EnvValue $envLocal 'NEXT_PUBLIC_SUPABASE_URL'
    if ($dbUrl -match 'https://([^.]+)\.') { $dbName = $matches[1] } else { $dbName = 'shared' }

    $port = if ($wt.Branch) { Get-BranchPort $wt.Branch } else { '?' }

    $dirName = Split-Path $wt.Path -Leaf

    return @{
        DirName   = $dirName
        Branch    = $wt.Branch
        Head      = $wt.Head
        Port      = $port
        DbName    = $dbName
        Changed   = $changed
        Untracked = $untracked
        Path      = $wt.Path
    }
}

function Get-StatusLabel([hashtable]$s) {
    if ($s.Changed -eq 0 -and $s.Untracked -eq 0) { return 'clean' }
    $parts = @()
    if ($s.Changed -gt 0)   { $parts += "$($s.Changed) modified" }
    if ($s.Untracked -gt 0) { $parts += "$($s.Untracked) untracked" }
    return $parts -join ', '
}

function Get-StatusColor([hashtable]$s) {
    if ($s.Changed -gt 0)   { return 'Yellow' }
    if ($s.Untracked -gt 0) { return 'DarkYellow' }
    return 'Green'
}

# ---------------------------------------------------------------------------
# dashboard
# ---------------------------------------------------------------------------
function Show-Dashboard {
    $repoName = Split-Path $RepoRoot -Leaf

    # Column widths
    $cDir    = 12
    $cBranch = 26
    $cPort   = 6
    $cDb     = 10
    $cStatus = 14
    $totalW  = 2 + $cDir + 2 + $cBranch + 2 + $cPort + 2 + $cDb + 2 + $cStatus

    function Write-Row([string]$dir, [string]$branch, [string]$port, [string]$db, [string]$status,
                       [string]$statusColor, [bool]$selected) {
        $dirD    = if ($dir.Length    -gt $cDir)    { $dir.Substring(0,$cDir-3)    + "..." } else { $dir.PadRight($cDir) }
        $branchD = if ($branch.Length -gt $cBranch) { $branch.Substring(0,$cBranch-3) + "..." } else { $branch.PadRight($cBranch) }
        $portD   = $port.PadRight($cPort)
        $dbD     = if ($db.Length     -gt $cDb)     { $db.Substring(0,$cDb-3)     + "..." } else { $db.PadRight($cDb) }
        $prefix  = if ($selected) { "> " } else { "  " }

        if ($selected) {
            Write-Host ($prefix + $dirD + "  " + $branchD + "  " + $portD + "  " + $dbD + "  ") -NoNewline -BackgroundColor DarkCyan -ForegroundColor White
            Write-Host $status.PadRight($cStatus) -BackgroundColor DarkCyan -ForegroundColor $statusColor
        } else {
            Write-Host ($prefix + $dirD + "  " + $branchD + "  " + $portD + "  " + $dbD + "  ") -NoNewline
            Write-Host $status -ForegroundColor $statusColor
        }
    }

    function Write-Files([hashtable]$s) {
        Write-Host ""
        Write-Host "  $($s.DirName)  $($s.Branch)" -ForegroundColor DarkGray
        $lines = @(git -C $s.Path status --porcelain 2>$null)
        if ($lines.Count -eq 0) {
            Write-Host "  (clean)" -ForegroundColor DarkGray
        } else {
            foreach ($l in $lines | Select-Object -First 15) {
                $code  = $l.Substring(0,2).Trim()
                $file  = $l.Substring(3)
                $color = switch -Regex ($code) {
                    '^M'  { 'Yellow' }
                    '^A'  { 'Green' }
                    '^D'  { 'Red' }
                    '^\?' { 'DarkGray' }
                    default { 'White' }
                }
                Write-Host "  $code  $file" -ForegroundColor $color
            }
            if ($lines.Count -gt 15) {
                Write-Host "  ... and $($lines.Count - 15) more" -ForegroundColor DarkGray
            }
        }
    }

    # Main loop
    $selected = 0

    while ($true) {
        $wts = @(Get-PhaseWorktrees)

        if ($wts.Count -eq 0) {
            Clear-Host
            Write-Host ""
            Write-Host "  $repoName worktrees" -ForegroundColor White
            Write-Host "  No active worktrees. Run: worktree start <branch>" -ForegroundColor DarkGray
            Write-Host ""
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Escape') { break }
            continue
        }

        if ($selected -ge $wts.Count) { $selected = $wts.Count - 1 }
        $statuses = @($wts | ForEach-Object { Get-WtStatus ([hashtable]$_) })

        [Console]::CursorVisible = $false
        Clear-Host
        Write-Host ""
        Write-Host "  $repoName worktrees" -ForegroundColor White
        Write-Host ("  " + ("-" * ($totalW - 2))) -ForegroundColor DarkGray
        Write-Host ("  " + "Name".PadRight($cDir) + "  " + "Branch".PadRight($cBranch) + "  " + "Port".PadRight($cPort) + "  " + "DB".PadRight($cDb) + "  " + "Status") -ForegroundColor DarkGray
        Write-Host ("  " + ("-" * ($totalW - 2))) -ForegroundColor DarkGray

        for ($i = 0; $i -lt $statuses.Count; $i++) {
            $s = $statuses[$i]
            Write-Row $s.DirName $s.Branch "$($s.Port)" $s.DbName (Get-StatusLabel $s) (Get-StatusColor $s) ($i -eq $selected)
        }

        Write-Host ("  " + ("-" * ($totalW - 2))) -ForegroundColor DarkGray
        Write-Host "  [enter] cd into worktree   [c] cd + claude   [d] remove   [esc] exit" -ForegroundColor DarkGray

        Write-Files $statuses[$selected]

        $key = [Console]::ReadKey($true)

        switch ($key.Key) {
            'UpArrow'   { if ($selected -gt 0) { $selected-- } }
            'DownArrow' { if ($selected -lt $statuses.Count - 1) { $selected++ } }
            'Escape'    { [Console]::CursorVisible = $true; Clear-Host; return }
            'Enter' {
                $b  = $statuses[$selected].Branch
                $wt = $statuses[$selected].Path
                [Console]::CursorVisible = $true
                Clear-Host
                # Enter: cd into worktree in current terminal
                Set-Location $wt
                Write-Host "  -> $wt" -ForegroundColor DarkGray
                return
            }
        }

        switch ($key.KeyChar) {
            'c' {
                [Console]::CursorVisible = $true
                Clear-Host
                $b  = $statuses[$selected].Branch
                $wt = $statuses[$selected].Path
                if ($b) { Start-Worktree $b } else {
                    Set-Location $wt
                    claude
                }
                return
            }
            'd' {
                [Console]::CursorVisible = $true
                Clear-Host
                $b = $statuses[$selected].Branch
                if ($b) { Remove-Worktree $b } else { Write-Host "No branch for selected worktree." -ForegroundColor Red }
                return
            }
        }
    }

    [Console]::CursorVisible = $true
    Clear-Host
}

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------
function Start-Worktree([string]$branch) {
    $info = Resolve-WorktreePath $branch
    $wt   = $info.Path
    $port = $info.Port

    Write-Host ""
    Write-Host "  Branch : $branch" -ForegroundColor Cyan
    Write-Host "  Path   : $wt"     -ForegroundColor Cyan
    Write-Host "  Port   : $port"   -ForegroundColor Cyan
    Write-Host ""

    # 1. Create (or reuse) git worktree
    if (Test-Path $wt) {
        Write-Host "[skip] Worktree already exists at $wt" -ForegroundColor Yellow
    } else {
        $branchExists = git branch --list $branch
        if (-not $branchExists) {
            $remoteBranch = "origin/$branch"
            $remoteExists = git branch -r --list $remoteBranch
            if ($remoteExists) {
                Write-Host "[git] Checking out remote branch $remoteBranch"
                git worktree add $wt $branch 2>$null
                if ($LASTEXITCODE -ne 0) {
                    git worktree add --track -b $branch $wt $remoteBranch
                }
            } else {
                Write-Host "[git] Creating new branch $branch from HEAD"
                git worktree add -b $branch $wt HEAD
            }
        } else {
            $addOut = & { $ErrorActionPreference = 'Continue'; git worktree add $wt $branch 2>&1 }
            if ($LASTEXITCODE -ne 0) {
                # Branch may already be checked out in a differently-named worktree (e.g. old hash path)
                $addStr = "$addOut"
                $m = [regex]::Match($addStr, "already used by worktree at '([^']+)'")
                if ($m.Success) {
                    $existingWt = $m.Groups[1].Value.Replace('/', '\')
                    Write-Host "[remap] Branch already checked out at $existingWt" -ForegroundColor Yellow
                    $wt = $existingWt
                } else {
                    throw "git worktree add failed: $addStr"
                }
            }
        }
        if (Test-Path $wt) {
            Write-Host "[git] Worktree ready" -ForegroundColor Green
        } else {
            throw "git worktree add failed"
        }
    }

    # 2. Junction-link node_modules (no elevated rights needed on Windows)
    $nmSource = Join-Path $RepoRoot 'node_modules'
    $nmTarget = Join-Path $wt 'node_modules'
    if (-not (Test-Path $nmTarget)) {
        if (-not (Test-Path $nmSource)) {
            Write-Host "[warn] node_modules not found at $nmSource - run 'npm install' in repo root first" -ForegroundColor Yellow
        } else {
            New-Item -ItemType Junction -Path $nmTarget -Target $nmSource | Out-Null
            Write-Host "[link] node_modules junction created" -ForegroundColor Green
        }
    } else {
        Write-Host "[skip] node_modules already linked" -ForegroundColor Yellow
    }

    # 3. Copy .env.local
    $envTarget = Join-Path $wt '.env.local'
    if (Test-Path $EnvSource) {
        Copy-Item $EnvSource $envTarget -Force
        Write-Host "[env]  .env.local copied from $EnvSource" -ForegroundColor Green
    } else {
        Write-Host "[warn] $EnvSource not found - worktree will have no .env.local" -ForegroundColor Yellow
    }

    # 4. Write a launch helper script the user (and Claude Code) can just dot-source or run
    $launchScript = Join-Path $wt 'dev.ps1'
    @"
# Generated by worktree start — run this to launch the dev server on the correct port
`$env:PORT = '$port'
npm run dev
"@ | Set-Content $launchScript -Encoding UTF8
    Write-Host "[env]  dev.ps1 written (sets PORT=$port then runs npm run dev)" -ForegroundColor Green

    # 5. Launch Claude Code in the worktree
    Write-Host ""
    Write-Host "Launching Claude Code in worktree..." -ForegroundColor Cyan
    Write-Host "(dev server: run .\dev.ps1  -- or:  `$env:PORT='$port'; npm run dev)"
    Write-Host ""
    Set-Location $wt
    claude

    Write-Host ""
    Write-Host "Claude Code exited." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "If '$branch' is verified and ready to merge:" -ForegroundColor Yellow
    Write-Host "  1. Merge to main (GitHub PR or: git checkout main && git merge $branch)"
    Write-Host "  2. Then clean up:  worktree done $branch"
    Write-Host ""
}

# ---------------------------------------------------------------------------
# done
# ---------------------------------------------------------------------------
function Remove-Worktree([string]$branch) {
    $info = Resolve-WorktreePath $branch
    $wt   = $info.Path

    if (-not (Test-Path $wt)) {
        Write-Host "[skip] Worktree path not found: $wt" -ForegroundColor Yellow
    } else {
        $nmTarget = Join-Path $wt 'node_modules'
        if (Test-Path $nmTarget) {
            # cmd /c rmdir removes the junction only, no prompts, no recursion into target
            cmd /c rmdir "$nmTarget" | Out-Null
            Write-Host "[unlink] node_modules junction removed" -ForegroundColor Green
        }

        git worktree remove --force $wt 2>$null
        if ($LASTEXITCODE -ne 0) {
            # .git file may be missing (e.g. prior failed removal) - force-delete and prune
            Write-Host "[warn] git worktree remove failed, force-deleting directory" -ForegroundColor Yellow
            Remove-Item $wt -Recurse -Force
        }
        Write-Host "[git] Worktree removed" -ForegroundColor Green
    }

    git worktree prune
    Write-Host "[git] Worktree list pruned" -ForegroundColor Green

    Write-Host ""
    Write-Host "Done. Worktree for '$branch' has been cleaned up." -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
switch ($Command) {
    ''      { Show-Dashboard }
    'start' {
        if (-not $Branch) { Write-Host "Usage: worktree start <branch>" -ForegroundColor Red; exit 1 }
        Start-Worktree $Branch
    }
    'done'  {
        if (-not $Branch) { Write-Host "Usage: worktree done <branch>" -ForegroundColor Red; exit 1 }
        Remove-Worktree $Branch
    }
    default {
        Write-Host "Unknown command '$Command'. Use: worktree | worktree start <branch> | worktree done <branch>" -ForegroundColor Red
        exit 1
    }
}
