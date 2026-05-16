--[[
    Djinni's Warband Manager - Core
    Phase 1: gold balancing toward a per-character target.

    Bank-ready state machine (DESIGN.md S13.1): we only act when the warband
    bank is genuinely usable, not merely when a banker frame showed.
]]

local ADDON_NAME, ns = ...

local DWM = LibStub("AceAddon-3.0"):NewAddon(
    ADDON_NAME, "AceConsole-3.0", "AceEvent-3.0", "AceTimer-3.0"
)
ns.Addon = DWM
_G.DjinnisWarbandManager = DWM

local L = LibStub("AceLocale-3.0"):GetLocale(ADDON_NAME)
ns.L = L

--============================================================================
-- Constants (reference Enum directly; cache with documented fallbacks)
--============================================================================

local BANKTYPE_ACCOUNT = (Enum and Enum.BankType and Enum.BankType.Account) or 2
local INTERACT_ACCOUNT_BANKER =
    (Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.AccountBanker) or 68

ns.BANKTYPE_ACCOUNT = BANKTYPE_ACCOUNT

--============================================================================
-- Saved variables
--============================================================================

local defaults = {
    profile = {
        enabled = true,
        mode = "both",                 -- "deposit" | "withdraw" | "both"
        simulate = false,              -- dry-run: report, never move gold
        defaultTargetGold = 1000,      -- gold units (not copper)
        minimap = { hide = false },
    },
    char = {
        useDefault = true,             -- follow profile default unless overridden
        targetGold = 1000,             -- gold units; used when useDefault == false
    },
}

--============================================================================
-- Session-only state
--============================================================================

ns.sessionPaused = false
ns.bankState = "closed"               -- "closed" | "opening" | "ready"

local sawAccountBanker = false
local uiReady = false
local ranThisOpen = false

--============================================================================
-- Helpers
--============================================================================

function DWM:FormatMoney(copper)
    -- GetMoneyString is a current retail global; avoids hand-rolled formatting.
    if GetMoneyString then return GetMoneyString(copper or 0, true) end
    return tostring(math.floor((copper or 0) / 10000)) .. "g"
end

-- Effective target in COPPER for the current character, plus a source tag.
function DWM:GetEffectiveTargetCopper()
    local c = self.db.char
    if c and not c.useDefault and type(c.targetGold) == "number" then
        return math.max(0, math.floor(c.targetGold)) * 10000, "override"
    end
    local g = (self.db.profile and self.db.profile.defaultTargetGold) or 0
    return math.max(0, math.floor(g)) * 10000, "default"
end

-- Is the warband bank actually usable right now (Phase 1: for gold)?
function DWM:IsWarbandUsable()
    if not C_Bank then return false end
    if C_Bank.CanUseBank and not C_Bank.CanUseBank(BANKTYPE_ACCOUNT) then return false end
    -- The warband bank is only "unlocked" once the first tab is purchased;
    -- this also doubles as the stability signal from DESIGN S13.1.
    if C_Bank.FetchNumPurchasedBankTabs then
        local n = C_Bank.FetchNumPurchasedBankTabs(BANKTYPE_ACCOUNT)
        if not n or n < 1 then return false end
    end
    return true
end

function DWM:GetWarbandGold()
    if C_Bank and C_Bank.FetchDepositedMoney then
        return C_Bank.FetchDepositedMoney(BANKTYPE_ACCOUNT) or 0
    end
    return 0
end

-- Override AceConsole's Print with a tidy colored prefix.
function DWM:Print(msg)
    print("|cFF4FC3F7" .. L["ADDON_NAME"] .. ":|r " .. tostring(msg))
end

--============================================================================
-- Bank-ready state machine (DESIGN.md S13.1 / S13.14)
--============================================================================

local function ResetBankState()
    ns.bankState = "closed"
    sawAccountBanker = false
    uiReady = false
    ranThisOpen = false
end

