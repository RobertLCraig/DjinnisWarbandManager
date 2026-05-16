--[[
    Djinni's Warband Manager - Purposes (Phase 2)

    Character "purpose" drives the gold (later item) target instead of rigid
    level brackets. Presets are SEEDED into the live profile (not AceDB
    defaults) so users can delete them without AceDB resurrecting them.

    Resolution (DESIGN.md S4): explicit per-character override -> character's
    purpose -> profile default purpose. Identical chain will extend to items.
]]

local ADDON_NAME, ns = ...
local DWM = ns.Addon

local Purposes = DWM:NewModule("Purposes")
ns.Purposes = Purposes

-- Preset purposes. gold is in gold units. items reserved for Phase 3.
-- 38682 = Enchanting Vellum (keep >=500 on Crafters) - inert until Phase 3.
local PRESETS = {
    { name = "Default",  gold = 1000 },
    { name = "Raider",   gold = 50000 },
    { name = "Mythic",   gold = 30000 },
    -- Vellum uses "exact": a Crafter should be topped back up to 500 from the
    -- warband when low (the original "always have at least 500" requirement),
    -- not merely have surplus skimmed. keepmin never withdraws by design.
    { name = "Crafter",  gold = 20000, items = { [38682] = { qty = 500, mode = "exact" } } },
    { name = "Gatherer", gold = 10000 },
    { name = "Leveling", gold = 2000 },
    { name = "Mule",     gold = 0, mule = true },
    -- Banker/Auctioneer: a large working float for AH buyouts/posting. Not a
    -- Mule (it keeps a bounded target, it doesn't drain the warband bank).
    { name = "Banker/Auctioneer", gold = 250000 },
}

-- Seed presets and migrate the Phase 1 profile.defaultTargetGold.
-- Per-preset tracking (_seededPresets) is forward-safe: a NEW preset added in
-- a later version reaches existing profiles, but a preset the user deletes is
-- NOT resurrected (the AceDB-defaults gotcha we set out to avoid).
function Purposes:Seed()
    local p = DWM.db.profile
    p.purposes = p.purposes or {}
    p._seededPresets = p._seededPresets or {}

    for _, preset in ipairs(PRESETS) do
        if not p._seededPresets[preset.name] then
            if p.purposes[preset.name] == nil then
                local entry = { gold = preset.gold }
                if preset.mule then entry.mule = true end
                if preset.items then
                    entry.items = {}
                    for id, spec in pairs(preset.items) do
                        entry.items[id] = { qty = spec.qty, mode = spec.mode }
                    end
                end
                p.purposes[preset.name] = entry
            end
            p._seededPresets[preset.name] = true
        end
    end

    -- One-time Phase 1 -> Phase 2: carry the old global default into "Default".
    if not p._seeded then
        if type(p.defaultTargetGold) == "number" and p.purposes.Default then
            p.purposes.Default.gold = p.defaultTargetGold
        end
        p._seeded = true
    end

    p.defaultPurpose = p.defaultPurpose or "Default"
    if not p.purposes[p.defaultPurpose] then
        -- Default purpose was deleted; fall back to any existing one.
        p.defaultPurpose = next(p.purposes) or "Default"
        p.purposes[p.defaultPurpose] = p.purposes[p.defaultPurpose] or { gold = 0 }
    end
end

function Purposes:Names()
    local p = DWM.db.profile.purposes or {}
    local names = {}
    for name in pairs(p) do names[#names + 1] = name end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

function Purposes:Get(name) return DWM.db.profile.purposes[name] end

function Purposes:Add(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return false, "empty" end
    if DWM.db.profile.purposes[name] then return false, "exists" end
    DWM.db.profile.purposes[name] = { gold = 0 }
    return true
end

function Purposes:Delete(name)
    local p = DWM.db.profile
    if not p.purposes[name] then return false, "missing" end
    if name == p.defaultPurpose then return false, "isdefault" end
    p.purposes[name] = nil
    -- Reassign any characters that pointed at the deleted purpose.
    local g = DWM.db.global
    if g and g.characters then
        for _, rec in pairs(g.characters) do
            if rec.purpose == name then rec.purpose = p.defaultPurpose end
        end
    end
    return true
end

function Purposes:SetGold(name, gold)
    local e = DWM.db.profile.purposes[name]
    if not e then return false end
    e.gold = math.max(0, math.floor(tonumber(gold) or 0))
    return true
end

function Purposes:SetMule(name, on)
    local e = DWM.db.profile.purposes[name]
    if not e then return false end
    e.mule = on and true or nil
    return true
end

--============================================================================
-- Item targets (Phase 3). spec = { qty = <n>, mode = "keepmin"|"exact"|"depositall" }
--============================================================================

local VALID_MODES = { keepmin = true, exact = true, depositall = true }

function Purposes:SetItem(purposeName, itemID, qty, mode)
    local e = DWM.db.profile.purposes[purposeName]
    if not e then return false, "missing" end
    itemID = tonumber(itemID)
    if not itemID then return false, "baditem" end
    mode = VALID_MODES[mode] and mode or "keepmin"
    qty = math.max(0, math.floor(tonumber(qty) or 0))
    e.items = e.items or {}
    e.items[itemID] = { qty = qty, mode = mode }
    return true
end

function Purposes:DelItem(purposeName, itemID)
    local e = DWM.db.profile.purposes[purposeName]
    if not e or not e.items then return false end
    e.items[tonumber(itemID) or -1] = nil
    return true
end

-- Merged item targets for ANY roster record (§14.2):
-- the record's purpose.items, then its itemOverrides win (false = unmanage).
-- Returns { [itemID] = { qty, mode } }
function Purposes:ResolveItemsFor(rec)
    local prof = DWM.db.profile
    local out  = {}
    if not rec then return out end

    local pname = rec.purpose or prof.defaultPurpose
    local p = prof.purposes[pname] or prof.purposes[prof.defaultPurpose]
    if p and p.items then
        for id, spec in pairs(p.items) do
            out[id] = { qty = spec.qty or 0, mode = spec.mode or "keepmin" }
        end
    end
    if rec.itemOverrides then
        for id, spec in pairs(rec.itemOverrides) do
            if spec == false then
                out[id] = nil                       -- explicitly unmanaged here
            elseif type(spec) == "table" then
                out[id] = { qty = spec.qty or 0, mode = spec.mode or "keepmin" }
            end
        end
    end
    return out
end

-- Thin wrapper: targets for the current character (unchanged callers).
function Purposes:ResolveItemsForCurrent()
    return self:ResolveItemsFor(ns.Roster and ns.Roster:Current())
end

-- Every itemID referenced by any purpose or any character override (§14.2).
-- Returns a set { [itemID] = true }.
function Purposes:AllManagedItemIDs()
    local set = {}
    for _, p in pairs(DWM.db.profile.purposes or {}) do
        if p.items then for id in pairs(p.items) do set[id] = true end end
    end
    local g = DWM.db.global and DWM.db.global.characters
    if g then
        for _, rec in pairs(g) do
            if rec.itemOverrides then
                for id, spec in pairs(rec.itemOverrides) do
                    if spec ~= false then set[id] = true end
                end
            end
        end
    end
    return set
end

-- Resolve the current character's gold target.
-- Returns: copperTarget, source, isMule, purposeName
--   source in: "override" | "purpose" | "mule" | "default" | "none"
function Purposes:ResolveGoldForCurrent()
    local prof = DWM.db.profile
    local rec  = ns.Roster and ns.Roster:Current()

    if rec and type(rec.goldOverride) == "number" then
        return math.max(0, math.floor(rec.goldOverride)) * 10000, "override", false
    end

    local pname = (rec and rec.purpose) or prof.defaultPurpose or "Default"
    local entry = prof.purposes[pname]
    local usedDefault = false
    if not entry then
        pname = prof.defaultPurpose or "Default"
        entry = prof.purposes[pname]
        usedDefault = true
    end
    if not entry then return 0, "none", false, pname end
    if entry.mule then return 0, "mule", true, pname end
    return math.max(0, math.floor(entry.gold or 0)) * 10000,
           usedDefault and "default" or "purpose", false, pname
end
