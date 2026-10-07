---
not_for_the_loop: every check is in a live game client, and the plan file is built from Rob's own saved data
---

# 0001 AH plan: spread auction stock across the four AH characters

Rob posts on four characters, each on a different auction house (AH): Buyme (Aggra), What
(Shadowsong), Loamint (Moonglade) and Hotwheel (Ghostlands). Buyme posts about 500 auctions; many
have expired in dozens of posting rounds with no sale. The goal is to give each item its best AH,
and to make the moves happen at the warband bank with no manual sorting.

## How it works

1. **Outside the game**, `tools/ahplan/` reads Syndicator (bags, banks, posted auctions, guild
   banks, warband bank), TSM AuctionDB for each AH, TSM's own sales and expiry history, and
   undermine.exchange live listings. It decides how many copies of each item each AH character
   should hold, and writes `Data/AHPlan.lua`.
2. **In the game**, DWM treats each planned item as an `exact` target for an AH character. All
   four AH characters are in the guild "Anything for Profit", and its guild bank carries the moves
   (the warband bank was full). At that guild bank, Buyme deposits copies that belong on another
   AH character, and the other three withdraw the copies planned for them. At the warband bank,
   planned items can be withdrawn but are never deposited, so the guild bank stays the one channel.
   Copies already posted or in the mail (from Syndicator) count as held, so a posted copy is not
   replaced. A whole stack deposits the way a right-click does, so the server picks the slot.
3. **Storage characters** (Pouches and Shortnbitter on Aggra, Jinn on Shadowsong) cannot open that
   guild bank. They mail planned items from the Storinator and Transmog DOESNT Sell guild banks to
   Buyme or What by hand. The report's `2-post-from-storage.csv` lists what to send.
4. TSM still prices and posts everything. The plan only decides where an item sits.

## Acceptance

- [ ] `Data/AHPlan.lua` builds from `tools/ahplan/build.ps1` with no hand editing.
- [ ] The plan is OFF by default. Turning it on and opening the guild bank prints a dry run
      first; moves happen only after `/dwm ahplanconfirm`.
- [ ] On Buyme, a guild bank visit deposits planned items that belong on another AH character.
- [ ] On What, Loamint and Hotwheel, a guild bank visit withdraws the copies planned for them.
- [ ] A full guild bank tab, or one the rank cannot deposit to or withdraw from, is skipped.
- [ ] An item that is posted or in the mail is not withdrawn again.
- [ ] Items outside the plan, and the existing Crafter vellum target, behave as before.
- [ ] No Lua error with Syndicator disabled (the plan then counts bags only, and says so).

## Out of scope for this card

- Battle pets. All caged pets share item ID 82800, and the engine matches on item ID.
- Moves in the storage guild banks (Storinator, Transmog DOESNT Sell). Storage characters mail
  those items by hand.
- Guild banks nobody can open now (Creality: all members are on an unsubscribed account).

## Comments

**2026-10-07** Built as part of DWM, not a new addon: DWM's goal is "balance items toward a
per-character target", and its item engine already does sequenced, server-confirmed warband
moves. This widens DESIGN.md's non-goal "equipment / gear" for planned items only.

**2026-10-07** Design changed during the build. The warband bank was full, so the transport is the
"Anything for Profit" guild bank, and DESIGN.md's guild bank non-goal is lifted for AH-plan items
only. The feeder role is gone: storage characters sit in guilds the AH characters cannot open, so
they mail. 21 offline checks pass (`lua tests/test_ahplan.lua`). They prove the decisions, not
that the client accepts the calls. The in-game check is Rob's.
