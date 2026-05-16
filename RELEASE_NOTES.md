<!--
  This file drives release.ps1:
  - The "## Version:" line below is the single source of truth for the version
    (release.ps1 syncs the .toc to match and tags the git release).
  - Everything below the Version line becomes the GitHub release body and the
    new CHANGELOG.md entry. Replace it each release; keep it user-facing.
-->

# Release Notes

## Version: 0.3.1

Phase 3 - item balancing.

- New **Banker/Auctioneer** purpose preset (large working gold float for
  auction-house play; keeps a bounded target rather than draining the warband
  bank like Mule).
- Preset seeding is now forward-safe: new presets reach existing profiles,
  while presets you delete stay deleted.
- Fixed money display showing "???" instead of coin icons (and unreadable
  when copied): amounts now print as comma-grouped, colored g/s/c text.
- Fixed on-character item count wrongly including the character reagent
  *bank*, which could make "keep at least" over-deposit carried stacks.
- Crafter's Enchanting Vellum preset now uses **exact** mode (maintains 500:
  tops up from the warband when low, skims the surplus when high) - matching
  "always have at least 500 on the Crafter". keepmin never withdraws by
  design, so it would not top a character back up.
- The options panel now shows a live summary at the top - current character,
  its purpose, and the resolved gold target - and names the character in the
  "This Character" section, so the active purpose is obvious at a glance.

- Balances stackable reagents toward per-character targets, the same model as
  gold: surplus deposits to the warband bank, shortfall withdraws.
- Three per-item modes: **keep at least** (deposit surplus, never withdraw -
  e.g. Crafters keep 500 Enchanting Vellum), **maintain exactly** (deposit and
  withdraw), and **deposit all** (keep none).
- Item targets live on a purpose (the Crafter preset already keeps Vellum) and
  can be overridden per character.
- **Safety first**: item balancing is OFF by default, and the first real run
  is simulated until you explicitly confirm it. Simulate mode predicts space
  problems before they happen.
- Item moves use Blizzard's bank-context API with event-driven pacing (no
  fragile fixed delays) and re-derive from live state, so an interrupted run
  simply finishes next visit. Aborts cleanly on combat or closing the bank.
- Configure from the panel (per-purpose item editor) or commands: paste an
  item link or ID - `/dwm item <link|id> <qty> [keepmin|exact|depositall]`,
  `/dwm items`, `/dwm itemenable on|off`.
