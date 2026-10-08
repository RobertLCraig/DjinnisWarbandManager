--[[
    PetScan (card 0006, step 1): which battle pet sits in each guild bank cage.

    A caged pet in a guild bank comes back from GetGuildBankItemLink as a plain
    Pet Cage (item 82800) with no species. Syndicator recovers the species from
    C_TooltipInfo.GetGuildBankItem, but on 2026-10-08 it had saved no species
    for any guild bank on Rob's account, so the AH plan builder cannot price
    those pets. This module tries three reads on every caged slot of the tab on
    screen and keeps what works:

      link     a battlepet: link, if the game gives one
      tooltip  C_TooltipInfo.GetGuildBankItem(tab, slot).battlePetSpeciesID,
               the field TooltipDataRules.BattlePet reads
      name     the tooltip's first line through C_PetJournal.FindPetIDByName,
               as Blizzard's /summonpet does (no level or quality this way)

    Saved per guild in db.global.petScan[guild] = { realm, at,
    tabs = { [tab] = { [slot] = { species, level, quality, how } } } }.
    A tab is recorded when it is on screen, so open each tab once.
    `/dwm pets` reports what is known.
]]

local ADDON_NAME, ns = ...
local DWM = ns.Addon
local L = ns.L

local PetScan = DWM:NewModule("PetScan", "AceEvent-3.0")
ns.PetScan = PetScan

local PET_CAGE = 82800
local SLOTS_PER_TAB = 98   -- a local in Blizzard_GuildBankUI.lua, not a global

-- Is a value a 12.1 secret? `type()` cannot tell (workspace DECISIONS.md).
local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) or false
end

-- A plain number we may use as a table key, or nil.
local function Num(v)
    if v == nil or IsSecret(v) then return nil end
    v = tonumber(v)
    if v and v > 0 then return v end
end

local function GuildName()
    if not IsInGuild() then return nil end
    local ok, name = pcall(GetGuildInfo, "player")
    if not ok or not name or IsSecret(name) then return nil end
    return name
end

-- species, level, quality, how; nil when no read worked.
function PetScan:ReadSlot(tab, slot, link)
    local s, lv, q = link:match("battlepet:(%d+):(%d+):(%d+)")
    if Num(s) then return Num(s), Num(lv) or 0, Num(q) or 0, "link" end

    local data = C_TooltipInfo and C_TooltipInfo.GetGuildBankItem
        and C_TooltipInfo.GetGuildBankItem(tab, slot)
    if not data then return nil end
    local species = Num(data.battlePetSpeciesID)
    if species then
        return species, Num(data.battlePetLevel) or 0, Num(data.battlePetBreedQuality) or 0, "tooltip"
    end

    local line = data.lines and data.lines[1]
    local name = line and line.leftText
    if name and not IsSecret(name) and C_PetJournal and C_PetJournal.FindPetIDByName then
        local found = Num((C_PetJournal.FindPetIDByName(name)))
        if found then return found, 0, 0, "name" end
    end
    return nil
end

-- Record every caged pet on the guild bank tab on screen.
function PetScan:ScanCurrentTab()
    local guild = GuildName()
    local tab = GetCurrentGuildBankTab and GetCurrentGuildBankTab()
    if not guild or not tab then return end
    local g = DWM.db.global.petScan or {}
    DWM.db.global.petScan = g
    local rec = g[guild] or { tabs = {} }
    g[guild] = rec
    rec.realm = GetNormalizedRealmName and GetNormalizedRealmName() or rec.realm
    rec.at = time()

    local slots, any = {}, false
    for slot = 1, SLOTS_PER_TAB do
        local link = GetGuildBankItemLink(tab, slot)
        if link and not IsSecret(link) then
            local id = C_Item.GetItemInfoInstant(link)
            if id == PET_CAGE or link:find("battlepet:", 1, true) then
                any = true
                local species, level, quality, how = self:ReadSlot(tab, slot, link)
                slots[slot] = { species = species, level = level, quality = quality, how = how or "none" }
            end
        end
    end
    rec.tabs[tab] = slots
    if any then DWM:Debug(("PetScan: %s tab %d recorded"):format(guild, tab)) end
end

-- One chat line per guild: tabs seen, cages, and how many have a known species.
function PetScan:PrintReport()
    if ns.guildBankOpen then self:ScanCurrentTab() end
    local g = DWM.db.global.petScan
    if not g or not next(g) then DWM:Print(L["MSG_PETS_NONE"]); return end
    for guild, rec in pairs(g) do
        local tabs, cages, known, m = 0, 0, 0, {}
        for _, slots in pairs(rec.tabs or {}) do
            tabs = tabs + 1
            for _, p in pairs(slots) do
                cages = cages + 1
                if p.species then known = known + 1 end
                m[p.how] = (m[p.how] or 0) + 1
            end
        end
        DWM:Print(L["MSG_PETS_LINE"]:format(guild, tabs, cages, known,
            m.link or 0, m.tooltip or 0, m.name or 0, m.none or 0))
    end
end

function PetScan:GUILDBANKBAGSLOTS_CHANGED()
    if ns.guildBankOpen then self:ScanCurrentTab() end
end

function PetScan:OnEnable()
    self:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
end
