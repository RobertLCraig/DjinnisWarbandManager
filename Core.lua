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
        simulate = false,              -- dry-run: report, never move anything
        itemEnabled = false,           -- items OFF by default (safety, DESIGN S8)
        itemFirstRunConfirmed = false, -- first real item run requires opt-in
        defaultTargetGold = 1000,      -- LEGACY (Phase 1): read once for migration
        defaultPurpose = "Default",
        -- purposes is intentionally NOT in defaults: presets are seeded into
        -- the live profile by Purposes:Seed() so users can delete them without
        -- AceDB resurrecting them. _seeded guards the one-time seed/migration.
        minimap = { hide = false },
    },
    -- Phase 1 per-character fields kept ONLY for one-time migration into the
    -- global roster (Roster:EnsureCurrent). New config lives in db.global.
    char = {
        useDefault = true,
        targetGold = 1000,
    },
    global = {
        characters = {},               -- [GUID] = per-character record
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

-- Texture-free money formatter. GetMoneyString embeds |T coin icons that
-- render as "???" in some chat contexts and do not survive copy/paste, so we
-- emit comma-grouped, colored g/s/c text instead (always readable & copyable).
local function CommaGroup(n)
    local s = tostring(n)
    s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (s:gsub("^,", ""))
end

function DWM:FormatMoney(copper)
    copper = math.floor(tonumber(copper) or 0)
    local neg = copper < 0
    if neg then copper = -copper end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100

    local parts = {}
    if g > 0 then parts[#parts + 1] = "|cffffd700" .. CommaGroup(g) .. "g|r" end
    if g > 0 or s > 0 then parts[#parts + 1] = "|cffc7c7cf" .. s .. "s|r" end
    parts[#parts + 1] = "|cffeda55f" .. c .. "c|r"
    return (neg and "-" or "") .. table.concat(parts, " ")
end

-- Effective target in COPPER for the current character.
-- Returns: copper, source, isMule, purposeName  (delegates to Purposes).
function DWM:GetEffectiveTargetCopper()
    if ns.Purposes and ns.Purposes.ResolveGoldForCurrent then
        return ns.Purposes:ResolveGoldForCurrent()
    end
    local g = (self.db.profile and self.db.profile.defaultTargetGold) or 0
    return math.max(0, math.floor(g)) * 10000, "default", false
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

-- On-character item count: carried bags ONLY. Excludes the character bank,
-- the character REAGENT BANK, and the account/warband bank (DESIGN S13.2 -
-- single patch point so the three banks can never leak into a balance
-- decision). NOTE: the carried reagent *bag* (BagIndex 5) is always part of
-- the base GetItemCount; the 4th arg is the reagent *bank* (character-bank
-- territory) and MUST be false, or keepmin over-deposits.
-- GetItemCount(itemID, includeBank, includeUses, includeReagentBank, includeAccountBank)
function DWM:GetOnCharacterCount(itemID)
    if not itemID then return 0 end
    return C_Item.GetItemCount(itemID, false, false, false, false) or 0
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
    -- Gold first, then items (DESIGN S13.9 deterministic order).
    local ItemEngine = self:GetModule("ItemEngine", true)
    if ItemEngine then ItemEngine:Run("bank-open") end
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
    local ItemEngine = self:GetModule("ItemEngine", true)
    if ItemEngine and ItemEngine.Abort then ItemEngine:Abort("bank-closed") end
    ResetBankState()
end

function DWM:PLAYER_REGEN_DISABLED()
    -- Entering combat: abort any in-flight work and reset (DESIGN S13.14).
    local Balancer = self:GetModule("Balancer", true)
    if Balancer and Balancer.Abort then Balancer:Abort("combat") end
    local ItemEngine = self:GetModule("ItemEngine", true)
    if ItemEngine and ItemEngine.Abort then ItemEngine:Abort("combat") end
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
            local target, _, isMule, pname = DWM:GetEffectiveTargetCopper()
            local rec = ns.Roster and ns.Roster:Current()
            tt:AddDoubleLine(L["STATUS_CHAR_GOLD"]:format(""), DWM:FormatMoney(GetMoney()))
            tt:AddDoubleLine(L["STATUS_WARBAND_GOLD"]:format(""), DWM:FormatMoney(DWM:GetWarbandGold()))
            tt:AddDoubleLine(L["STATUS_PURPOSE"]:format(""), tostring(pname or "?"))
            if isMule then
                tt:AddDoubleLine(L["STATUS_TARGET"]:format(""), L["MULE_LABEL"])
            else
                tt:AddDoubleLine(L["STATUS_TARGET"]:format(""), DWM:FormatMoney(target))
            end
            if rec and rec.managed == false then
                tt:AddLine("|cFFFF8080" .. L["STATUS_UNMANAGED"] .. "|r")
            end
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

    -- Seed purposes + register this character BEFORE options so the panel and
    -- command tree can list purposes and read the current record.
    if ns.Purposes then ns.Purposes:Seed() end
    if ns.Roster then ns.Roster:EnsureCurrent() end

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
    self:RegisterEvent("PLAYER_LOGIN")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    ResetBankState()
end

-- Professions/realm are reliably available by these; refresh the record and
-- run the (guarded) purpose suggestion.
function DWM:PLAYER_LOGIN()
    if ns.Purposes then ns.Purposes:Seed() end
    if ns.Roster then ns.Roster:EnsureCurrent() end
    if ns.ProfessionDetect then ns.ProfessionDetect:Apply() end
    if ns.RefreshOptions then ns.RefreshOptions() end
end

function DWM:PLAYER_ENTERING_WORLD()
    if ns.Roster then ns.Roster:EnsureCurrent() end
end

-- Re-applied when AceDB profile changes (wired in Options.lua). A new profile
-- may have unseeded purposes, so reseed and rebuild the dynamic options.
function DWM:RefreshConfig()
    if ns.Purposes then ns.Purposes:Seed() end
    local icon = LibStub("LibDBIcon-1.0", true)
    if icon then
        if self.db.profile.minimap.hide then icon:Hide(ADDON_NAME) else icon:Show(ADDON_NAME) end
    end
    if ns.RefreshOptions then ns.RefreshOptions() end
end
