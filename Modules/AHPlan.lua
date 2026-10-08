--[[
    Djinni's Warband Manager - AHPlan (cards 0001, 0004)

    Spreads auction stock across the AH characters. The plan itself is built
    OUTSIDE the game by tools/ahplan/ and shipped as Data/AHPlan.lua
    (ns.AHPlanData); this module only turns it into item targets for the
    current character, which the ItemEngine then balances like any other.

      * A POSTER (an AH character) gets an `exact` target for every planned
        item it holds or should hold: surplus deposits, shortfall withdraws.
      * A FEEDER (card 0004) empties a storage guild bank that no AH character
        can open: at that guild bank it takes out the planned copies, and at
        the warband bank it puts them in. The AH characters then withdraw them
        from the warband bank like any other planned copy. Jinn feeds from
        Transmog DOESNT Sell, Pouches from Storinator.
      * Anyone else gets nothing from the plan.

    A feeder's progress is saved account-wide (db.global.ahFeed), per plan
    build, so a copy already taken out and sold is never taken out again.

    Posters deposit into the transport guild bank only (ItemEngine:BuildPlan),
    so the warband takes only what a feeder brings; withdrawals come from
    either bank.

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

-- "poster" | "feeder" | nil for the current character.
function AHPlan:Role()
    local d = Data()
    local me = d and self:CurrentFullName()
    if not me then return nil end
    if d.posters and d.posters[me] then return "poster" end
    if d.feeders and d.feeders[me] then return "feeder" end
    return nil
end

-- The guild bank this character's role uses: the transport guild for a
-- poster, its storage guild for a feeder.
function AHPlan:RoleGuild()
    local d, role = Data(), self:Role()
    if role == "poster" then return d.transportGuild end
    if role == "feeder" then return d.feeders[self:CurrentFullName()].guild end
end

-- The role, if this character's guild is the one its role uses, whether or
-- not the plan is on. The AH plan window shows at the guild bank on this
-- test, so the plan can be switched on from there.
function AHPlan:GuildRole()
    local want = self:RoleGuild()
    if not want or not IsInGuild() then return nil end
    local ok, guildName = pcall(GetGuildInfo, "player")
    if not ok or not guildName or IsSecret(guildName) then return nil end
    if guildName ~= want then return nil end
    return self:Role()
end

-- May the AH plan move items through the guild bank that is open now?
function AHPlan:CanUseGuildBank()
    return self:IsEnabled() and self:GuildRole() ~= nil
end

--============================================================================
-- Feeder progress (card 0004)
--============================================================================

-- { [itemID] = copies taken out } for the plan now loaded. A new plan build
-- starts from zero: the build already counts what is left in the guild bank.
local function FeedState()
    local g = DWM.db.global
    local gen = Data() and Data().generated or "?"
    if not g.ahFeed or g.ahFeed.plan ~= gen then g.ahFeed = { plan = gen, pulled = {} } end
    return g.ahFeed.pulled
end

function AHPlan:Pulled(itemID) return FeedState()[itemID] or 0 end

function AHPlan:AddPulled(itemID, n)
    local p = FeedState()
    p[itemID] = math.max(0, (p[itemID] or 0) + n)
end

--============================================================================
-- Summary and targets
--============================================================================

-- Plan date, this character, its role, and what it should hold or take out.
function AHPlan:Summary()
    local d = Data()
    if not d then return nil end
    local me = self:CurrentFullName()
    local role = self:Role()
    local s = { generated = d.generated, me = me, role = role, guild = self:RoleGuild() or d.transportGuild,
                poster = role == "poster", items = 0, copies = 0, pulled = 0 }
    if role == "poster" then
        for _, qty in pairs(d.posters[me]) do s.items = s.items + 1; s.copies = s.copies + qty end
    elseif role == "feeder" then
        for id, qty in pairs(d.feeders[me].items or {}) do
            s.items = s.items + 1; s.copies = s.copies + qty
            s.pulled = s.pulled + math.min(qty, self:Pulled(id))
        end
    end
    return s
end

-- Every item ID the plan covers, built once from the posters' lists.
local planned, plannedFrom
local function PlannedSet()
    local d = Data()
    local stamp = d and d.posters
    if planned and plannedFrom == stamp then return planned end
    planned, plannedFrom = {}, stamp
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
                -- A caged pet counts under its species key (card 0006).
                local key = item.itemID
                local species = key == ns.PET_CAGE and item.itemLink
                    and tonumber(item.itemLink:match("battlepet:(%d+)"))
                if species then key = -species end
                out[key] = (out[key] or 0) + (item.itemCount or 1)
            end
        end
    end
    return out, true
end

-- Item targets for the current character, in the ItemEngine's shape:
-- poster  { [itemID] = { qty, mode = "exact", pending, ah = true } }
-- feeder  { [itemID] = { qty = 0, mode = "feed", remaining, ah = true, feed = true, bagFeed } }
-- A caged pet's key is -species (Core.lua ns.SlotKey).
-- Only items this character holds, has pending, or should hold or take out,
-- so the engine scans a short list.
function AHPlan:TargetsForCurrent()
    local out = {}
    if not self:IsEnabled() then return out end
    local role = self:Role()
    if role == "feeder" then
        local f = Data().feeders[self:CurrentFullName()]
        for id, n in pairs(f.items or {}) do
            local remaining = math.max(0, n - self:Pulled(id))
            if remaining > 0 or (not f.bags and DWM:GetOnCharacterCount(id) > 0) then
                -- bags: the stock is in this character's own bags (Lostpets'
                -- pets, card 0006), so only the planned copies go in.
                out[id] = { qty = 0, mode = "feed", remaining = remaining, ah = true, feed = true,
                            bagFeed = f.bags or nil }
            end
        end
        return out
    end
    if role ~= "poster" then return out end
    local mine = Data().posters[self:CurrentFullName()]
    local pending = self:PendingCounts()
    -- Every planned item, even one planned only for another poster: a copy
    -- of it in the warband bank must still come out (Rob, 2026-10-08).
    for id in pairs(PlannedSet()) do
        out[id] = { qty = mine[id] or 0, mode = "exact", pending = pending[id] or 0, ah = true }
    end
    return out
end

-- One chat block: plan age, this character's role, and what it should hold.
function AHPlan:PrintStatus()
    local s = self:Summary()
    if not s then DWM:Print(L["MSG_AHPLAN_NODATA"]); return end
    DWM:Print(L["MSG_AHPLAN_STATUS"]:format(
        DWM.db.profile.ahPlanEnabled and L["ON"] or L["OFF"],
        tostring(s.generated or "?"),
        s.me or "?",
        s.role and L["AHPLAN_ROLE_" .. s.role:upper()] or L["AHPLAN_ROLE_NONE"]))
    if s.role == "poster" then
        DWM:Print(L["MSG_AHPLAN_HOLDS"]:format(s.copies, s.items))
    elseif s.role == "feeder" then
        DWM:Print(L["MSG_AHPLAN_FEEDS"]:format(s.copies, s.items, s.guild or "?", s.pulled))
    end
    if not DWM.db.profile.ahPlanConfirmed then DWM:Print(L["MSG_AHPLAN_UNCONFIRMED"]) end
    local _, haveSyndicator = self:PendingCounts()
    if not haveSyndicator and s.role == "poster" then DWM:Print(L["MSG_AHPLAN_NOSYNDICATOR"]) end
end
