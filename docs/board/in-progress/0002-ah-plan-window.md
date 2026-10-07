---
not_for_the_loop: every check is in a live game client
---

# 0002 AH plan window, so no commands need remembering

Rob, 2026-10-07, after the first dry run of card 0001: "I need a UI for this. I'm not going to
remember these commands."

## How it works

- The window opens by itself when an AH character opens the "Anything for Profit" guild bank,
  whether the plan is on or off. It closes with the guild bank.
- Two checkboxes: "Use the AH plan" and "Move items by themselves". The second one is the old
  `ahPlanConfirmed` flag. Off means the list in the window is the dry run, and nothing moves until
  "Move items" is pressed. No dry run goes to chat from the guild bank any more.
- The list shows each move (put in or take out, count, item, before and after), with an item
  tooltip on hover.
- "Move items" runs the engine once and shows progress. "Refresh" asks the guild bank again.
- Other ways in: the options panel button "Open the AH plan window", the bank button's
  right-click menu, and `/dwm ahplanwindow`.
- The window moves by dragging, and from Edit Mode. Escape closes it.
- The bank button's right-click used to pause the session by itself. It now opens a menu (Options,
  AH plan window, Pause or Resume), per Rob's right-click rule.

## Acceptance

- [ ] Opening the guild bank on Buyme shows the window with the same moves the chat dry run showed.
- [ ] "Move items" moves them, the count goes up, and the list empties when done.
- [ ] With "Move items by themselves" ticked, opening the guild bank moves items with no click.
- [ ] Closing the guild bank closes the window and stops any move in progress.
- [ ] The window can be moved in Edit Mode, and the place is kept after /reload.
- [ ] The bank button's right-click opens a menu, and each menu item works.
- [ ] No Lua error on a character that is not in the plan.

## Comments

**2026-10-07** 25 offline checks pass (`lua tests/test_ahplan.lua`), including that a guild bank
visit moves nothing while unconfirmed and that the button path does. The window itself has no
offline check; it uses only Blizzard templates checked against `wow-ui-source` 12.1
(BasicFrameTemplateWithInset, WowScrollBoxList, MinimalScrollBar, UICheckButtonTemplate,
EditModeSystemSelectionTemplate, MenuUtil.CreateContextMenu).

**2026-10-07** Rob's first in-game test: the window showed the right 16 moves, but Move items made
0 moves ("no further progress"). Cause: `C_Bank.IsItemAllowedInBankType(Enum.BankType.Guild, loc)`
answers false for every item; Blizzard only calls it for the character and warband banks. The
guild bank test is now `C_Item.IsBound`. The test fake now behaves like the live client, and 6
checks fail on the old code.
