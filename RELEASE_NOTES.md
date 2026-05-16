<!--
  This file drives release.ps1:
  - The "## Version:" line below is the single source of truth for the version
    (release.ps1 syncs the .toc to match and tags the git release).
  - Everything below the Version line becomes the GitHub release body and the
    new CHANGELOG.md entry. Replace it each release; keep it user-facing.
-->

# Release Notes

## Version: 0.2.0

Phase 2 - character purposes, roster, and profession auto-detection.

- Gold targets now come from a character **purpose** (Default, Raider, Mythic,
  Crafter, Gatherer, Leveling, Mule) instead of a single shared number.
  Purposes are fully editable and you can add your own.
- **Mule** purpose: pulls all gold out of the warband bank onto that
  character and never deposits.
- Per-character **gold override** still wins over the purpose; resolution is
  override -> purpose -> default purpose.
- **Profession auto-detection**: new characters are suggested Crafter or
  Gatherer from their professions (suggestion only - never overrides a purpose
  you picked yourself; only primary professions count).
- **Roster** panel/command to view and manage every character on the account,
  including excluding bank alts entirely ("Manage this character" off).
- Phase 1 per-character settings are migrated automatically.
- Everything remains reachable from both the options panel and the `/dwm`
  command tree.
