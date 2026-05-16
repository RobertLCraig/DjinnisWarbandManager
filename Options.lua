--[[
    Djinni's Warband Manager - Options

    One AceConfig table -> the options panel AND the /dwm command tree
    (AceConfigCmd). Every operation is reachable both ways with no duplicated
    logic (DESIGN.md S4 / S7).
]]

local ADDON_NAME, ns = ...
local DWM = ns.Addon
local L = ns.L

local function P() return DWM.db.profile end
local function C() return DWM.db.char end

local function ParseGold(input)
    local n = tonumber((tostring(input or "")):gsub("[%s,]", ""))
    if not n or n < 0 then return nil end
    return math.floor(n)
end

local function PrintStatus()
    DWM:Print(L["STATUS_HEADER"])
    DWM:Print(L["STATUS_ENABLED"]:format(P().enabled and L["ON"] or L["OFF"]))
    local modeName = ({
        deposit = L["MODE_DEPOSIT"], withdraw = L["MODE_WITHDRAW"], both = L["MODE_BOTH"],
    })[P().mode] or P().mode
    DWM:Print(L["STATUS_MODE"]:format(modeName))
    local target, source = DWM:GetEffectiveTargetCopper()
    local srcTag = (source == "override") and L["STATUS_TARGET_SOURCE_OVERRIDE"]
                                          or L["STATUS_TARGET_SOURCE_DEFAULT"]
    DWM:Print(L["STATUS_TARGET"]:format(DWM:FormatMoney(target)) .. " " .. srcTag)
    DWM:Print(L["STATUS_CHAR_GOLD"]:format(DWM:FormatMoney(GetMoney())))
    DWM:Print(L["STATUS_WARBAND_GOLD"]:format(DWM:FormatMoney(DWM:GetWarbandGold())))
    DWM:Print(L["STATUS_SIMULATE"]:format(P().simulate and L["ON"] or L["OFF"]))
    DWM:Print(L["STATUS_PAUSED"]:format(ns.sessionPaused and L["YES"] or L["NO"]))
end
ns.PrintStatus = PrintStatus

