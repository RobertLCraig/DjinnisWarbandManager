---
not_for_the_loop: every check is in a live game client
---

# 0005 Faster bank moves, progress in the window, text that does not overlap

Rob, 2026-10-08: "need to give a bit more space in the AH Plan to text when it grows so that text
doesnt end up overlapping. need more feedback when doing moves into and out of the banks. warbank
can transfer significantly faster (again check how TSM does this, both for warbank and guildbank)".

## How TSM moves items (read from the installed addon, not copied)

`TradeSkillMaster/Core/Service/Banking/Core.lua` `MoveThread` and `MoveContext.lua`:

- Every move is planned first: each source slot gets its own empty target slot.
- Bank and warband bank: all moves are sent at once (`SplitItem` then `PickupItem` onto the empty
  slot, then `ClearCursor`), then it waits up to 2 s for any to land, and sends the rest again.
- Guild bank: one move at a time. It sends the next as soon as the source slot shows the last one,
  with no fixed pause.

## What changed

- Warband bank and bank: batches of up to 60 moves, each slot to its own empty slot, in one step.
  The next batch waits until every source slot shows its move (4 s timeout). Three batches in a row
  with nothing landed ends the run. Withdrawals land in the backpack and bags 1-4, never the reagent
  bag.
- Guild bank: the pause after a confirmed move is 0.3 s, down from 0.8 s. The re-send of a dropped
  move stays.
- Window: each line is anchored under the one above, so wrapped text pushes the rest down. The list
  stays live while items move. A progress bar and a status line show "Moved n of m. Now: ...", then
  "Done" or "Stopped after n of m" with the reason. A sound plays when a run finishes.

## Acceptance

- [ ] A long feeder summary on Jinn does not overlap the checkboxes.
- [ ] Jinn at a bank puts 50+ items into the warband in a few seconds, not one per second.
- [ ] An AH character at a bank takes its items out of the warband just as fast.
- [ ] The progress bar fills and the status line names the item moving.
- [ ] A run that stops says why.

## Comments

**2026-10-08** 48 offline checks pass; 6 new ones cover the batch (all moves in one step, distinct
target slots, the taken slot skipped, waits while in flight, ends when all landed).
