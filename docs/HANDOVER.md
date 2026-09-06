# HANDOVER: Djinni's Warband Manager (DWM)

> A World of Warcraft Retail addon that balances gold, and later items, toward a per-character
> target driven by what that character is for. Read this, then `docs/board/`, before changing
> anything.

**Stage:** active
**Category:** addon
**Status:** v0.3.2, `Interface: 120100`. Tree clean, nothing unpushed, remote
`github.com/RobertLCraig/DjinnisWarbandManager`. Last commit `2026-08-12`, "chore(12.1.0): update
for Midnight 12.1.0 and tighten deploy exclusions". **Installed and running in the game.**
**`DESIGN.md` still says "Status: planning" while v0.3.2 is deployed**, so that file describes the
intent and not the build. Trust the code and this page over it.
_Last updated: 2026-08-26 (board and handover created; no addon code was touched)_

## Goal & success criteria
**No PRD exists. `DESIGN.md` in the repository root is the nearest thing** and is the source for
everything below. It is a design document rather than a signed-off spec, and it is stale on status.

Goal, in `DESIGN.md`'s words: one unifying model, **balance a resource toward a per-character
target**. Gold and items use the same operation. At the warband banker, compute
`onCharacter - target`; a surplus deposits and a deficit withdraws, bounded by warband contents,
space and cap. **Targets come from the character's purpose, not from level brackets.**

Feature 1 in `DESIGN.md` is the per-character gold target: `/dwm set <gold>`, an options panel, and
a bank widget later.

**The non-goals are unknown and need Rob.** For an addon that moves gold automatically, that is the
gap that matters most on this page.

## Canonical data shape
`DjinnisWarbandManagerDB`, one account-wide SavedVariables table declared in the `.toc`, holding the
per-character purpose and target. **Its shape lives in `Core.lua`, `Options.lua` and `Modules/`, and
nowhere else**; there is no `DATA-MODEL.md`, and for an addon whose whole model is "a target per
character" that is a real gap.

## Architecture / stack
Lua against the Blizzard Retail API, Ace3 and friends bundled under `libs/` and wired in through
`embeds.xml`. **`embeds.xml` hard-references `libs\LibStub\LibStub.lua` and the Ace3 XML files by
path**, so a clone without `libs/` does not load at all - which is exactly why `WoWAddons#0003`
reversed its own criterion and `libs/` is tracked. Locales under `Locales/`, features under
`Modules/`. 50 Lua files counted on disk, most of them the bundled libs. No build step beyond
`release.ps1` and no test suite: **every check that matters happens in a live game client, which no
agent can run.**

## Key files / structure
- `Core.lua` - load, event wiring and `DjinnisWarbandManagerDB`.
- `Options.lua` - the settings UI and `/dwm`.
- `Modules/` - the per-feature code, including the balance operation itself.
- `embeds.xml` - the library load order. **Editing `libs/` without editing this breaks loading.**
- `Locales/` - translations.
- `libs/` - bundled Ace3 and friends. **Tracked on purpose**, see above.
- `deploy.ps1`, `release.ps1`, `pkgmeta.yaml` - this addon owns its own, with their own exclusions.
- `DESIGN.md` - **the design, and stale on status.** It also names the reference sources reviewed
  and says plainly: do not ship code from them. Those are `WarbandMiser`, `warband-nexus`,
  `WBT_WarbandTools`, `WarbankStockist` and Blizzard's `wow-ui-source`; four of the five sit beside
  this addon in `C:\Dev\WoWAddons`.
- `CHANGELOG.md`, `RELEASE_NOTES.md` - history, not a plan.

## Decisions locked
- **One operation for every resource.** Gold and items both reduce to `onCharacter - target`. A
  feature that needs its own separate mechanism is a signal the model is wrong, not that the model
  needs an exception.
- **Targets come from purpose, not from level.** `DESIGN.md` is explicit about this.
- **Reference sources were read, and no code was taken from them.** `DESIGN.md` names them and says
  so. Keep it that way; the four sitting locally are other people's work.
- **`libs/` is tracked**, because `embeds.xml` references it by path. See `WoWAddons#0003`.

## Current state
Active and deployed at v0.3.2. The 12.1.0 update landed on `2026-08-12`. **How much of `DESIGN.md`
is actually built is not recorded anywhere**, and `DESIGN.md` itself still says "planning", so the
first job for the next session is to measure that rather than to trust either document.

## What's next (in order)
**`docs/board/` owns this.** The board is empty because nothing has been triaged into it yet. The
obvious first card is the one above: read the code against `DESIGN.md` and write down which features
exist.

## Blockers / open questions
- **`DESIGN.md` is stale on status and possibly on scope.** Nothing here says which of its features
  shipped.
- **The non-goals are unstated**, and this addon moves gold on a player's behalf. A bounded, stated
  set of things it will not do is worth more here than in any other addon in this workspace.
- **The 12.1 secret-values fault has not been ruled out here.** The sweep updated the `.toc` and
  checked nothing else, and this addon keys work per character. See
  `C:\Dev\WoWAddons\docs\DECISIONS.md`.

## How to pick up
1. Read this file, then `docs/board/README.md` and any card in `docs/board/`.
2. Read `DESIGN.md` for intent, and **do not trust its status line**.
3. Read `C:\Dev\WoWAddons\docs\DECISIONS.md` for the two 12.1 traps before touching event
   registration or anything keyed on a unit.
4. Deploy from the workspace and never edit the game folder:
   `C:\Dev\WoWAddons\bin\deploy.ps1 -WhatIf -Only DjinnisWarbandManager`, then the same without
   `-WhatIf`. The dry run is the plan.
5. Check any API against `C:\Dev\WoWAddons\wow-ui-source\`, never from memory. Anything defined only
   under `Blizzard_Deprecated*/` is CVar-gated and is not safe to rely on.

## Sibling docs
- `DESIGN.md` in the repository root: goal, model and feature list.
- Workspace: `C:\Dev\WoWAddons\docs\HANDOVER.md` and `docs\DECISIONS.md`.
- **Gaps:** no `README.md`, no `PRD.md`, no `DATA-MODEL.md`, no `DECISIONS.md`.

## Branch status
One branch, `master`. Clean, level with `origin/master`.

## Session log
- **2026-08-26** Board and handover created, so this stops showing on `board:map` as an
  unidentifiable nested folder. No addon code was touched.
