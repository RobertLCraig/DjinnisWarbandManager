<#
.SYNOPSIS
  Build the AH plan (DWM card 0001): read your saved data, decide which AH character should hold
  each auction item, and write Data\AHPlan.lua plus a readable report.

.DESCRIPTION
  Reads, never writes, the game folder:
    - Syndicator.lua and TradeSkillMaster.lua from your SavedVariables
    - TSM's AppData.lua (AuctionDB, kept fresh by the TSM desktop app)
  Downloads undermine.exchange's free live-listing file for each of the four auction houses into
  a new temporary folder.

  Writes:
    - Data\AHPlan.lua in this addon's source folder. Deploy it, then /reload in game.
    - The report folder: CSV files a person can open in Excel.

  Log out of the game (or /reload) first, so the SavedVariables on disk are current.

.EXAMPLE
  .\tools\ahplan\build.ps1
  C:\Dev\WoWAddons\bin\deploy.ps1 -WhatIf -Only DjinnisWarbandManager
  C:\Dev\WoWAddons\bin\deploy.ps1 -Only DjinnisWarbandManager
#>
param(
    [string]$SavedVariables = 'C:\Games\World of Warcraft\_retail_\WTF\Account\DJINNWRAITH\SavedVariables',
    [string]$AppData = 'C:\Games\World of Warcraft\_retail_\Interface\AddOns\TradeSkillMaster_AppHelper\AppData.lua',
    [string]$Report = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) ("WoW AH Rebalance " + (Get-Date -Format 'yyyy-MM-dd')))
)
$ErrorActionPreference = 'Stop'

$here  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$addon = Resolve-Path (Join-Path $here '..\..')
$plan  = Join-Path $addon 'Data\AHPlan.lua'

foreach ($tool in 'lua', 'python') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is not on PATH." }
}
foreach ($f in (Join-Path $SavedVariables 'Syndicator.lua'), (Join-Path $SavedVariables 'TradeSkillMaster.lua'), $AppData) {
    if (-not (Test-Path $f)) { throw "Missing input: $f" }
}

# Downloads and intermediate files go in a new, empty folder; the scripts stay where they are.
$work = Join-Path ([IO.Path]::GetTempPath()) ("ahplan-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
Write-Host "Work folder: $work"

# The Lua scripts write their own files: a PowerShell pipe re-encodes text and would mangle
# UTF-8 realm names such as "Aggra(Português)", which are the plan's character keys.
Write-Host 'Reading Syndicator...'
& lua (Join-Path $here 'dump.lua') (Join-Path $SavedVariables 'Syndicator.lua') (Join-Path $work 'items.tsv')
if ($LASTEXITCODE -ne 0) { throw 'dump.lua failed.' }
Write-Host 'Reading TSM sales history...'
& lua (Join-Path $here 'tsmacct.lua') (Join-Path $SavedVariables 'TradeSkillMaster.lua') (Join-Path $work 'acct.tsv') 2>$null
if ($LASTEXITCODE -ne 0) { throw 'tsmacct.lua failed.' }

# Connected-realm IDs on undermine.exchange: Aggra, Shadowsong, Moonglade, Ghostlands.
Write-Host 'Downloading undermine.exchange listings...'
foreach ($id in 1303, 3666, 1085, 1596) {
    Invoke-WebRequest -Uri "https://undermine.exchange/data/$id/state.free.bin" -OutFile (Join-Path $work "r$id.bin") -UseBasicParsing
}

Write-Host 'Building the plan...'
& python -I (Join-Path $here 'analyze.py') --appdata $AppData --work $work --report $Report --plan $plan
if ($LASTEXITCODE -ne 0) { throw "analyze.py failed (exit $LASTEXITCODE). Work folder kept: $work" }

Remove-Item -Recurse -Force $work
Write-Host ''
Write-Host "Plan:   $plan"
Write-Host "Report: $Report"
Write-Host 'Next:   C:\Dev\WoWAddons\bin\deploy.ps1 -WhatIf -Only DjinnisWarbandManager, then without -WhatIf, then /reload.'
