local L = LibStub("AceLocale-3.0"):NewLocale("DjinnisWarbandManager", "enUS", true)
if not L then return end

-- Addon / chrome
L["ADDON_NAME"] = "Djinni's Warband Manager"
L["BROKER_TOOLTIP_TITLE"] = "Djinni's Warband Manager"
L["BROKER_LEFT_CLICK"] = "Left-click: open options"
L["BROKER_RIGHT_CLICK"] = "Right-click: pause/resume for this session"

-- Status
L["STATUS_HEADER"] = "Djinni's Warband Manager status"
L["STATUS_ENABLED"] = "Gold balancing: %s"
L["STATUS_MODE"] = "Mode: %s"
L["STATUS_TARGET"] = "This character's gold target: %s"
L["STATUS_TARGET_SOURCE_OVERRIDE"] = "(per-character override)"
L["STATUS_TARGET_SOURCE_DEFAULT"] = "(profile default)"
L["STATUS_CHAR_GOLD"] = "On character: %s"
L["STATUS_WARBAND_GOLD"] = "In warband bank: %s"
L["STATUS_PAUSED"] = "Paused for this session: %s"
L["STATUS_SIMULATE"] = "Simulate (dry-run) mode: %s"
L["ON"] = "on"
L["OFF"] = "off"
L["YES"] = "yes"
L["NO"] = "no"

-- Modes
L["MODE_DEPOSIT"] = "Deposit only"
L["MODE_WITHDRAW"] = "Withdraw only"
L["MODE_BOTH"] = "Both (maintain target)"

-- Messages
L["MSG_DEPOSITED"] = "Deposited %s to the warband bank."
L["MSG_WITHDREW"] = "Withdrew %s from the warband bank."
L["MSG_NOTHING"] = "Gold already at target; nothing to do."
L["MSG_SIM_DEPOSIT"] = "[Simulate] Would deposit %s to the warband bank."
L["MSG_SIM_WITHDRAW"] = "[Simulate] Would withdraw %s from the warband bank."
L["MSG_SIM_NOTHING"] = "[Simulate] Gold already at target; would do nothing."
L["MSG_NO_WARBAND"] = "Warband bank is not available (not purchased, or not reachable here)."
L["MSG_WITHDRAW_SHORT"] = "Warband bank has only %s; withdrawing that."
L["MSG_DEPOSIT_CAP"] = "Warband bank gold cap reached; deposited what fit (%s)."
L["MSG_PAUSED_SKIP"] = "Paused for this session - skipping automatic balancing."
L["MSG_SET_TARGET"] = "Gold target for %s set to %s."
L["MSG_CLEARED_OVERRIDE"] = "Cleared this character's gold override; now using the profile default (%s)."
L["MSG_DEPOSIT_FAILED"] = "Deposit did not complete (the bank may be busy); will retry next bank visit."
L["MSG_WITHDRAW_FAILED"] = "Withdraw did not complete (the bank may be busy); will retry next bank visit."

-- Options: groups
L["OPT_GENERAL"] = "General"
L["OPT_THISCHAR"] = "This Character"
L["OPT_PROFILES"] = "Profiles"

-- Options: fields
L["OPT_ENABLED_NAME"] = "Enable gold balancing"
L["OPT_ENABLED_DESC"] = "Automatically move gold to/from the warband bank when you visit a banker."
L["OPT_MODE_NAME"] = "Mode"
L["OPT_MODE_DESC"] = "Deposit only, withdraw only, or both (maintain the target exactly)."
L["OPT_SIMULATE_NAME"] = "Simulate (dry-run)"
L["OPT_SIMULATE_DESC"] = "Report what would happen without moving any gold. Use this to verify behavior safely."
L["OPT_PAUSE_NAME"] = "Pause for this session"
L["OPT_PAUSE_DESC"] = "Temporarily stop automatic balancing until you reload or relog."
L["OPT_DEFAULT_TARGET_NAME"] = "Default gold target"
L["OPT_DEFAULT_TARGET_DESC"] = "Gold (in gold, not copper) to keep on a character that has no per-character override."
L["OPT_CHAR_TARGET_NAME"] = "This character's gold target"
L["OPT_CHAR_TARGET_DESC"] = "Override the default for this character only. Leave empty to use the profile default."
L["OPT_CHAR_USEDEFAULT_NAME"] = "Use profile default for this character"
L["OPT_CHAR_USEDEFAULT_DESC"] = "When checked, this character follows the profile default instead of its own override."
L["OPT_BALANCE_NOW_NAME"] = "Balance now"
L["OPT_BALANCE_NOW_DESC"] = "Run a balancing pass immediately (only works while a banker is open)."
L["OPT_STATUS_NAME"] = "Print status"
L["OPT_STATUS_DESC"] = "Print the current configuration and gold figures to chat."

-- Command help
L["CMD_HELP_HEADER"] = "Djinni's Warband Manager commands:"
L["CMD_HELP_OPTIONS"] = "/dwm options - open the options panel"
L["CMD_HELP_SET"] = "/dwm set <gold> - set this character's gold target"
L["CMD_HELP_CLEAR"] = "/dwm clear - clear this character's override (use profile default)"
L["CMD_HELP_MODE"] = "/dwm mode deposit|withdraw|both - set the mode"
L["CMD_HELP_ENABLE"] = "/dwm enable on|off - toggle gold balancing"
L["CMD_HELP_SIMULATE"] = "/dwm simulate on|off - toggle dry-run mode"
L["CMD_HELP_PAUSE"] = "/dwm pause - pause/resume for this session"
L["CMD_HELP_BALANCE"] = "/dwm balance - balance now (at a banker)"
L["CMD_HELP_STATUS"] = "/dwm status - print status"
