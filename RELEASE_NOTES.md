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

Phase 5 - account-wide item management (in progress).

- **Fixed: automatic balancing never ran on opening the bank in normal play.**
  The trigger wrongly required the `AccountBanker` interaction; a normal
  banker fires `Banker`/`CharacterBanker`, so auto-balance only happened via
  `/dwm balance`. It now keys off the bank window opening + warband being
  usable, so it just works at any banker (and with bag addons).

- New item ledger: persistent, advisory account snapshots of the warband bank
  and each managed character's on-hand counts (captured at the bank and on
  login; never gate a move).
- `/dwm ledger` reports per-item warband stock, each character's
  have -> intent, and shortages (e.g. "Enchanting Vellum SHORT 150").

Phase 4 - polish (in progress).

- Transaction log: every gold/item move is recorded (account-wide, capped).
  View with `/dwm log` or the Transaction Log panel; clear from options.
- Optional "Sort warband bank after item moves" - runs Blizzard's warband
  sort so split-created small stacks get consolidated (off by default).
