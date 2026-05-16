# Djinni's Warband Manager (DWM) — Design

Status: planning. New greenfield addon. Reference sources reviewed (do **not** ship code from them):
WarbandMiser, warband-nexus, WBT_WarbandTools, WarbankStockist, and Blizzard `wow-ui-source` (client **12.0.5.67602**, interface **120005**).

## 1. Goal & core idea

One unifying model: **balance a resource toward a per-character target**. Gold and items use the same
operation — at the warband banker, compute `onCharacter − target`; surplus deposits, deficit withdraws
(bounded by warband contents/space/cap). Targets come from the character's **purpose**, not rigid level
brackets.

### Features
1. **Easy per-character gold target** — `/dwm set <gold>`, plus options panel and (later) a bank widget.
2. **Purpose-based targets** — editable presets (Raider, Mythic+, Crafter, Gatherer, Leveling, Mule,
   custom). Per-character purpose, auto-suggested from professions, always overridable.
3. **Item balancing** — purposes/characters carry per-item targets (e.g. Crafter keeps ≥500 Enchanting
   Vellum). Surplus deposits; deficit withdraws — same model as gold.

### Non-goals (explicit)
- **Guild bank** — separate API, per-rank withdrawal limits; out of scope.
- **Currencies** (Artisan's Mettle, Valorstones, etc.) — not items, can't enter the warband bank.
- **Equipment / gear / quality-variant items** — only stackable, account-bank-allowed commodities.
- **Void storage / reagent *bank* tabs** — untouched.

## 2. The three banks — correctness contract

There are **three distinct banks**. Always pass the bank type **explicitly**; never act on "whatever bank
is open."

| Bank | `Enum.BankType` | Container bag IDs | Scope |
|---|---|---|---|
| Character bank | `Character` (0) | `CharacterBankTab_1..6` = 6–11 | per-character — **never touched** |
| **Warband / account** | `Account` (2) | `AccountBankTab_1..5` = 12–16 | account-wide, faction-agnostic — **our only target** |
| Guild bank | `Guild` (1) | separate API | out of scope |

Two traps this creates:

- **`C_Item.GetItemCount` signature.** Current:
  `GetItemCount(itemID, includeBank, includeUses, includeReagentBank, includeAccountBank)`.
  "On character" = carried bags only → `GetItemCount(id, false, false, false, false)`. The carried
  reagent **bag** (BagIndex 5) is ALWAYS in the base count; the 4th arg is `includeReagentBank` =
  the character **reagent bank** (character-bank territory) and MUST be `false`. Passing `true` here
  was a real bug: it inflated `have`, so keepmin over-deposited carried stacks to the warband.
  Excluding character bank, reagent bank, **and** account bank is mandatory — letting any bank's
  contents leak into the "on character" number corrupts every balance decision. This is the single
  most likely place the three-banks confusion produces a silent bug.
- **The warband bank must be purchased.** The first tab costs gold. Until then
  `C_Bank.CanUseBank(Enum.BankType.Account)` is false and `FetchPurchasedBankTabIDs(Account)` is empty.
  Must no-op with a clear message — never error. Same graceful handling for: no free warband slots,
  warband gold cap reached, no free bag space on withdraw.

## 3. Bank-operation reality (validated against Blizzard source)

- Item moves to/from the warband bank are **server-confirmed and async**. Items enter a **locked**
  state during transit (`ContainerItemInfo.isLocked`; `ITEM_LOCK_CHANGED` fires on toggle).
- Blizzard's UI uses **no timers and no throttle** — it is purely event-driven. Confirmation events:
  `ITEM_LOCK_CHANGED`, `PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED`, `BAG_UPDATE`.
- Blizzard's **bulk** operations are single server-side calls: `C_Bank.AutoDepositItemsIntoBank(bankType)`,
  `C_Container.SortBank(bankType)`. The server batches; the client fires once.
- `C_Container.UseContainerItem(bag, slot, nil, Enum.BankType.Account, reagentBankOpen)` is
  bank-context-aware (deposits from a bag slot, withdraws from a warband-tab slot) and avoids the
  cursor entirely. `PickupContainerItem`/`SplitContainerItem` (cursor) only needed for **partial
  stacks**.

**Consequence for DWM:** `UseContainerItem` gives robustness and zero cross-addon cursor contention,
**not** speed — per-item throughput is server-gated regardless of method. Therefore:

- Sequence moves on `ITEM_LOCK_CHANGED` / slot-changed events (adaptive), **never fixed timers**.
- One in-flight pass at a time; one in-flight move at a time (wait for confirmation before the next).
- A large rebalance is inherently many sequential confirmed moves — set this expectation in the UI.
- **Do not** use `AutoDepositItemsIntoBank` as a pre-pass for keep-min items: it deposits *all* flagged
  reagents including the ones we want to keep, forcing a deposit-then-withdraw thrash + race. Compute
  the desired end-state and make only the **minimal net move** per item (never deposit then withdraw
  the same item in one pass). The bulk call is acceptable **only** for `deposit-all` (qty 0) items.

## 4. Stack & architecture

Ace3 (approved). Rationale: **AceConfig renders the options panel *and* generates the slash-command
interface from one options table** — directly satisfies "expose every operation to commands and the
panel" with no duplicated logic.

- **AceAddon-3.0**, **AceDB-3.0** (profile + per-char resolution), **AceConfig/Dialog/Cmd-3.0**,
  **AceConsole-3.0**, **AceEvent-3.0** + **AceBucket-3.0** (coalesce `BAG_UPDATE`), **AceLocale-3.0**,
  **LibDataBroker-1.1** + **LibDBIcon-1.0** (minimap/broker).

```
DjinnisWarbandManager.toc        # interface 120005, Ace3 embeds, SavedVariables: DjinnisWarbandManagerDB
embeds.xml
Core.lua                         # AceAddon; AceDB; warband-available gate; orchestration
Modules/Balancer.lua             # shared engine: plan + execute gold and item moves
Modules/ItemEngine.lua           # UseContainerItem-first move, split fallback, event sequencing
Modules/Purposes.lua             # purpose presets + resolution chain
Modules/ProfessionDetect.lua     # suggest purpose from professions
Options.lua                      # ONE AceConfig table -> panel + commands
Locales/*.lua                    # AceLocale (enUS first; Blizzard-supported locales)
```

### Data model (AceDB)
```
profile.purposes[name] = {
    gold  = <copper>,
    items = { [itemID] = { qty = <n>, mode = "keepmin"|"exact"|"depositall" } },
}
profile.defaultPurpose, profile.mode = "deposit"|"withdraw"|"both",
profile.goldEnabled = true, profile.itemEnabled = false   -- items OFF by default
char.purpose, char.goldOverride, char.itemOverrides[itemID] = {qty,mode},
char.autoPurpose = true, char.managed = true              -- managed=false => fully ignored
```
**Resolution (gold & each item):** explicit char override → character's purpose → profile default.
Identical chain for both resources.

### charKey stability
Use the player **GUID** as the key with a `Name-Realm` → GUID migration map (as warband-nexus does),
so character/realm renames and connected realms don't orphan a character's purpose/overrides.

## 5. Per-item modes

`qty`-only is insufficient. Each item target has a **mode**:

- **keepmin** — deposit surplus above `qty`; **never withdraw**. Safe on characters that shouldn't
  accumulate the item, but it will NOT top a character back up.
- **exact** (the Vellum/Crafter case) — deposit *and* withdraw to hit exactly `qty` (true balance).
  This is what "always have at least 500 Vellum on the Crafter" actually requires: top up from the
  warband when low, skim the surplus when high.
- **depositall** (`qty = 0`) — deposit everything; never withdraw. Eligible for the server-side bulk
  call.

## 6. Purposes & profession detection

Presets ship sensible defaults (Crafter includes Enchanting Vellum `exact 500`, etc.). `Mule` purpose
= withdraw-all gold/items toward this character (WarbandMiser's "AllGold" pattern). On login, if
`char.autoPurpose`, suggest a purpose from professions (gathering→Gatherer, crafting→Crafter, none→leave
manual) — suggestion only, never silently overrides a user choice. `managed=false` excludes a character
entirely (bank alts).

## 7. Command + options surface (every node dual-exposed via AceConfig)

Engine: `enable`, `gold on|off`, `items on|off`, `mode deposit|withdraw|both`, `balance` (run now),
`pause` (session), `simulate on|off` (dry-run: plan + report, execute nothing).
This character: `set <gold>`, `purpose <name>`, `autopurpose on|off`, `manage on|off`, `clear`.
Purposes: `purpose list|add|del`, `purpose set <name> gold <amt>`,
`purpose item <name> <itemID|link> <qty> [keepmin|exact|depositall]`.
Items: `item <itemID|link> <qty> [mode]` (per-char), `item clear <id>`, `items list`.
Diagnostics: `status`, `log`, `debug on|off`; AceDBOptions gives profile copy/import/export free.
Item input also via **shift-click / drag an item link** into a config slot (users don't know item IDs);
resolve async item data with `C_Item.RequestLoadItemDataByID`.

## 8. Safety model

- **Items default OFF**, per-character opt-in, and the **first real item run requires confirmation**
  (or runs `simulate` first). Gold is forgiving; item moves feel destructive and are effectively
  un-undoable.
- **Cursor guard:** before any split/pickup, abort if the cursor is not empty (other addons act on the
  same bank-open). Prefer `UseContainerItem` (cursorless) for full stacks.
- **Reentrancy guard:** never start a pass while one is in flight; never issue the next move until the
  prior is confirmed by event.
- **Eligibility filter:** `C_Bank.IsItemAllowedInBankType(Enum.BankType.Account, ItemLocation)` is
  authoritative — do **not** parse tooltip strings (WBT's fragile approach). Also require: stackable,
  non-equippable.
- **Deterministic order & summary:** fixed order (gold, then items); one concise chat summary
  ("Deposited 1,240g + 300 Vellum; withdrew 50 Flux") + transaction log; capacity failures reported,
  never swallowed. Optional silent mode.
- Never run protected/secure paths in combat; gate every action on
  `C_Bank.CanUseBank(Account)` / `CanDepositMoney` / `CanWithdrawMoney`.

## 9. Reagent bag vs reagent bank

The carried **reagent bag** (`Enum.BagIndex.ReagentBag` = 5) counts as "on character" and is a valid
deposit source — reagents live there. The old reagent *bank* is merged into character-bank tabs and is
**not** ours. Test that `UseContainerItem` works from a reagent-bag slot.

## 10. Testing

No unit tests in WoW. `simulate` is the **primary Phase 3 dev tool**: plans and logs intended moves,
executes nothing. Required manual matrix: warband not purchased; warband empty; warband full; partial
stacks split across multiple tabs; item data not yet cached; cursor occupied by another addon; in
combat; character/realm rename; connected-realm alt.

## 11. Phasing

1. **Foundation + gold** — TOC, Ace3 embeds, AceAddon/AceDB, warband-available gate
   (`PLAYER_INTERACTION_MANAGER_FRAME_SHOW` + `AccountBanker`==68, **not** WarbandMiser's
   `Banker or AccountBanker` always-true bug), gold balancer, AceConfig skeleton
   (`enable`/`mode`/`set`/`status`), minimap/broker. No item risk — safe to start here.
2. **Purposes** — presets, resolution chain, `ProfessionDetect`, roster panel, `Mule`/`manage off`.
3. **Item engine** — `UseContainerItem`-first mover + split fallback + event-driven sequencing;
   eligibility filter; per-item modes; Crafter/Vellum preset; `simulate`-first; first-run confirm.
4. **Polish** — transaction log, full locale pass, item-link drag input, profile import/export,
   changelog.
5. **Account-wide item management** (§14) — persistent ledger, item-centric overview tab,
   residual-shortfall feedback. No new bank APIs; reuses the §3 scan + convergent model.

## 12. Borrow vs avoid (lessons)

Borrow: WarbandMiser's banker-open trigger & gold formatter; WarbankStockist's
`IsItemAllowedInBankType` filtering and qty-0=deposit-all; WBT's per-char→profile assignment model;
warband-nexus's resolution-order + transaction-log structure.
Avoid: WarbandMiser's `Banker or AccountBanker` truthiness bug; WBT's tooltip-string bind detection and
bespoke config panel; every reference addon's fixed-delay cursor queue (replace with `UseContainerItem`
+ event sequencing); warband-nexus's stale "WoW has no gold API" comment myth; using
`AutoDepositItemsIntoBank` for keep-min items.

## 13. Hardening (engineering review)

**13.1 Bank-ready state machine.** `PLAYER_INTERACTION_MANAGER_FRAME_SHOW` fires before the bank is
usable; `CanUseBank(Account)` may be false for a few frames; tab IDs can momentarily return empty.
State = `closed → opening → ready`. Enter `ready` only when **all** hold: `arg1 == AccountBanker` (68),
`C_Bank.CanUseBank(Account)` true, and `FetchPurchasedBankTabIDs(Account)` returns a non-empty stable
table. Use `BANKFRAME_OPENED` as the UI-ready signal and `BANKFRAME_CLOSED` to force `closed` + abort
any in-flight pass. No balancing runs outside `ready`.

**13.2 On-character count wrapper.** All counts go through one function
`DWM:GetOnCharacterCount(itemID)` = `C_Item.GetItemCount(id, false, false, false, false)`
(carried bags incl. the reagent *bag*, which is always in the base count; excludes character bank,
the character reagent *bank*, **and** account bank). Single patch point. The 4th arg
(`includeReagentBank`) must stay `false` - it is character-bank territory, not the carried bag.

**13.3 Lock-event handling (corrected).** `ITEM_LOCK_CHANGED` payload is `(bagOrSlotIndex, slotIndex)`
— **no locked boolean in the event**. On fire, re-query
`C_Container.GetContainerItemInfo(bag, slot).isLocked`: if still locked → ignore (in transit); if
unlocked **and** it is the slot our in-flight move targeted → the move is confirmed, advance the queue.
This prevents double-advancing on the lock half of the pair.

**13.4 Split retry/abort.** Partial-stack split can fail (cursor stolen, destination locked mid-op,
server stack-size mismatch). On failure: retry **once**, event-driven (after the next relevant
lock/slot event, not a timer). If it still fails, **abort the entire pass** with a clear message — never
loop. Cursor-empty precondition still applies before every split/pickup.

**13.5 Coalesced rescan.** `PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED` is not guaranteed per slot. After
each confirmed move, rescan the affected bag/slot immediately, **and** schedule a coalesced full-tab
rescan via AceBucket on `BAG_UPDATE_DELAYED` to reconcile the internal model with the server.

**13.6 Profession detection guards.** No auto-suggestion when: only secondary professions
(Cooking/Fishing) are known; profession data missing/incomplete; or specialization data present without
a learned base profession (known Blizzard inconsistency). Suggestion is always a suggestion — never
silently applied.

**13.7 Gold-cap race.** Do **not** rely on a `FetchBankLockedReason()` gold-cap value (none is
documented; enum is `NoAccountInventoryLock/BankDisabled/BankConversionFailed`). Instead: pre-check
warband total against the cap before depositing; after the deposit, verify
`C_Bank.FetchDepositedMoney(Account)` increased by the expected delta. If not, treat as cap/failure,
abort the pass cleanly, report. Also check `FetchBankLockedReason()` for the documented disabled/locked
states before acting.

**13.8 Simulate = capacity prediction.** `simulate` does not just list intended moves; it predicts
feasibility: free warband slots, free bag slots, per-item max stack sizes, eligibility. Output e.g.
"Would withdraw 200 Flux, but only 40 bag slots free — 160 deficit remains." This is the primary
debugging tool.

**13.9 Stable, deterministic order.** Items sorted by `itemID` ascending; deposits then ordered by
`(bag, slot)`, withdrawals by `(tab, slot)`. Gold before items. Guarantees reproducible logs and
reproducible `simulate` output.

**13.10 Poor-quality exclusion.** Items with quality `0` (poor) are ignored even if stackable and
account-bank-allowed, unless explicitly configured per-item. Prevents accidental junk deposits.

**13.11 Concurrency — convergence, not locking.** SavedVariables are **not** live IPC (read at load,
written at logout; last-writer-wins) — they cannot lock out a *simultaneously running* second client.
Therefore the balancer is **state-driven and convergent**: every pass re-derives the move set from
current server state, so concurrent runs from two clients converge (the second finds targets already
met and no-ops) rather than corrupt. Keep an SV "last rebalanced by <char> at <time>" stamp only as a
**soft next-login notice**, never as a gate.

**13.12 Item-data timeout.** `C_Item.RequestLoadItemDataByID` can silently never return for obscure
items. If data is not loaded within ~2s, fall back to itemID-only display/handling; never block a pass
waiting on item data.

**13.13 GUID map collisions.** Connected realms can yield same-name characters on different realms.
The Name→GUID map stores multiple candidates and resolves by realm when known; "first seen" is the last
resort only.

**13.14 Combat & frame-close aborts.** On `PLAYER_REGEN_DISABLED` or `BANKFRAME_CLOSED`, abort the
in-flight pass immediately and reset the queue/state — do not leave a move "pending" across the
transition (events can arrive out of order as the bank force-closes).

**13.15 Post-bulk reconcile.** `AutoDepositItemsIntoBank` (used only for qty-0 deposit-all) has a
history of depositing unintended items (some tools, cosmetic stackables, quest items). After the bulk
call, rescan the warband, diff against expectation, and surface (optionally auto-withdraw) anything
unexpected.

## 14. Phase 5 — Account-wide item management

Addresses two user gaps: (a) no at-a-glance view of which characters/purposes source vs sink
which items; (b) shortages ("enchanter needs 500 Vellum, warband has 0") are invisible unless
you are standing at the bank on the needy character, and even there a *partial* shortfall is
never quantified. Builds entirely on existing mechanics — no new bank APIs, same convergent
model (§13.11): snapshots are advisory; the live scan at the bank stays authoritative for the
actual pass.

**14.1 ItemLedger module (new).** Persistent account snapshots in `db.global` (created lazily
like `global.characters`, **not** in AceDB `defaults`):

- `db.global.warband = { items = { [itemID] = count }, scannedAt = <time>, scannedBy = <display> }`
  — full warband-tab scan captured when the §13.1 state reaches `ready`, and re-captured while
  open on a coalesced `BAG_UPDATE_DELAYED` / `PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED` bucket.
  **ItemLedger registers its OWN `RegisterBucketEvent`** — it must NOT piggyback ItemEngine's
  bucket, which is session-scoped (created in `Run`, unregistered in `_Finish`/`_Abort`) and so
  does not exist between passes. Generalize ItemEngine's `WarbandCount` into a shared
  `ScanWarband()` returning the whole `{[itemID]=count}` table (one scan, reused by both).
- `db.global.characters[GUID].itemCounts = { [itemID] = count }`, `.itemCountsAt = <time>` —
  on-hand counts via `DWM:GetOnCharacterCount` (§13.2), but **only for items managed for that
  character** (its resolved target set ∪ overrides), so SV stays O(managed items), not
  Altoholic-style full-bag. Captured after `Roster:EnsureCurrent` on `PLAYER_LOGIN` /
  `PLAYER_ENTERING_WORLD` and on a coalesced `BAG_UPDATE_DELAYED` bucket. **Skipped entirely for
  `managed=false`** characters. Pruned to currently-managed IDs on every snapshot so config
  changes shrink it. **Lifecycle:** snapshot-time pruning can't clean a character that stops
  snapshotting — so when a character is flipped to `managed=false` (the `manage` setter, and
  `Roster:Delete`), wipe its `itemCounts`/`itemCountsAt` immediately rather than leaving stale
  data that never self-prunes.
- All snapshots timestamped and **stale-tolerant**: displayed as "as of <relative time> · <char>",
  never gate a move. Missing/empty snapshots (fresh install, alt never logged in) render as
  "—/unknown", never error.

**14.2 Generalized resolution (Purposes).** `ResolveItemsForCurrent()` becomes a thin wrapper over
new `ResolveItemsFor(rec)` so the report resolves targets for **any** roster record. Add
`AllManagedItemIDs()` = union of every purpose's `items` + every char's `itemOverrides` — drives
the overview row list and the per-char snapshot filter.

**14.3 Account report.** `ItemLedger:BuildReport()` — pure, deterministic (itemID asc, §13.9),
shared by the tab, status block, broker, and simulate. Per managed itemID:

- per-character: resolved `{qty,mode}`, snapshot `have`, derived intent (deposit surplus /
  withdraw deficit / keep) — the **same math as `ItemEngine:BuildPlan`**, evaluated from snapshots
  for every managed char, not just current.
- aggregate: `warband` (ledger); `demand` = Σ exact-mode deficits (`qty−have` where `have<qty`);
  `supply` = `warband` + Σ surplus deposits (depositall `have`; keepmin/exact `have−qty`);
  `shortBy` = `max(0, demand − supply)`.

**Profile-scope seam (known semantic, not a bug).** Purposes and their `items` live in
`db.profile` (per AceDB profile); the roster lives in `db.global`. `BuildReport` resolves every
character's intent through the **active profile's** purpose definitions, even for characters last
seen under a different profile. This is correct for the single-profile norm; with multiple
profiles the report reflects "what the current profile's rules say about each character." State
this in the tab header/help so it is expected, not surprising. (Pre-existing characteristic of
the §4 model; §14 only makes it visible.)

**14.4 Item-centric overview tab (Options).** New top-level dynamic group `itemsoverview`
(rebuilt by `ns.RefreshOptions()` alongside purposes/roster). Per item: a collapsible inline
group headed by name + warband count + `OK` / `▲ SHORT n`; children = each purpose targeting it
(inline qty input + mode select + del, reusing `Purposes:SetItem`/`DelItem`) and each managed
character's resolved `have → intent` line; plus an "add item to purpose" input (reuse
`ParseItemArgs`, link/id). The existing per-purpose inline item editor **stays** (natural place to
bulk-edit one purpose); this tab is the cross-cutting view.

**14.5 Residual-shortfall feedback (ItemEngine).** `BuildPlan` already clamps exact-withdraw to
`min(qty−have, wb)`; capture the clamped remainder as `e.shortfall`. Surface the **number** (not
just the boolean `MSG_ITEM_NONE_IN_WB`) in simulate output ("withdraw 50 Vellum — still 150
short, warband holds 0") and in the post-pass summary / `blocked` finish for live runs. Delivers
the §13.8 promise for the warband-empty/partial case.

**14.6 Alert surfaces (user-selected; login summary explicitly de-scoped).**
(a) **Chat at bank** — residual shortfalls appended to the existing ItemEngine summary/simulate
lines (§14.5). (b) **Panel status block** — a dynamic `description` "Unmet demand" under the live
summary listing every `shortBy>0` item from `BuildReport()`. (c) **Broker tooltip** — in
`OnTooltipShow`, after the gold lines, "Items short: N" + up to ~3 worst offenders.
(d) **`/dwm ledger` chat command** — prints `BuildReport()` (per-item warband count, per-char
have→intent, `shortBy`). This is the primary testable entry point during the build (the build
order's earlier "/dwm print" phrasing predates the current command surface — there is no
`print` command; use `ledger`). Registered like `/dwm log` (top-level execute, AceConfig node).

**14.7 Files.** New `Modules/ItemLedger.lua` (.toc: after `Purposes.lua`, before `Balancer.lua`;
addon code, not a lib → not in embeds.xml). Edits: `Purposes.lua` (`ResolveItemsFor` /
`AllManagedItemIDs`), `ItemEngine.lua` (`shortfall`, shared `ScanWarband`), `Options.lua`
(overview tab + status block + `/dwm ledger` execute + refresh wiring + **`manage` setter wipes
`itemCounts`**), `Roster.lua` (**`Delete` wipes `itemCounts`**), `Core.lua` (ItemLedger's own
bucket + snapshot triggers on bank-ready/login/bag-update + broker lines), `Locales/enUS.lua`
(new strings, incl. profile-scope help text), `.toc` (add file + version bump), this doc + memory.
Parse-check every edited Lua with luac 5.1 (§ reference-lua-toolchain), 0 errors required;
in-game shakedown still gates release (item subsystem is the irreversible one).

## Appendix — confirmed API contract (client 12.0.5, non-deprecated)

- Banker gate: `PLAYER_INTERACTION_MANAGER_FRAME_SHOW`, `arg1 == Enum.PlayerInteractionType.AccountBanker` (68).
- Gold: `C_Bank.DepositMoney/WithdrawMoney/FetchDepositedMoney(Enum.BankType.Account)`;
  gate `C_Bank.CanUseBank/CanDepositMoney/CanWithdrawMoney`; `C_Bank.FetchBankLockedReason()`.
- Item move (full): `C_Container.UseContainerItem(bag, slot, nil, Enum.BankType.Account, reagentBankOpen)`.
- Item move (partial): `C_Container.SplitContainerItem(bag, slot, qty)` → `C_Container.PickupContainerItem(destBag, destSlot)` (cursor; guard cursor empty first).
- Bulk (depositall only): `C_Bank.AutoDepositItemsIntoBank(Enum.BankType.Account)`.
- Filter: `C_Bank.IsItemAllowedInBankType(Enum.BankType.Account, ItemLocation)`.
- Tabs: `C_Bank.FetchPurchasedBankTabData/IDs(Enum.BankType.Account)`; bag IDs `AccountBankTab_1..5` (12–16).
- On-char count: `C_Item.GetItemCount(id, false, false, false, false)` (carried bags incl. ReagentBag 5; NOT the reagent bank); scan bags `0..NUM_BAG_SLOTS` + `ReagentBag` (5).
- Move-confirm / sequencing events: `ITEM_LOCK_CHANGED` (re-query `GetContainerItemInfo(bag,slot).isLocked` — no locked flag in payload), `PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED`, `BAG_UPDATE`, `BAG_UPDATE_DELAYED` (coalesce via AceBucket).
- Abort triggers: `PLAYER_REGEN_DISABLED`, `BANKFRAME_CLOSED`.
- Lifecycle: `BANKFRAME_OPENED` (UI-ready signal for the 13.1 state machine).
