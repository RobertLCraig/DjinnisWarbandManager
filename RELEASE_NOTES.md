<!--
  This file drives release.ps1:
  - The "## Version:" line below is the single source of truth for the version
    (release.ps1 syncs the .toc to match and tags the git release).
  - Everything below the Version line becomes the GitHub release body and the
    new CHANGELOG.md entry. Replace it each release; keep it user-facing.
-->

# Release Notes

## Version: 0.1.0

Phase 1 - gold balancing foundation.

- Automatically balances character gold toward a per-character target when you
  visit the Warband banker (deposit excess / withdraw shortfall / maintain).
- Deposit-only, withdraw-only, or both (maintain) modes.
- Per-character override or shared profile default.
- Simulate (dry-run) mode reports what would happen without moving any gold.
- Session pause, minimap/broker button, and full control from the options
  panel or the `/dwm` command tree.
