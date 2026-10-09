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

**2026-10-08** In game on What: 13 warband take-outs (single gear items) built 0 moves with 60 bag
slots free, so the run stopped "blocked". The cause of the missed free slot is not proven. Fix in
79a7348: a whole stack now leaves the warband bank by right-click (`UseContainerItem(tab, slot)`, as
`BankFrame.lua` does), so the server picks the bag slot. A part stack still needs a free slot found
first. `/dwm debug on` now prints the empty slot counts and, per item, why it made no move. 50
offline checks pass.

**2026-10-08** The new debug found the cause: all 13 warband slots read `isLocked`, with 60 free bag
slots. Blizzard's bank right-click does not check `isLocked`, so whole-stack take-outs now ignore it
too (505d946). Why the slots read locked is not known. Open check: do the 13 come out on What?

**2026-10-08** Rob: the items stayed greyed out through several reloads. A full logout of several
minutes cleared them, and the addon then moved items normally. So it was a lock held on the game's
side. Fix 430eefc: a batch move now counts when it lands, not when it is sent, and a run where every
refused slot is still locked stops with "log out for a few minutes". 52 offline checks pass.
**2026-10-08** Lostpets: pet deposits stopped "blocked" after one second while pets were still
landing, and many pets went grey. TSM's `MoveThread` yields a frame after every move and never gives
up on a move in flight; this addon sent the whole batch in one go. Fix aac223c: one move per frame,
and a wait on copies in flight that restarts whenever one lands (10 s with nothing landing, then
the log-out message). Whole-stack deposits now use Blizzard's warband deposit call (d92ffc7).
**2026-10-09** What: 55 guild bank withdraws worked (some dropped and re-sent). Then at the warband
bank, 19 take-outs (6 pets, 13 items) were sent one per frame, three times, and none landed; the run
stopped with the log-out message. Third stale-lock run; each came after many moves in a short time,
which points at a server rate limit, not proven. Fix a390f8e: the run records every
`UI_ERROR_MESSAGE` and prints it at the end, and never re-sends a slot it already sent from while
that slot is locked. Next: read the game's refusal text from the next stuck run.
**2026-10-09** Loamint: 44 pet take-outs. The debug slot counts show 38 landed (bag empties 130 to
92), but the window said "Stopped after 20 of 44": copies that land after their batch timed out were
never counted. Pets reached the bags about 12 s after sending. The game said "Internal Bag Error"
twice, on two single re-sends. 6 pets stayed locked and the run stopped at the 10 s wait. Fix: progress
is now the plan total minus what the plan still needs, and the wait is 20 s. Open check: does a second
press, a minute later, move the last few?
**Open risk:** the locks may have come from our own 74-move batch just before. If greyed items show
up again after a big batch, cut `BATCH_MAX` in `Modules/ItemEngine.lua`.
