param(
    [string]$AddonName = "DjinnisWarbandManager",
    [string]$Source = (Split-Path -Parent $MyInvocation.MyCommand.Definition),
    [string]$Destination = "C:/Games/World of Warcraft/_retail_/Interface/AddOns",
    [switch]$DryRun
)

$DestPath = Join-Path $Destination $AddonName

# Exclusions come from pkgmeta.yaml's `ignore:` block, which is the single source of
# truth shared with release.ps1 and the CurseForge packager. This script used to keep
# its own copy; the copies drifted, and files that ship to users stopped matching the
# files that reach the game folder. Edit pkgmeta.yaml, not this.
function Get-PkgmetaIgnore {
    param([string]$PkgmetaPath)

    if (-not (Test-Path $PkgmetaPath)) {
        throw "pkgmeta.yaml not found at '$PkgmetaPath'. It owns the exclusion list, so deploying without it would copy docs, tooling and git internals into the game folder. Refusing."
    }

    $ignore  = @()
    $inBlock = $false
    foreach ($line in (Get-Content $PkgmetaPath)) {
        if ($line -match '^ignore:\s*$')      { $inBlock = $true;  continue }
        if ($inBlock -and $line -match '^\S') { $inBlock = $false }
        if ($inBlock -and $line -match '^\s+-\s+(.+?)\s*$') { $ignore += $Matches[1] }
    }

    if ($ignore.Count -eq 0) {
        throw "pkgmeta.yaml has no entries under 'ignore:'. Refusing to deploy rather than copying every file in the repo."
    }
    return $ignore
}

# A path is excluded if it equals an entry or sits underneath one. Compared with
# forward slashes so the YAML entries read the same on either side.
function Test-Excluded {
    param([string]$RelPath, [string[]]$Ignore)

    $rel = $RelPath -replace '\\', '/'
    foreach ($ex in $Ignore) {
        $e = ($ex -replace '\\', '/').TrimEnd('/')
        if ($rel -eq $e -or $rel.StartsWith("$e/", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

$Exclusions = Get-PkgmetaIgnore (Join-Path $Source "pkgmeta.yaml")

function Write-Info($msg)    { Write-Host $msg -ForegroundColor Cyan }
function Write-Success($msg) { Write-Host $msg -ForegroundColor Green }
function Write-Warn($msg)    { Write-Host $msg -ForegroundColor Yellow }

Write-Info ""
Write-Info "=== Deploying $AddonName ==="
Write-Info "Source:      $Source"
Write-Info "Destination: $DestPath"
if ($DryRun) { Write-Warn "  DRY RUN - no files will be copied or deleted" }
Write-Info ""

# Ensure destination exists
if (-not (Test-Path $DestPath)) {
    if ($DryRun) {
        Write-Warn "[DryRun] Would create directory: $DestPath"
    } else {
        New-Item -ItemType Directory -Path $DestPath | Out-Null
        Write-Info "  Created: $DestPath"
    }
}

# Collect source files (respecting exclusions)
$allFiles = Get-ChildItem -Path $Source -Recurse -File
$sourceFiles = @()
# Every relative path that belongs in the game folder. The mirror step below deletes
# by absence from this set, so excluding a file here is what removes an already-
# deployed copy of it.
$deployable = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($f in $allFiles) {
    $rel = $f.FullName.Substring($Source.Length).TrimStart('\', '/')
    if (-not (Test-Excluded $rel $Exclusions)) {
        $sourceFiles += $f
        [void]$deployable.Add(($rel -replace '\\', '/'))
    }
}

$newCount     = 0
$updatedCount = 0
$skippedCount = 0

foreach ($file in $sourceFiles) {
    $rel      = $file.FullName.Substring($Source.Length).TrimStart('\', '/')
    $destFile = Join-Path $DestPath $rel

    if (-not (Test-Path $destFile)) {
        if (-not $DryRun) {
            $destDir = Split-Path $destFile -Parent
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            Copy-Item $file.FullName $destFile -Force
        }
        Write-Host "  + $rel" -ForegroundColor Green
        $newCount++
    } else {
        $srcHash  = (Get-FileHash $file.FullName -Algorithm MD5).Hash
        $destHash = (Get-FileHash $destFile -Algorithm MD5).Hash
        if ($srcHash -ne $destHash) {
            if (-not $DryRun) {
                Copy-Item $file.FullName $destFile -Force
            }
            Write-Host "  ~ $rel" -ForegroundColor Yellow
            $updatedCount++
        } else {
            $skippedCount++
        }
    }
}

# Remove destination files that are not in the deployable set (mirror behavior).
# Tested against the set rather than against the source tree: a newly excluded file
# still exists in source, so an existence check would leave every copy already in the
# game folder behind for good. This is scoped to this addon's own directory and never
# touches the AddOns root.
$removedCount = 0
if (Test-Path $DestPath) {
    $destFiles = Get-ChildItem -Path $DestPath -Recurse -File
    foreach ($df in $destFiles) {
        $rel = $df.FullName.Substring($DestPath.Length).TrimStart('\', '/')
        if (-not $deployable.Contains(($rel -replace '\\', '/'))) {
            if (-not $DryRun) {
                Remove-Item $df.FullName -Force
            }
            Write-Host "  - $rel" -ForegroundColor Red
            $removedCount++
        }
    }

    # Clean up empty directories
    if (-not $DryRun) {
        Get-ChildItem -Path $DestPath -Recurse -Directory |
            Sort-Object { $_.FullName.Length } -Descending |
            Where-Object { @(Get-ChildItem $_.FullName -Force).Count -eq 0 } |
            ForEach-Object { Remove-Item $_.FullName -Force }
    }
}

Write-Info ""
Write-Success "=== Deploy complete! ==="
Write-Info "  New:       $newCount"
Write-Info "  Updated:   $updatedCount"
Write-Info "  Removed:   $removedCount"
Write-Info "  Unchanged: $skippedCount"
Write-Info ""
