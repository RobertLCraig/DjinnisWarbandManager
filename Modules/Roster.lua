--[[
    Djinni's Warband Manager - Roster (Phase 2)

    Account-wide character store keyed by player GUID (DESIGN.md S13.13), so the
    roster panel can edit any character and renames/connected realms don't
    orphan a character's purpose/override. Also migrates Phase 1 db.char values.
]]

local ADDON_NAME, ns = ...
local DWM = ns.Addon

local Roster = DWM:NewModule("Roster")
ns.Roster = Roster

-- Stable key for the current character.
function Roster:CurrentKey()
    local guid = UnitGUID("player")
    if guid and guid ~= "" then return guid end
    -- Fallback only if GUID is somehow unavailable this early.
    local n, r = UnitFullName("player")
    if n then return (r and r ~= "" and (n .. "-" .. r)) or n end
    return nil
end

local function Display(rec)
    if not rec then return "?" end
    if rec.realm and rec.realm ~= "" then return rec.name .. " - " .. rec.realm end
    return rec.name or "?"
end
Roster.Display = function(_, rec) return Display(rec) end

-- Ensure (and refresh) the current character's record; migrate Phase 1 data.
function Roster:EnsureCurrent()
    local g = DWM.db.global
    g.characters = g.characters or {}

    local key = self:CurrentKey()
    if not key then return nil end

    local name, realm = UnitFullName("player")
    realm = realm or (GetRealmName and GetRealmName()) or ""
    local _, classFile = UnitClass("player")

    local rec = g.characters[key]
    if not rec then
        rec = {
            purpose        = DWM.db.profile.defaultPurpose or "Default",
            purposeUserSet = false,
            goldOverride   = nil,            -- gold units; nil = use purpose
            managed        = true,
            autoPurpose    = true,
            itemOverrides  = {},             -- reserved for Phase 3
        }
        -- One-time migration of Phase 1 per-character settings.
        local c = DWM.db.char
        if c and c.useDefault == false and type(c.targetGold) == "number" then
            rec.goldOverride = c.targetGold
        end
        g.characters[key] = rec
    end

    rec.guid      = (UnitGUID("player") ~= "" and UnitGUID("player")) or rec.guid
    rec.name      = name or rec.name
    rec.realm     = realm
    rec.classFile = classFile or rec.classFile
    rec.lastSeen  = time()
    return rec, key
end

function Roster:Current()
    local g = DWM.db and DWM.db.global
    if not g or not g.characters then return nil end
    local key = self:CurrentKey()
    return key and g.characters[key] or nil, key
end

-- Sorted list of { key, rec } for the roster panel / `/dwm roster`.
function Roster:All()
    local out = {}
    local g = DWM.db and DWM.db.global
    if not g or not g.characters then return out end
    for k, rec in pairs(g.characters) do
        out[#out + 1] = { key = k, rec = rec }
    end
    table.sort(out, function(a, b)
        return Display(a.rec):lower() < Display(b.rec):lower()
    end)
    return out
end

function Roster:Delete(key)
    local g = DWM.db and DWM.db.global
    if g and g.characters and key ~= self:CurrentKey() then
        g.characters[key] = nil
        return true
    end
    return false
end
