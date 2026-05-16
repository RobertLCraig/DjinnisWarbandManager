param(
    [string]$OutputDir   = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) "releases"),
    # release (default), beta, or alpha -- controls git tag suffix so CurseForge sets the right file type
    # Release: v1.2.3        -> CurseForge "Release"
    # Beta:    v1.2.3-beta   -> CurseForge "Beta"
    # Alpha:   v1.2.3-alpha  -> CurseForge "Alpha"
    [ValidateSet("release","beta","alpha")]
    [string]$ReleaseType = "release",
    [switch]$DryRun,
    [switch]$SkipTag,
    [switch]$SkipPush
)

$ErrorActionPreference = "Stop"
$Root             = Split-Path -Parent $MyInvocation.MyCommand.Definition
$AddonName        = "DjinnisWarbandManager"
$TocFile          = Join-Path $Root "$AddonName.toc"
$ReleaseNotesFile = Join-Path $Root "RELEASE_NOTES.md"
$ChangelogFile    = Join-Path $Root "CHANGELOG.md"

# Resolve gh CLI -- check PATH first, then common install locations
$_ghCmd = Get-Command "gh" -ErrorAction SilentlyContinue
$GhExe  = if ($_ghCmd) { $_ghCmd.Source } else { $null }
if (-not $GhExe) {
    $candidates = @(
        "C:\Program Files\GitHub CLI\gh.exe",
        "$env:LOCALAPPDATA\Programs\GitHub CLI\gh.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { $GhExe = $c; break } }
}

function Write-Info    { param($m) Write-Host $m -ForegroundColor Cyan    }
function Write-Success { param($m) Write-Host $m -ForegroundColor Green   }
function Write-Warn    { param($m) Write-Host $m -ForegroundColor Yellow  }
function Write-Err     { param($m) Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

function Make-Tag {
    param([string]$ver, [string]$type)
    if ($type -eq "release") { return "v$ver" }
    return "v$ver-$type"
}

# ---------------------------------------------------------------------------
# 1. Read version from RELEASE_NOTES.md
# ---------------------------------------------------------------------------

if (-not (Test-Path $ReleaseNotesFile)) {
    Write-Err "RELEASE_NOTES.md not found. Create it with a '## Version: x.y.z' line."
}

$rnContent    = Get-Content $ReleaseNotesFile -Raw -Encoding UTF8
$versionMatch = [regex]::Match($rnContent, '##\s+Version:\s*(\S+)')
if (-not $versionMatch.Success) {
    Write-Err "No '## Version: x.y.z' line found in RELEASE_NOTES.md."
}
$Version = $versionMatch.Groups[1].Value.TrimStart('v')
$Tag     = Make-Tag $Version $ReleaseType

Write-Info ""
Write-Info "=== DjinnisWarbandManager Release: $Tag ($ReleaseType) ==="
if ($DryRun) { Write-Warn "  DRY RUN - no files will be written, committed, tagged, or pushed" }
Write-Info ""

# ---------------------------------------------------------------------------
# 2. Sync TOC version (auto-update if it doesn't match)
# ---------------------------------------------------------------------------

$tocContent      = Get-Content $TocFile -Raw -Encoding UTF8
$tocVersionMatch = [regex]::Match($tocContent, '##\s+Version:\s*(\S+)')
if (-not $tocVersionMatch.Success) { Write-Err "No '## Version:' in $AddonName.toc." }
$tocVersion = $tocVersionMatch.Groups[1].Value.TrimStart('v')

if ($tocVersion -ne $Version) {
    Write-Warn "  TOC version ($tocVersion) differs from RELEASE_NOTES.md ($Version) - auto-updating .toc"
    $tocContent = $tocContent -replace '(##\s+Version:\s*)\S+', "`${1}$Version"
    if (-not $DryRun) {
        [System.IO.File]::WriteAllText($TocFile, $tocContent, (New-Object System.Text.UTF8Encoding $false))
        Write-Success "  Updated $AddonName.toc to $Version"
    }
} else {
    Write-Info "  TOC version: $tocVersion  OK"
}

# ---------------------------------------------------------------------------
# 3. Check git state (RELEASE_NOTES.md and .toc are managed by this script)
# ---------------------------------------------------------------------------

$gitStatus  = & git -C $Root status --porcelain 2>&1
$rnFileName  = [System.IO.Path]::GetFileName($ReleaseNotesFile)
$tocFileName = [System.IO.Path]::GetFileName($TocFile)
$dirtyFiles = $gitStatus | Where-Object {
    $_ -match '^\s*[MADRCU?]' -and
    $_ -notmatch '\.claude' -and
    $_ -notmatch ([regex]::Escape($rnFileName)) -and
    $_ -notmatch ([regex]::Escape($tocFileName))
}

if ($dirtyFiles) {
    Write-Warn "  Uncommitted changes detected:"
    $dirtyFiles | ForEach-Object { Write-Warn "    $_" }
    if (-not $DryRun) {
        Write-Err "Commit or stash non-release changes before releasing. Use -DryRun to preview without this check."
    }
}

$tagExists = & git -C $Root tag -l $Tag 2>&1
if ($tagExists -contains $Tag) {
    Write-Warn "  Tag '$Tag' already exists - auto-bumping patch version..."

    # Parse numeric version and increment patch until a free tag is found
    # Strip any pre-release suffix (e.g. "0-beta" -> "0") before casting to int
    $parts = $Version.Split('.')
    $major = [int]$parts[0]
    $minor = [int]$parts[1]
    $patch = [int]($parts[2] -replace '[^0-9].*', '')

    do {
        $patch++
        $Version  = "$major.$minor.$patch"
        $Tag      = Make-Tag $Version $ReleaseType
        $tagCheck = & git -C $Root tag -l $Tag 2>&1
    } while ($tagCheck -contains $Tag)

    Write-Success "  Bumped to: $Tag"

    # Update RELEASE_NOTES.md (numeric version only, no suffix)
    $rnContent = $rnContent -replace '(##\s+Version:\s*)\S+', "`${1}$Version"
    [System.IO.File]::WriteAllText($ReleaseNotesFile, $rnContent, (New-Object System.Text.UTF8Encoding $false))
    Write-Success "  Updated RELEASE_NOTES.md"

    # Update .toc
    $tocContent = $tocContent -replace '(##\s+Version:\s*)\S+', "`${1}$Version"
    [System.IO.File]::WriteAllText($TocFile, $tocContent, (New-Object System.Text.UTF8Encoding $false))
    Write-Success "  Updated $AddonName.toc"

    # Re-read for changelog extraction
    $rnContent = Get-Content $ReleaseNotesFile -Raw -Encoding UTF8
}

# ---------------------------------------------------------------------------
# 4. Extract release notes body
# ---------------------------------------------------------------------------

# Strip comment blocks, top-level heading, and Version header line
$notesBody = $rnContent -replace '(?s)<!--.*?-->\s*', ''
$notesBody = $notesBody -replace '(?m)^#\s+Release Notes\s*(\r?\n)?', ''
$notesBody = $notesBody -replace '(?m)^##\s+Version:.*(\r?\n)?', ''
$notesBody = $notesBody.Trim()

# ---------------------------------------------------------------------------
# 5. Prepend entry to CHANGELOG.md
# ---------------------------------------------------------------------------

$today          = (Get-Date).ToString("yyyy-MM-dd")
# Beta/alpha: embed suffix in the version bracket (e.g. [0.3.1-beta]) to match the git tag
$versionLabel   = if ($ReleaseType -ne "release") { "$Version-$ReleaseType" } else { $Version }
$changelogEntry = "## [$versionLabel] - $today`r`n`r`n$notesBody`r`n"

if (-not $DryRun) {
    $existing = ""
    if (Test-Path $ChangelogFile) { $existing = Get-Content $ChangelogFile -Raw -Encoding UTF8 }

    # Skip prepend if this version is already the top entry (prevents duplicates on re-run)
    if ($existing -match "(?m)^##\s+\[$([regex]::Escape($versionLabel))\]") {
        Write-Warn "  CHANGELOG.md already contains [$versionLabel] -- skipping prepend"
    } else {
        # Detect the file's line-ending style so the separator search always matches
        $nl        = if ($existing -match "`r`n") { "`r`n" } else { "`n" }
        $separator = "${nl}---${nl}"
        $sepIndex  = $existing.IndexOf($separator)

        if ($sepIndex -ge 0) {
            $before       = $existing.Substring(0, $sepIndex + $separator.Length)
            $after        = $existing.Substring($sepIndex + $separator.Length)
            $newChangelog = $before + $nl + $changelogEntry + $nl + $after
        } else {
            $newChangelog = $existing + "${nl}---${nl}${nl}" + $changelogEntry
        }

        [System.IO.File]::WriteAllText($ChangelogFile, $newChangelog, (New-Object System.Text.UTF8Encoding $false))
        Write-Success "  CHANGELOG.md updated"
    }
} else {
    Write-Warn "  [DryRun] Would prepend to CHANGELOG.md:"
    Write-Host $changelogEntry -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 6. Build the local zip (for local testing; CurseForge builds its own from git)
# ---------------------------------------------------------------------------

$ExcludeNames = @(
    ".git"
    ".github"
    ".gitignore"
    ".claude"
    "CLAUDE.md"
    "CHANGELOG.md"
    "LICENSE"
    "README.md"
    "deploy.ps1"
    "release.ps1"
    "RELEASE_NOTES.md"
    "pkgmeta.yaml"
    "DESIGN.md"
    "releases"
)

$ZipName = "DjinnisWarbandManager-$Tag.zip"
$ZipPath = Join-Path $OutputDir $ZipName

if (-not $DryRun) {
    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }
    if (Test-Path $ZipPath)         { Remove-Item $ZipPath -Force }
}

Write-Info "  Building zip: $ZipPath"

$allItems   = Get-ChildItem -Path $Root -Recurse
$filesToZip = $allItems | Where-Object {
    if ($_.PSIsContainer) { return $false }
    $rel = $_.FullName.Substring($Root.Length).TrimStart('\','/')
    foreach ($ex in $ExcludeNames) {
        $pattern = "^" + [regex]::Escape($ex) + "(/|\\|$)"
        if ($rel -eq $ex -or $rel -match $pattern) { return $false }
    }
    return $true
}

if ($DryRun) {
    $count = @($filesToZip).Count
    Write-Warn "  [DryRun] Would include $count files in zip:"
    $filesToZip | ForEach-Object {
        $rel = $_.FullName.Substring($Root.Length).TrimStart('\','/')
        Write-Host "    $AddonName/$rel" -ForegroundColor DarkGray
    }
} else {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($ZipPath, 'Create')
    try {
        foreach ($file in $filesToZip) {
            $rel       = $file.FullName.Substring($Root.Length).TrimStart('\','/')
            $entryName = ("$AddonName/" + $rel) -replace '\\', '/'
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $file.FullName, $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    } finally {
        $zip.Dispose()
    }
    $sizeKB = [math]::Round((Get-Item $ZipPath).Length / 1KB, 1)
    $count  = @($filesToZip).Count
    Write-Success "  Zip created: $ZipName ($sizeKB KB, $count files)"
}

# ---------------------------------------------------------------------------
# 7. Commit, tag, and push
# ---------------------------------------------------------------------------

if (-not $DryRun) {
    & git -C $Root add CHANGELOG.md RELEASE_NOTES.md "$TocFile" | Out-Null
    $commitMsg = "Release $Tag"
    & git -C $Root commit -m $commitMsg | Out-Null
    Write-Success "  Committed: $commitMsg"

    if (-not $SkipTag) {
        & git -C $Root tag -a $Tag -m $commitMsg
        Write-Success "  Tagged:    $Tag"
    }

    if (-not $SkipPush) {
        Write-Info "  Pushing to origin..."
        & git -C $Root push origin HEAD
        Write-Success "  Pushed commits"
        if (-not $SkipTag) {
            & git -C $Root push origin $Tag
            Write-Success "  Pushed tag $Tag -> CurseForge webhook will trigger packaging as [$ReleaseType]"
        }
    } else {
        Write-Warn "  SkipPush set - run manually: git push origin HEAD && git push origin $Tag"
    }
} else {
    Write-Warn "  [DryRun] Would commit, tag '$Tag', push commits, and push tag to trigger CurseForge"
}

# ---------------------------------------------------------------------------
# 8. Create GitHub Release with zip attached (requires gh CLI)
# ---------------------------------------------------------------------------

$ghAvailable = $null -ne $GhExe

if (-not $ghAvailable) {
    Write-Warn ""
    Write-Warn "  GitHub CLI (gh) not found -- skipping GitHub Release creation."
    Write-Warn "  Install from https://cli.github.com then run 'gh auth login'."
    Write-Warn "  To create the release manually:"
    Write-Warn "    gh release create $Tag '$ZipPath' --title '$Tag' --notes-file '$ReleaseNotesFile'"
} elseif ($SkipPush -or $SkipTag) {
    Write-Warn "  Skipping GitHub Release (SkipPush or SkipTag is set)"
} elseif ($DryRun) {
    Write-Warn "  [DryRun] Would create GitHub Release '$Tag' with $(Split-Path $ZipPath -Leaf) attached"
} else {
    Write-Info "  Creating GitHub Release $Tag..."

    $isPrerelease = ($ReleaseType -ne "release")

    # Write release notes to a temp file so special characters survive
    $tmpNotes = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmpNotes, $notesBody, (New-Object System.Text.UTF8Encoding $false))

    # Attach zip with a versioned display label (shown as download filename on the release page)
    $ZipLabel  = "DjinnisWarbandManager-$Tag.zip"
    $ZipAsset  = "${ZipPath}#${ZipLabel}"

    $ghArgs = @(
        "release", "create", $Tag,
        $ZipAsset,
        "--title", $Tag,
        "--notes-file", $tmpNotes
    )
    if ($isPrerelease) {
        $ghArgs += "--prerelease"
        $ghArgs += "--latest=false"
    }

    & $GhExe @ghArgs
    Remove-Item $tmpNotes -Force

    if ($LASTEXITCODE -eq 0) {
        Write-Success "  GitHub Release created: https://github.com/RobertLCraig/DjinnisWarbandManager/releases/tag/$Tag"
    } else {
        Write-Warn "  gh release create failed (exit $LASTEXITCODE) -- create it manually:"
        Write-Warn "    & '$GhExe' release create $Tag '$ZipPath' --title '$Tag' --notes-file RELEASE_NOTES.md"
    }
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Info ""
Write-Success "=== Release $Tag complete! ==="
Write-Info ""
Write-Info "  Local zip:  $ZipPath"
if (-not $DryRun -and -not $SkipPush -and -not $SkipTag) {
    Write-Info "  GitHub:     https://github.com/RobertLCraig/DjinnisWarbandManager/releases/tag/$Tag"
    Write-Info "  CurseForge: packaging triggered by pushed tag (file type: $ReleaseType)"
}
Write-Info ""
Write-Info "Next steps:"
Write-Info "  1. Verify the zip locally: extract and load in WoW"
Write-Info "  2. Clear RELEASE_NOTES.md and set the next version placeholder"
Write-Info ""
