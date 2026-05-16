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

function PD:Apply()
    local rec = ns.Roster and ns.Roster:Current()
    if not rec then return end
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
