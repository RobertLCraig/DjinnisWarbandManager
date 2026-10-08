---
not_for_the_loop: every check is in a live game client
---

# 0004 Jinn empties the Transmog DOESNT Sell guild bank into the warband bank

Rob, 2026-10-08: "review transmog doesnt sell bank, and Jinn use that to move items from that bank
to the anything for profit to sell".

Jinn cannot open "Anything for Profit": a character is in one guild only. So the route is the
warband bank, which every character on the account can open.

## How it works

- The plan file now has `feeders`: Jinn-Shadowsong for "Transmog DOESNT Sell" (291 copies on the
  2026-10-08 build) and Pouches-Aggra for "Storinator" (9 copies). Each list is every planned copy
  that sits in that guild bank.
- At its storage guild bank, a feeder takes the planned copies out (mode `feed`).
- At a bank, a feeder puts every bag copy of those items into the warband bank.
- The AH characters withdraw them from the warband bank at a bank, as before.
- Progress is saved account-wide (`db.global.ahFeed`), per plan build, and counted only when the
  bags show the copy. So a copy taken out, put in the warband and sold is never taken out again.
- The AH plan window opens at the feeder's guild bank, and at a bank when the AH plan has moves
  there. A bank visit no longer prints the AH plan's dry run to chat: AH plan items wait for the
  window's Move items button, or move by themselves if "Move items by themselves" is ticked.

## Acceptance

- [ ] On Jinn, opening the Transmog guild bank shows the window with take-out moves; Move items
      takes them out until the bags are full.
- [ ] On Jinn at a bank, the window shows put-in moves, and Move items puts them in the warband.
- [ ] A second Transmog visit does not take out what was already taken.
- [ ] On What (or any AH character) at a bank, the window shows take-out moves from the warband.
- [ ] Jinn's guild bank withdraw limit stops it cleanly, with no Lua error.

## Limits

- The warband had 109 free slots on the 10:10 save, and most of these items do not stack, so it
  takes three or so rounds: Jinn fills the warband, the AH characters empty it, repeat.
- Jinn's rank in Transmog DOESNT Sell may have a daily withdraw limit per tab. The engine reads it
  (`GetGuildBankTabInfo`) and skips a tab with no withdrawals left.

## Comments

**2026-10-08** 42 offline checks pass, 9 of them new for the feeder (role, guild check, take-out
count, confirmed-only counting, warband put-in, second visit, new plan resets the count).
