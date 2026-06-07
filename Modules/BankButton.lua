--[[
    Djinni's Warband Manager - BankButton (Phase 6, DESIGN §15.6)

    A small button that appears while the bank window is open and opens the
    options panel. It tries to ANCHOR to whatever bank frame is actually on
    screen - Baganator's bank view first, then other bag replacements, then
    Blizzard's BankFrame - so it sits attached to the bank instead of floating
    in the middle of the screen.

    Anchoring is entirely best-effort and self-healing: if none of the known
    frames is present (an addon renamed/removed its frame, or a UI we don't
    recognise), it silently falls back to the original free-floating, draggable
    behaviour positioned in screen coords. A missing frame can therefore only
    ever cost us the anchor, never raise an error - which preserves the
    "compatible with everything" guarantee the original design wanted.

    Plain (non-secure) frame -> no combat-lockdown concerns.
]]

local ADDON_NAME, ns = ...
local DWM = ns.Addon
local L = ns.L

local BankButton = DWM:NewModule("BankButton", "AceEvent-3.0", "AceTimer-3.0")
ns.BankButton = BankButton

local btn  -- created lazily on first bank open

-- Bank frames we know how to anchor to, in priority order. We anchor to the
-- first one that EXISTS and is SHOWN. Lookups are by global name and fully
-- guarded, so an addon changing a name just drops us back to floating.
local ANCHOR_CANDIDATES = {
    "Baganator_CategoryViewBankViewFrame",  -- Baganator (categories)
    "Baganator_SingleViewBankViewFrame",    -- Baganator (single view)
    "BagnonFramebank",                      -- Bagnon
    "CombuctorFrameBank",                   -- Combuctor
    "ARKINV_Frame2",                        -- ArkInventory (bank frame)
    "BankPanel",                            -- Blizzard (The War Within bank UI)
    "BankFrame",                            -- Blizzard (fallback / container)
}

local function ResolveAnchor()
    for _, name in ipairs(ANCHOR_CANDIDATES) do
        local f = _G[name]
        if f and f.IsShown and f:IsShown() and f.GetRight and f:GetRight() then
            return f
        end
    end
    return nil
end

local function SavePosition(self)
    local cfg = DWM.db.profile.bankButton
    if self._anchored then
        -- Save our centre as an offset from the anchor's top-right corner, in
        -- the anchor's coordinate space. We parent to the anchor and keep our
        -- own scale at 1, so the button and the anchor share an effective
        -- scale and this subtraction needs no scale conversion.
        local fr, ft = self._anchored:GetRight(), self._anchored:GetTop()
        local cx, cy = self:GetCenter()
        if fr and ft and cx and cy then
            cfg.anchor = { x = cx - fr, y = cy - ft }
        end
    else
        local point, _, relPoint, x, y = self:GetPoint()
        cfg.point, cfg.relPoint, cfg.x, cfg.y = point, relPoint, x, y
    end
end

local function ApplyPosition(self)
    local cfg = DWM.db.profile.bankButton
    local anchor = ResolveAnchor()
    self:ClearAllPoints()
    if anchor then
        -- Parent to the anchor so we inherit its strata and auto-hide with it;
        -- scale 1 keeps our coordinate space identical to the anchor's.
        self:SetParent(anchor)
        self:SetScale(1)
        self:SetFrameStrata("HIGH")
        self:SetFrameLevel((anchor:GetFrameLevel() or 0) + 20)
        local a = cfg.anchor
        -- Default: just above the frame's top-right corner, clear of the
        -- close button that lives inside that corner.
        self:SetPoint("CENTER", anchor, "TOPRIGHT", (a and a.x) or -20, (a and a.y) or 18)
        self._anchored = anchor
    else
        self:SetParent(UIParent)
        self:SetScale(1)
        self:SetFrameStrata("HIGH")
        self:SetPoint(cfg.point or "CENTER", UIParent,
            cfg.relPoint or "CENTER", cfg.x or 0, cfg.y or 220)
        self._anchored = nil
    end
end

function BankButton:_Ensure()
    if btn then return btn end

    btn = CreateFrame("Button", "DWMBankButton", UIParent)
    btn:SetSize(36, 36)
    btn:SetFrameStrata("HIGH")
    btn:SetClampedToScreen(true)
    btn:SetMovable(true)
    btn:EnableMouse(true)
    btn:RegisterForDrag("LeftButton")
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture("Interface\\Icons\\achievement_guildperk_mobilebanking")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    btn.icon = icon

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetPoint("BOTTOMRIGHT", 2, -2)
    border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    border:SetTexCoord(0.2, 0.8, 0.2, 0.8)
    border:SetVertexColor(0.31, 0.76, 0.97)

    btn:SetScript("OnDragStart", function(self) self:StartMoving() end)
    btn:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
        ApplyPosition(self)   -- re-resolve to the anchor-relative point cleanly
    end)
    btn:SetScript("OnClick", function(_, mouseButton)
        DWM:HandleActionClick(mouseButton)
    end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L["ADDON_NAME"])
        GameTooltip:AddLine("|cFFAAAAAA" .. L["BANKBTN_TIP_OPEN"] .. "|r")
        GameTooltip:AddLine("|cFFAAAAAA" .. L["BANKBTN_TIP_PAUSE"] .. "|r")
        GameTooltip:AddLine("|cFFAAAAAA" .. L["BANKBTN_TIP_DRAG"] .. "|r")
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    btn:Hide()
    return btn
end

-- Place + show the button. Deferred one frame from BANKFRAME_OPENED because
-- bag-replacement addons open their own bank frame in response to the SAME
-- event, and event order between addons is not guaranteed - resolving on the
-- next frame ensures their frame is already shown so we can anchor to it.
function BankButton:_Place()
    if DWM.db.profile.bankButton.hide then return end
    if ns.bankState == "closed" then return end
    local b = self:_Ensure()
    ApplyPosition(b)
    b:Show()
end

function BankButton:Refresh()
    -- Called when the toggle changes (possibly while the bank is open).
    if DWM.db.profile.bankButton.hide then
        if btn then btn:Hide() end
        return
    end
    if ns.bankState ~= "closed" then self:_Place() end
end

function BankButton:BANKFRAME_OPENED()
    if DWM.db.profile.bankButton.hide then return end
    self:ScheduleTimer("_Place", 0)
end

function BankButton:BANKFRAME_CLOSED()
    if btn then btn:Hide() end
end

function BankButton:OnEnable()
    self:RegisterEvent("BANKFRAME_OPENED")
    self:RegisterEvent("BANKFRAME_CLOSED")
end
