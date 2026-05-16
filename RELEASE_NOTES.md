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

Phase 5/6 - account-wide item management + profession-conditioned items
(in progress).

- **Fixed: entering a gold value in the options panel errored** ("base out
  of range") and silently failed - a `tonumber(gsub(...))` mistake. Gold
  inputs now parse correctly.
- The `/dwm` options window now opens tall enough for the Items Overview /
  Roster tabs (was too short, leaving the scroll unusable), and your
  resized/moved size & position now persist across sessions.
- Account-wide shortages now also surface passively: an "Unmet demand" line
  at the top of the options panel and on the minimap/broker tooltip.
- **Bank-side config button.** A small draggable button appears while the
  bank is open; click to open options, right-click to pause/resume, drag to
  reposition (saved). Frame-independent, so it works with Baganator, Bagnon,
  ArkInventory, OneBag, and the default UI. Toggle in options.
- **New "Items Overview" options tab.** One entry per managed item showing
  warband stock and an OK / SHORT n / NO DATA headline, the per-purpose
  quantity / mode / required-profession / min-skill editors, and a
  per-character "have -> intent" breakdown - the single place to see and
  manage what's balanced between which characters.
- **Profession-conditioned item targets.** An item can require a profession
  (and optional min skill); each character's professions are recorded on
  login. The Crafter preset's Enchanting Vellum now requires Enchanting, so a
  Crafter without it no longer stocks Vellum (multi-profession characters get
  every set they qualify for). Set gates with
  `/dwm purposeitemprof <purpose> <link|id> <profession|none> [minSkill]`.
  (Existing profiles: the gate is added to new installs only - set it on your
  Crafter once with that command.)
- **Fixed: a manually-chosen purpose (e.g. Banker/Auctioneer) reverted to a
  profession-detected one after /reload.** Explicit purpose picks are now
  correctly marked user-set and never auto-overridden.
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
- When the warband bank can't fully top a character up, it now says exactly
  how much is still short (e.g. "still short 150 x Enchanting Vellum
  (warband holds 0)") - in both simulate and live runs at the bank.

Phase 4 - polish (in progress).

- Transaction log: every gold/item move is recorded (account-wide, capped).
  View with `/dwm log` or the Transaction Log panel; clear from options.
- Optional "Sort warband bank after item moves" - runs Blizzard's warband
  sort so split-created small stacks get consolidated (off by default).
