--[[
    Djinni's Warband Manager - AHPlan (card 0001)

    Spreads auction stock across the AH characters. The plan itself is built
    OUTSIDE the game by tools/ahplan/ and shipped as Data/AHPlan.lua
    (ns.AHPlanData); this module only turns it into item targets for the
    current character, which the ItemEngine then balances like any other.

      * A POSTER (an AH character) gets an `exact` target for every planned
        item it holds or should hold: surplus deposits, shortfall withdraws.
      * Anyone else gets nothing from the plan. Storage characters (Pouches,
        Shortnbitter, Jinn) cannot open the transport guild bank, so they
        mail planned items to an AH character on their own realm by hand,
        and that character's plan sends each copy on.

    Deposits go to the transport guild bank only (ItemEngine:BuildPlan), so
    the warband stays storage; withdrawals come from either bank.

    Copies already posted or waiting in the mail count as held (`pending`),
    read from Syndicator, so a posted copy is never replaced by a second one.
    Syndicator moves expired and cancelled auctions into its mail list itself,
    so auctions + mail never double-counts the same copy.
]]

local ADDON_NAME, ns = ...
local DWM = ns.Addon
local L = ns.L

local AHPlan = DWM:NewModule("AHPlan")
ns.AHPlan = AHPlan

local function Data() return ns.AHPlanData end

-- Is a value a 12.1 secret? `type()` cannot tell (workspace DECISIONS.md).
local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) or false
end

-- "Name-NormalizedRealm", the key Syndicator and the plan both use.
-- Returns nil when identity is secret: no key, no plan, nothing moves.
function AHPlan:CurrentFullName()
    if Syndicator and Syndicator.API and Syndicator.API.GetCurrentCharacter then
        local key = Syndicator.API.GetCurrentCharacter()
        if key and not IsSecret(key) then return key end
    end
    if C_Secrets and C_Secrets.ShouldUnitIdentityBeSecret
        and C_Secrets.ShouldUnitIdentityBeSecret("player") then
        return nil
    end
    local name = UnitName("player")
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if not name or not realm or IsSecret(name) or IsSecret(realm) then return nil end
    return name .. "-" .. realm
end

function AHPlan:IsEnabled()
    return DWM.db.profile.ahPlanEnabled and Data() ~= nil
end

-- May the AH plan move items through the guild bank that is open now?
-- Only an AH character, and only in the plan's transport guild: every AH
-- character is a member, so it is the one bank they all share.
function AHPlan:CanUseGuildBank()
    if not self:IsEnabled() or self:Role() ~= "poster" then return false end
    local want = Data().transportGuild
    if not want or not IsInGuild() then return false end
    local ok, guildName = pcall(GetGuildInfo, "player")
    if not ok or not guildName or IsSecret(guildName) then return false end
    return guildName == want
end

-- "poster" | nil for the current character.
function AHPlan:Role()
    local d = Data()
    local me = d and self:CurrentFullName()
    if not me then return nil end
    if d.posters and d.posters[me] then return "poster" end
    return nil
end

-- Every item ID the plan covers, built once from the posters' lists.
local planned
local function PlannedSet()
    if planned then return planned end
    planned = {}
    local d = Data()
    for _, list in pairs((d and d.posters) or {}) do
        for id in pairs(list) do planned[id] = true end
    end
    return planned
end

-- Copies of each item this character has posted or in the mail, per Syndicator.
-- Returns { [itemID] = count } and whether Syndicator data was available.
function AHPlan:PendingCounts()
    local out = {}
    local me = self:CurrentFullName()
    local rec = me and Syndicator and Syndicator.API and Syndicator.API.GetByCharacterFullName
        and Syndicator.API.GetByCharacterFullName(me)
    if not rec then return out, false end
    for _, listName in ipairs({ "auctions", "mail" }) do
        for _, item in pairs(rec[listName] or {}) do
            if type(item) == "table" and item.itemID then
                out[item.itemID] = (out[item.itemID] or 0) + (item.itemCount or 1)
            end
        end
    end
    return out, true
end

-- Item targets for the current character, in the ItemEngine's shape:
-- { [itemID] = { qty, mode, pending, ah = true } }. Only items this character
-- holds, has pending, or should hold, so the engine scans a short list.
function AHPlan:TargetsForCurrent()
    local out = {}
    if not self:IsEnabled() then return out end
    if self:Role() ~= "poster" then return out end
    local mine = Data().posters[self:CurrentFullName()]
    local pending = self:PendingCounts()
    for id in pairs(PlannedSet()) do
        local qty = mine[id] or 0
        local pend = pending[id] or 0
        if qty > 0 or pend > 0 or DWM:GetOnCharacterCount(id) > 0 then
            out[id] = { qty = qty, mode = "exact", pending = pend, ah = true }
        end
    end
    return out
end

-- One chat block: plan age, this character's role, and what it should hold.
function AHPlan:PrintStatus()
    local d = Data()
    if not d then DWM:Print(L["MSG_AHPLAN_NODATA"]); return end
    local me = self:CurrentFullName() or "?"
    local role = self:Role()
    DWM:Print(L["MSG_AHPLAN_STATUS"]:format(
        DWM.db.profile.ahPlanEnabled and L["ON"] or L["OFF"],
        tostring(d.generated or "?"),
        me,
        role and L["AHPLAN_ROLE_" .. role:upper()] or L["AHPLAN_ROLE_NONE"]))
    if role == "poster" then
        local items, copies = 0, 0
        for _, qty in pairs(d.posters[me]) do items = items + 1; copies = copies + qty end
        DWM:Print(L["MSG_AHPLAN_HOLDS"]:format(copies, items))
    end
    if not DWM.db.profile.ahPlanConfirmed then DWM:Print(L["MSG_AHPLAN_UNCONFIRMED"]) end
    local _, haveSyndicator = self:PendingCounts()
    if not haveSyndicator then DWM:Print(L["MSG_AHPLAN_NOSYNDICATOR"]) end
end
