---
not_for_the_loop: every check is in a live game client
---

# 0006 Battle pets in the AH plan

Rob, 2026-10-08: "what is in "Bank of Requirement" on Lostpets that we can also balance and sell?"
Then, offered selling them by hand or building pet support, he picked pet support.

## What is there

Syndicator's save of 2026-10-08 13:39: Bank of Requirement (Aggra) holds 122 caged battle pets and
nothing else. Every one is saved as a plain Pet Cage (item 82800) with no species. The same is true
of every guild bank on the account: NoMoni 154, Regenesis 57, Creality (Aggra) 42, Creality
(Silvermoon) 5. Not one guild bank cage has a species.

## Why the plan cannot sell them today

- The builder (`tools/ahplan/analyze.py`) prices pets by species (`p:<species>`), but a guild bank
  cage has none.
- `GetGuildBankItemLink` gives item 82800 for a caged pet. Syndicator recovers the species from
  `C_TooltipInfo.GetGuildBankItem(tab, slot).battlePetSpeciesID`
  (`Syndicator/Tracking/GuildCache.lua`), and that recovery saved nothing on this account.
- The plan file and the item engine both match on item ID, and every caged pet is 82800.

## Steps

1. **Learn the species in game (done, waiting on Rob).** `Modules/PetScan.lua` reads every caged
   slot of the guild bank tab on screen three ways (battlepet link, tooltip data field, tooltip name
   line through `C_PetJournal.FindPetIDByName`) and saves what works in
   `db.global.petScan[guild]`. `/dwm pets` reports cages, known species and which read worked.
2. **Builder reads the species.** `dump.lua` also loads DWM's SavedVariables and emits the recorded
   species for those guild bank cages in place of Syndicator's plain cages. Lostpets becomes a
   feeder for Bank of Requirement. The plan file gains pet targets.
3. **Engine moves pets by species.** A pet target gets its own key (proposal: the negative species
   ID, so it never meets an item ID), and every slot match reads the slot's species instead of
   the item ID: bags and warband from the `battlepet:` hyperlink, guild bank from step 1's reads.

Step 2 and 3 depend on which read works in step 1. If none works, a guild bank pet's species cannot
be learned without taking it out, and the fallback is a feeder that takes every cage out to its
bags, where the hyperlink carries the species.

## Acceptance

- [ ] Step 1: on Lostpets at Bank of Requirement, after clicking each tab, `/dwm pets` shows the
  cages with a known species, and says which read worked.
- [ ] Step 2: the rebuilt plan lists pets for the AH characters and Lostpets as a feeder.
- [ ] Step 3: Lostpets moves the planned pets to the warband bank, and an AH character takes them.

## Comments

**2026-10-08** Step 1 in game, Lostpets at Bank of Requirement: "6 tab(s) seen, 62 cages, 0 known.
Read by link 0, tooltip 0, name 0, not read 62." No read works on a guild bank cage. Syndicator
counted 122 at 13:39; the gap is not explained. Next: the fallback (cages out to bags, where the
`battlepet:` hyperlink carries the species; Syndicator already holds 277 such bag links), or one
more diagnostic round to learn why the reads fail. Waiting on Rob.

**2026-10-08** Step 1 built. 60 offline checks pass; 4 new ones cover the tooltip read, the name
read, a cage neither read knows, and a non-pet item ignored.
