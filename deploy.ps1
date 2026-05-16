param(
    [string]$AddonName = "DjinnisWarbandManager",
    [string]$Source = (Split-Path -Parent $MyInvocation.MyCommand.Definition),
    [string]$Destination = "C:/Games/World of Warcraft/_retail_/Interface/AddOns",
    [switch]$DryRun
)

$DestPath = Join-Path $Destination $AddonName

# Exclusions - files and folders that should NOT be deployed to the game client
$ExcludeFiles = @(
    ".gitignore"
    "CLAUDE.md"
    "README.md"
    "LICENSE"
    "deploy.ps1"
    "release.ps1"
    "RELEASE_NOTES.md"
    "CHANGELOG.md"
    "pkgmeta.yaml"
    "DESIGN.md"
)
$ExcludeFolders = @(
    ".git"
    ".github"
    ".claude"
    ".agents"
    "releases"
)

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
foreach ($f in $allFiles) {
    $rel = $f.FullName.Substring($Source.Length).TrimStart('\', '/')
    $skip = $false

    foreach ($ex in $ExcludeFiles) {
        if ($rel -eq $ex) { $skip = $true; break }
    }
    if (-not $skip) {
        foreach ($ex in $ExcludeFolders) {
            if ($rel -like "$ex\*" -or $rel -like "$ex/*" -or $rel -eq $ex) {
                $skip = $true; break
            }
        }
    }
    if (-not $skip) { $sourceFiles += $f }
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

# Remove files in destination that no longer exist in source (mirror behavior)
$removedCount = 0
if (Test-Path $DestPath) {
    $destFiles = Get-ChildItem -Path $DestPath -Recurse -File
    foreach ($df in $destFiles) {
        $rel     = $df.FullName.Substring($DestPath.Length).TrimStart('\', '/')
        $srcFile = Join-Path $Source $rel
        if (-not (Test-Path $srcFile)) {
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
