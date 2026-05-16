--[[
    Djinni's Warband Manager - ProfessionDetect (Phase 2)

    Suggests a purpose (Crafter / Gatherer only) from the character's primary
    professions. Classifies by skill-line ID, NOT localized name (DESIGN locale
    stance). Suggestion is applied only when the user has not chosen a purpose
    (rec.purposeUserSet); it never overrides an explicit choice (DESIGN S13.6).
]]

local ADDON_NAME, ns = ...
local DWM = ns.Addon
local L = ns.L

local PD = DWM:NewModule("ProfessionDetect", "AceEvent-3.0", "AceTimer-3.0")
ns.ProfessionDetect = PD

-- Locale-independent base skill-line IDs.
local GATHERING = { [182] = true, [186] = true, [393] = true } -- Herb, Mining, Skinning
local CRAFTING  = {
    [171] = true, [164] = true, [333] = true, [202] = true,     -- Alch, BS, Ench, Eng
    [773] = true, [755] = true, [165] = true, [197] = true,     -- Insc, JC, LW, Tailor
}

-- Stable skill-line id -> English profession name. Display/config tokens only
-- (gating compares ids, locale-independent, §15.1). Live names differ by
-- expansion ("Khaz Algar Enchanting"); these are the profession identity.
local PROF_NAMES = {
    [171] = "Alchemy",      [164] = "Blacksmithing", [333] = "Enchanting",
    [202] = "Engineering",  [773] = "Inscription",   [755] = "Jewelcrafting",
    [165] = "Leatherworking", [197] = "Tailoring",
    [182] = "Herbalism",    [186] = "Mining",        [393] = "Skinning",
    [185] = "Cooking",      [356] = "Fishing",
}
ns.PROFESSIONS = PROF_NAMES

-- "Enchanting" / "333" / "none" -> skill-line id, nil("none"), or false(bad).
function ns.ProfessionNameToId(token)
    if token == nil then return false end
    token = tostring(token):gsub("^%s+", ""):gsub("%s+$", "")
    if token == "" or token:lower() == "none" then return nil end
    local num = tonumber(token)
    if num and PROF_NAMES[num] then return num end
    local lc = token:lower()
    for id, name in pairs(PROF_NAMES) do
        if name:lower() == lc then return id end
    end
    return false
end

-- Returns "Crafter" | "Gatherer" | nil. nil = no confident suggestion
-- (only secondary professions, none learned, or incomplete data: S13.6).
function PD:Classify()
    if not GetProfessions or not GetProfessionInfo then return nil end
    local prof1, prof2 = GetProfessions()
    if not prof1 and not prof2 then return nil end          -- none learned

    local hasCraft, hasGather, sawData = false, false, false
    for _, idx in ipairs({ prof1, prof2 }) do
        if idx then
            local _, _, _, _, _, _, skillLine = GetProfessionInfo(idx)
            if skillLine then
                sawData = true
                if CRAFTING[skillLine]  then hasCraft  = true end
                if GATHERING[skillLine] then hasGather = true end
            end
        end
    end
    if not sawData then return nil end                       -- incomplete data
    if hasCraft  then return "Crafter"  end
    if hasGather then return "Gatherer" end
    return nil
end

-- Record THIS character's professions (skill-line id -> rank) so item targets
-- can be profession-gated for any roster record (§15.1). nil = never seen,
-- {} = known to have no professions.
function PD:Snapshot(rec)
    rec = rec or (ns.Roster and ns.Roster:Current())
    if not rec then return end
    if not (GetProfessions and GetProfessionInfo) then return end
    local p1, p2, _, fish, cook = GetProfessions()
    local profs = {}
    local function add(idx)
        if not idx then return end
        local _, _, rank, _, _, _, skillLine = GetProfessionInfo(idx)
        if skillLine then profs[skillLine] = rank or 0 end
    end
    add(p1); add(p2); add(cook); add(fish)
    rec.professions   = profs
    rec.professionsAt = time()
end

function PD:Apply()
    local rec = ns.Roster and ns.Roster:Current()
    if not rec then return end
    self:Snapshot(rec)                                       -- always record
    if not rec.autoPurpose then return end
    if rec.purposeUserSet then return end                    -- never override a choice

    local suggestion = self:Classify()
    if not suggestion then return end
    if not (DWM.db.profile.purposes and DWM.db.profile.purposes[suggestion]) then
        return                                               -- preset was deleted
    end
    if rec.purpose == suggestion then return end

    rec.purpose = suggestion
    DWM:Print((L["MSG_AUTO_PURPOSE"]):format(suggestion))
    if ns.RefreshOptions then ns.RefreshOptions() end
end

-- Debounce: SKILL_LINES_CHANGED can fire in bursts.
function PD:Schedule()
    if self._t then self:CancelTimer(self._t) end
    self._t = self:ScheduleTimer(function() self._t = nil; self:Apply() end, 1.5)
end

function PD:OnEnable()
    self:RegisterEvent("SKILL_LINES_CHANGED", "Schedule")
    self:RegisterEvent("TRADE_SKILL_LIST_UPDATE", "Schedule")
end