function DWM:_TryTransitionReady()
    if ns.bankState == "ready" then return end
    if not sawAccountBanker then return end
    if not uiReady then return end
    if not self:IsWarbandUsable() then return end

    ns.bankState = "ready"
    if ranThisOpen then return end
    ranThisOpen = true

    if not self.db.profile.enabled then return end
    if ns.sessionPaused then
        self:Print(L["MSG_PAUSED_SKIP"])
        return
    end
    local Balancer = self:GetModule("Balancer", true)
    if Balancer then Balancer:RunGold("bank-open") end
end

function DWM:PLAYER_INTERACTION_MANAGER_FRAME_SHOW(_, interactionType)
    if interactionType == INTERACT_ACCOUNT_BANKER then
        sawAccountBanker = true
        if ns.bankState == "closed" then ns.bankState = "opening" end
        self:_TryTransitionReady()
    end
end

function DWM:PLAYER_INTERACTION_MANAGER_FRAME_HIDE(_, interactionType)
    if interactionType == INTERACT_ACCOUNT_BANKER then
        ResetBankState()
    end
end

function DWM:BANKFRAME_OPENED()
    uiReady = true
    if ns.bankState == "closed" then ns.bankState = "opening" end
    self:_TryTransitionReady()
end

function DWM:BANKFRAME_CLOSED()
    ResetBankState()
end

function DWM:PLAYER_REGEN_DISABLED()
    -- Entering combat: abort any in-flight work and reset (DESIGN S13.14).
    local Balancer = self:GetModule("Balancer", true)
    if Balancer and Balancer.Abort then Balancer:Abort("combat") end
    ResetBankState()
end

--============================================================================
-- LDB / minimap
--============================================================================

local function BuildBroker()
    local ldb = LibStub("LibDataBroker-1.1", true)
    if not ldb then return end

    local obj = ldb:NewDataObject(ADDON_NAME, {
        type = "data source",
        text = L["ADDON_NAME"],
        icon = "Interface\\Icons\\achievement_guildperk_mobilebanking",
        OnClick = function(_, button)
            if button == "RightButton" then
                ns.sessionPaused = not ns.sessionPaused
                DWM:Print(string.format(L["STATUS_PAUSED"],
                    ns.sessionPaused and L["YES"] or L["NO"]))
            else
                LibStub("AceConfigDialog-3.0"):Open(ADDON_NAME)
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine(L["BROKER_TOOLTIP_TITLE"])
            local target = DWM:GetEffectiveTargetCopper()
            tt:AddDoubleLine(L["STATUS_CHAR_GOLD"]:format(""), DWM:FormatMoney(GetMoney()))
            tt:AddDoubleLine(L["STATUS_WARBAND_GOLD"]:format(""), DWM:FormatMoney(DWM:GetWarbandGold()))
            tt:AddDoubleLine(L["STATUS_TARGET"]:format(""), DWM:FormatMoney(target))
            tt:AddLine(" ")
            tt:AddLine("|cFFAAAAAA" .. L["BROKER_LEFT_CLICK"] .. "|r")
            tt:AddLine("|cFFAAAAAA" .. L["BROKER_RIGHT_CLICK"] .. "|r")
        end,
    })

    local icon = LibStub("LibDBIcon-1.0", true)
    if icon and obj then
        icon:Register(ADDON_NAME, obj, DWM.db.profile.minimap)
    end
end

--============================================================================
-- Lifecycle
--============================================================================

function DWM:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("DjinnisWarbandManagerDB", defaults, true)
    ns.db = self.db

    -- Options.lua registers the AceConfig table + slash commands at file load.
    if ns.SetupOptions then ns.SetupOptions() end

    BuildBroker()
end

function DWM:OnEnable()
    self:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
    self:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
    self:RegisterEvent("BANKFRAME_OPENED")
    self:RegisterEvent("BANKFRAME_CLOSED")
    self:RegisterEvent("PLAYER_REGEN_DISABLED")
    ResetBankState()
end

-- Re-applied when AceDB profile changes (wired in Options.lua).
function DWM:RefreshConfig()
    local icon = LibStub("LibDBIcon-1.0", true)
    if icon then
        if self.db.profile.minimap.hide then icon:Hide(ADDON_NAME) else icon:Show(ADDON_NAME) end
    end
end
