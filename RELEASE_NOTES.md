<!--
  This file drives release.ps1:
  - The Version line below is the single source of truth for the version
    (release.ps1 syncs the .toc to match and tags the git release).
  - Everything below the Version line becomes the GitHub release body and the
    new CHANGELOG.md entry. Replace it each release; keep it user-facing.
  - NOTE: do not write the literal version-header pattern inside this comment;
    release.ps1 strips comments before reading the version, but keep it clean.
-->

# Release Notes

## Version: 0.3.2

Phase 4 - polish (in progress).

- Transaction log: every gold/item move is recorded (account-wide, capped).
  View with `/dwm log` or the Transaction Log panel; clear from options.
- Optional "Sort warband bank after item moves" - runs Blizzard's warband
  sort so split-created small stacks get consolidated (off by default).
