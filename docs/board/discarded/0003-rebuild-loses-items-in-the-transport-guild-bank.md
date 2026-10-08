---
not_for_the_loop: needs Rob's live saved data and a guild bank visit to check
---

# 0003 A plan rebuild loses the items waiting in the transport guild bank

On 2026-10-08 a rebuild (`tools/ahplan/build.ps1`) read Syndicator's copy of "Anything for
Profit-Ghostlands" as 6 tabs with 0 items, although Buyme had put 42 planned items into it the day
before (seen on screen). The new plan therefore gave those 42 items to nobody, so no AH character
would withdraw them. The rebuild was thrown away and the 2026-10-07 plan kept.

## Why it matters

The transport guild bank always holds items in transit between a deposit on one character and the
withdraw on another. Any rebuild between those two visits drops them, unless the build can see the
guild bank.

## To find out

- Does Syndicator record a guild bank tab only when it is clicked in the guild bank window, or also
  on `QueryGuildBankTab`? Check Syndicator's source in the AddOns folder.
- If it needs a click, the AH plan window could query and show each tab, or DWM could save its own
  scan of the transport guild bank (it already scans every tab in `ItemEngine` `ScanGuild`).

## Acceptance

- [ ] After a guild bank visit and a logout, a rebuild shows the items in the transport guild bank
      in `2-post-from-storage.csv` (or plans them to an AH character).
- [ ] `build.ps1` warns when the transport guild bank reads as empty.

## Comments

**2026-10-08** Discarded: the premise was wrong. Rob had already withdrawn and posted the 42 items
on What, Loamint and Hotwheel, and Syndicator's saved data shows them there (What 43, Loamint 20,
Hotwheel 4 posted copies of those items). The guild bank really was empty. The rebuild was kept.