local options = {
    type = "group",
    name = L["ADDON_NAME"],
    args = {
        enabled = {
            type = "toggle", order = 1,
            name = L["OPT_ENABLED_NAME"], desc = L["OPT_ENABLED_DESC"],
            get = function() return P().enabled end,
            set = function(_, v) P().enabled = v end,
        },
        mode = {
            type = "select", order = 2,
            name = L["OPT_MODE_NAME"], desc = L["OPT_MODE_DESC"],
            values = {
                deposit  = L["MODE_DEPOSIT"],
                withdraw = L["MODE_WITHDRAW"],
                both     = L["MODE_BOTH"],
            },
            sorting = { "deposit", "withdraw", "both" },
            get = function() return P().mode end,
            set = function(_, v) P().mode = v end,
        },
        simulate = {
            type = "toggle", order = 3,
            name = L["OPT_SIMULATE_NAME"], desc = L["OPT_SIMULATE_DESC"],
            get = function() return P().simulate end,
            set = function(_, v) P().simulate = v end,
        },
        pause = {
            type = "execute", order = 4,
            name = L["OPT_PAUSE_NAME"], desc = L["OPT_PAUSE_DESC"],
            func = function()
                ns.sessionPaused = not ns.sessionPaused
                DWM:Print(L["STATUS_PAUSED"]:format(ns.sessionPaused and L["YES"] or L["NO"]))
            end,
        },

        gap1 = { type = "header", order = 10, name = L["OPT_THISCHAR"] },

        set = {
            type = "input", order = 11,
            name = L["OPT_CHAR_TARGET_NAME"], desc = L["OPT_CHAR_TARGET_DESC"],
            usage = "<gold>",
            get = function() return tostring(C().targetGold or 0) end,
            validate = function(_, v)
                return ParseGold(v) ~= nil or (L["OPT_CHAR_TARGET_DESC"])
            end,
            set = function(_, v)
                local g = ParseGold(v)
                if not g then return end
                C().targetGold = g
                C().useDefault = false
                DWM:Print(L["MSG_SET_TARGET"]:format(
                    UnitName("player"), DWM:FormatMoney(g * 10000)))
            end,
        },
        usedefault = {
            type = "toggle", order = 12,
            name = L["OPT_CHAR_USEDEFAULT_NAME"], desc = L["OPT_CHAR_USEDEFAULT_DESC"],
            get = function() return C().useDefault end,
            set = function(_, v) C().useDefault = v end,
        },
        clear = {
            type = "execute", order = 13,
            name = L["OPT_CHAR_USEDEFAULT_NAME"],
            desc = L["OPT_CHAR_USEDEFAULT_DESC"],
            func = function()
                C().useDefault = true
                local d = (P().defaultTargetGold or 0) * 10000
                DWM:Print(L["MSG_CLEARED_OVERRIDE"]:format(DWM:FormatMoney(d)))
            end,
        },
        default = {
            type = "input", order = 14,
            name = L["OPT_DEFAULT_TARGET_NAME"], desc = L["OPT_DEFAULT_TARGET_DESC"],
            usage = "<gold>",
            get = function() return tostring(P().defaultTargetGold or 0) end,
            validate = function(_, v)
                return ParseGold(v) ~= nil or (L["OPT_DEFAULT_TARGET_DESC"])
            end,
            set = function(_, v)
                local g = ParseGold(v)
                if g then P().defaultTargetGold = g end
            end,
        },

        gap2 = { type = "header", order = 20, name = L["OPT_GENERAL"] },

        balance = {
            type = "execute", order = 21,
            name = L["OPT_BALANCE_NOW_NAME"], desc = L["OPT_BALANCE_NOW_DESC"],
            func = function()
                local B = DWM:GetModule("Balancer", true)
                if B then B:RunGold("manual") end
            end,
        },
        status = {
            type = "execute", order = 22,
            name = L["OPT_STATUS_NAME"], desc = L["OPT_STATUS_DESC"],
            func = PrintStatus,
        },
    },
}

function ns.SetupOptions()
    local AceConfig = LibStub("AceConfig-3.0")
    local AceConfigDialog = LibStub("AceConfigDialog-3.0")
    local AceConfigCmd = LibStub("AceConfigCmd-3.0")

    -- Profiles tab (AceDB import/copy/reset for free).
    options.args.profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(DWM.db)
    options.args.profiles.order = 30

    AceConfig:RegisterOptionsTable(ADDON_NAME, options)
    AceConfigDialog:AddToBlizOptions(ADDON_NAME, L["ADDON_NAME"])

    -- /dwm with no args (or options/config) opens the GUI; anything else is
    -- handled by AceConfigCmd against the same table.
    DWM:RegisterChatCommand("dwm", function(input)
        input = input and input:trim() or ""
        if input == "" or input == "options" or input == "config" then
            AceConfigDialog:Open(ADDON_NAME)
        elseif input == "help" or input == "?" then
            DWM:Print(L["CMD_HELP_HEADER"])
            DWM:Print(L["CMD_HELP_OPTIONS"]); DWM:Print(L["CMD_HELP_SET"])
            DWM:Print(L["CMD_HELP_CLEAR"]);   DWM:Print(L["CMD_HELP_MODE"])
            DWM:Print(L["CMD_HELP_ENABLE"]);  DWM:Print(L["CMD_HELP_SIMULATE"])
            DWM:Print(L["CMD_HELP_PAUSE"]);   DWM:Print(L["CMD_HELP_BALANCE"])
            DWM:Print(L["CMD_HELP_STATUS"])
        else
            AceConfigCmd.HandleCommand(DWM, "dwm", ADDON_NAME, input)
        end
    end)

    -- Keep minimap button / config in sync with profile switches.
    DWM.db.RegisterCallback(DWM, "OnProfileChanged", "RefreshConfig")
    DWM.db.RegisterCallback(DWM, "OnProfileCopied", "RefreshConfig")
    DWM.db.RegisterCallback(DWM, "OnProfileReset", "RefreshConfig")
end
