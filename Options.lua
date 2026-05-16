--[[
    Djinni's Warband Manager - Options (Phase 2)

    One AceConfig table -> the options panel AND the /dwm command tree
    (AceConfigCmd). Per-character + engine controls are TOP-LEVEL args so
    commands stay short (/dwm set, /dwm purpose, /dwm manage). "Purposes" and
    "Roster" are dynamic groups rebuilt by ns.RefreshOptions() (DESIGN S4/S7).
]]

local ADDON_NAME, ns = ...
local DWM = ns.Addon
local L = ns.L

local function P() return DWM.db.profile end

local function ParseGold(input)
    local n = tonumber((tostring(input or "")):gsub("[%s,]", ""))
    if not n or n < 0 then return nil end
    return math.floor(n)
end

-- "<name...> <value>" -> name, value  (value = LAST whitespace token, so
-- purpose names may contain spaces).
local function SplitNameValue(input)
    input = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return input:match("^(.-)%s+(%S+)$")
end

-- Pull an itemID, qty and optional mode out of free text that may contain a
-- pasted item link (whose [Name] can contain spaces).
local ITEM_MODES = { keepmin = true, exact = true, depositall = true }
local function ParseItemArgs(input)
    input = tostring(input or "")
    local id = input:match("Hitem:(%d+)") or input:match("|Hitem:(%d+)")
    local rest = input
    if id then
        rest = input:gsub("|%x+|Hitem:.-|h%[.-%]|h|r", " "):gsub("|Hitem:.-|h.-|h", " ")
    else
        id = input:match("^%s*(%d+)")
        if id then rest = input:gsub("^%s*%d+", " ", 1) end
    end
    local qty  = rest:match("(%d+)")
    local mode = rest:match("(keepmin)") or rest:match("(exact)") or rest:match("(depositall)")
    return tonumber(id), tonumber(qty), mode
end

local function ItemDisplayName(itemID)
    local n = C_Item.GetItemInfo(itemID)
    if not n and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
    return n or ("item:" .. tostring(itemID))
end

local MODE_VALUES = {
    keepmin    = L["OPT_ITEM_MODE_KEEPMIN"],
    exact      = L["OPT_ITEM_MODE_EXACT"],
    depositall = L["OPT_ITEM_MODE_DEPOSITALL"],
}

local function CurRec() return ns.Roster and ns.Roster:Current() end

local function SetPurposeFor(rec, key, name)
    rec.purpose = name
    if key == (ns.Roster and ns.Roster:CurrentKey()) then
        rec.purposeUserSet = true   -- stop profession auto-suggestion (S13.6)
    end
end

--============================================================================
-- Status / roster print
--============================================================================

local function PrintStatus()
    DWM:Print(L["STATUS_HEADER"])
    DWM:Print(L["STATUS_ENABLED"]:format(P().enabled and L["ON"] or L["OFF"]))
    local modeName = ({
        deposit = L["MODE_DEPOSIT"], withdraw = L["MODE_WITHDRAW"], both = L["MODE_BOTH"],
    })[P().mode] or P().mode
    DWM:Print(L["STATUS_MODE"]:format(modeName))

    local target, source, isMule, pname = DWM:GetEffectiveTargetCopper()
    DWM:Print(L["STATUS_PURPOSE"]:format(tostring(pname or "?")))
    if isMule then
        DWM:Print(L["STATUS_TARGET"]:format(L["MULE_LABEL"]))
    else
        local srcTag = (source == "override") and L["STATUS_TARGET_SOURCE_OVERRIDE"]
                                               or L["STATUS_TARGET_SOURCE_DEFAULT"]
        DWM:Print(L["STATUS_TARGET"]:format(DWM:FormatMoney(target)) .. " " .. srcTag)
    end

    local rec = CurRec()
    if rec then
        DWM:Print(L["STATUS_MANAGED"]:format(rec.managed ~= false and L["YES"] or L["NO"]))
        DWM:Print(L["STATUS_AUTOPURPOSE"]:format(rec.autoPurpose ~= false and L["ON"] or L["OFF"]))
    end
    DWM:Print(L["STATUS_CHAR_GOLD"]:format(DWM:FormatMoney(GetMoney())))
    DWM:Print(L["STATUS_WARBAND_GOLD"]:format(DWM:FormatMoney(DWM:GetWarbandGold())))
    -- Item balancing state (this is the bit that was invisible before).
    local nItems = 0
    for _ in pairs(ns.Purposes and ns.Purposes:ResolveItemsForCurrent() or {}) do
        nItems = nItems + 1
    end
    DWM:Print(L["STATUS_ITEMS"]:format(P().itemEnabled and L["ON"] or L["OFF"]))
    DWM:Print(L["STATUS_ITEMS_CONFIRMED"]:format(
        P().itemFirstRunConfirmed and L["YES"] or L["NO"]))
    DWM:Print(L["STATUS_ITEM_TARGETS"]:format(nItems))
    DWM:Print(L["STATUS_SIMULATE"]:format(P().simulate and L["ON"] or L["OFF"]))
    DWM:Print(L["STATUS_PAUSED"]:format(ns.sessionPaused and L["YES"] or L["NO"]))
end
ns.PrintStatus = PrintStatus

-- Live one-glance summary for the top of the panel.
local function CurrentSummary()
    local rec = CurRec()
    local who = (rec and ns.Roster and ns.Roster:Display(rec)) or UnitName("player") or "?"
    local target, source, isMule, pname = DWM:GetEffectiveTargetCopper()
    local tgt
    if isMule then
        tgt = L["MULE_LABEL"]
    else
        local srcTag = (source == "override") and L["STATUS_TARGET_SOURCE_OVERRIDE"]
                                               or L["STATUS_TARGET_SOURCE_DEFAULT"]
        tgt = DWM:FormatMoney(target) .. " " .. srcTag
    end
    local s = L["OPT_CURRENT_SUMMARY"]:format(who, tostring(pname or "?"), tgt)
    if rec and rec.managed == false then
        s = s .. "\n|cFFFF8080" .. L["STATUS_UNMANAGED"] .. "|r"
    end
    return s
end

local function PrintRoster()
    DWM:Print(L["ROSTER_HEADER"])
    local list = ns.Roster and ns.Roster:All() or {}
    if #list == 0 then DWM:Print("  " .. L["ROSTER_EMPTY"]); return end
    for _, e in ipairs(list) do
        local rec = e.rec
        local tgt = rec.goldOverride and DWM:FormatMoney(rec.goldOverride * 10000)
                                       or ("[" .. tostring(rec.purpose or "?") .. "]")
        DWM:Print(("  %s  %s%s"):format(
            ns.Roster:Display(rec), tgt,
            rec.managed == false and ("  |cFFFF8080(" .. L["STATUS_UNMANAGED"] .. ")|r") or ""))
    end
end

local function PrintItems()
    local t = ns.Purposes and ns.Purposes:ResolveItemsForCurrent() or {}
    local ids = {}
    for id in pairs(t) do ids[#ids + 1] = id end
    table.sort(ids)
    if #ids == 0 then DWM:Print(L["MSG_ITEMS_LIST_EMPTY"]); return end
    DWM:Print(L["MSG_ITEMS_LIST_HEADER"])
    for _, id in ipairs(ids) do
        local s = t[id]
        DWM:Print(("  %s (%d): %d  |cFFAAAAAA[%s]|r  - have %d"):format(
            ItemDisplayName(id), id, s.qty or 0, s.mode or "keepmin",
            DWM:GetOnCharacterCount(id)))
    end
end

--============================================================================
-- Dynamic args: purposes editor + roster
--============================================================================

local function PurposeValues()
    local v = {}
    for _, n in ipairs(ns.Purposes:Names()) do v[n] = n end
    return v
end

local function BuildPurposeEditArgs()
    local args = {
        _add = {
            type = "input", order = 1, name = L["OPT_PURPOSE_ADD_NAME"],
            desc = L["OPT_PURPOSE_ADD_DESC"], usage = "<name>",
            get = function() return "" end,
            set = function(_, v)
                local ok, why = ns.Purposes:Add(v)
                if ok then DWM:Print(L["MSG_PURPOSE_ADDED"]:format(v)); ns.RefreshOptions()
                elseif why == "exists" then DWM:Print(L["MSG_PURPOSE_EXISTS"]:format(v)) end
            end,
        },
    }
    local i = 2
    for _, name in ipairs(ns.Purposes:Names()) do
        local pname = name
        args["p" .. i] = {
            type = "group", inline = true, order = i, name = pname,
            args = {
                gold = {
                    type = "input", order = 1, name = L["OPT_PURPOSE_GOLD_NAME"], usage = "<gold>",
                    get = function() return tostring((ns.Purposes:Get(pname) or {}).gold or 0) end,
                    validate = function(_, v) return ParseGold(v) ~= nil or L["OPT_PURPOSE_GOLD_NAME"] end,
                    set = function(_, v) ns.Purposes:SetGold(pname, ParseGold(v)) end,
                    disabled = function() return (ns.Purposes:Get(pname) or {}).mule == true end,
                },
                mule = {
                    type = "toggle", order = 2, name = L["OPT_PURPOSE_MULE_NAME"],
                    desc = L["OPT_PURPOSE_MULE_DESC"],
                    get = function() return (ns.Purposes:Get(pname) or {}).mule == true end,
                    set = function(_, v) ns.Purposes:SetMule(pname, v) end,
                },
                del = {
                    type = "execute", order = 3, name = L["OPT_PURPOSE_DEL_NAME"],
                    confirm = true, confirmText = L["CONFIRM_PURPOSE_DEL"]:format(pname),
                    disabled = function() return pname == P().defaultPurpose end,
                    func = function()
                        local ok, why = ns.Purposes:Delete(pname)
                        if ok then DWM:Print(L["MSG_PURPOSE_DELETED"]:format(pname)); ns.RefreshOptions()
                        elseif why == "isdefault" then DWM:Print(L["MSG_PURPOSE_ISDEFAULT"]) end
                    end,
                },
                items = {
                    type = "group", inline = true, order = 4, name = L["OPT_ITEMS"],
                    args = (function()
                        local ia = {
                            add = {
                                type = "input", order = 1,
                                name = L["OPT_PURPOSE_ITEM_ADD_NAME"],
                                desc = L["OPT_PURPOSE_ITEM_ADD_DESC"],
                                usage = "<link|id> <qty> [keepmin|exact|depositall]",
                                get = function() return "" end,
                                set = function(_, v)
                                    local id, qty, md = ParseItemArgs(v)
                                    if not id then DWM:Print(L["MSG_ITEM_BADID"]); return end
                                    ns.Purposes:SetItem(pname, id, qty or 0, md)
                                    DWM:Print(L["MSG_PURPOSE_ITEM_SET"]:format(
                                        pname, ItemDisplayName(id), qty or 0, md or "keepmin"))
                                    ns.RefreshOptions()
                                end,
                            },
                        }
                        local entry = ns.Purposes:Get(pname)
                        local items = entry and entry.items or {}
                        local oid = 2
                        local ids = {}
                        for id in pairs(items) do ids[#ids + 1] = id end
                        table.sort(ids)
                        for _, id in ipairs(ids) do
                            local itemID = id
                            ia["i" .. oid] = {
                                type = "group", inline = true, order = oid,
                                name = ItemDisplayName(itemID) .. " (" .. itemID .. ")",
                                args = {
                                    qty = {
                                        type = "input", order = 1, name = L["OPT_ITEM_QTY"],
                                        usage = "<n>",
                                        get = function() return tostring((items[itemID] or {}).qty or 0) end,
                                        validate = function(_, v) return ParseGold(v) ~= nil or L["OPT_ITEM_QTY"] end,
                                        set = function(_, v)
                                            ns.Purposes:SetItem(pname, itemID, ParseGold(v) or 0,
                                                (items[itemID] or {}).mode)
                                        end,
                                    },
                                    mode = {
                                        type = "select", order = 2, name = L["OPT_ITEM_MODE"],
                                        values = MODE_VALUES,
                                        sorting = { "keepmin", "exact", "depositall" },
                                        get = function() return (items[itemID] or {}).mode or "keepmin" end,
                                        set = function(_, v)
                                            ns.Purposes:SetItem(pname, itemID,
                                                (items[itemID] or {}).qty or 0, v)
                                        end,
                                    },
                                    del = {
                                        type = "execute", order = 3, name = L["OPT_ITEM_DEL"],
                                        func = function()
                                            ns.Purposes:DelItem(pname, itemID)
                                            DWM:Print(L["MSG_PURPOSE_ITEM_DEL"]:format(
                                                pname, ItemDisplayName(itemID)))
                                            ns.RefreshOptions()
                                        end,
                                    },
                                },
                            }
                            oid = oid + 1
                        end
                        return ia
                    end)(),
                },
            },
        }
        i = i + 1
    end
    return args
end

local function BuildRosterArgs()
    local args, order = {}, 1
    for _, e in ipairs(ns.Roster and ns.Roster:All() or {}) do
        local rec, key = e.rec, e.key
        local isCurrent = (key == ns.Roster:CurrentKey())
        args["r" .. order] = {
            type = "group", inline = true, order = order,
            name = ns.Roster:Display(rec) .. (isCurrent and "  |cFF4FC3F7*|r" or ""),
            args = {
                purpose = {
                    type = "select", order = 1, name = L["OPT_PURPOSE_NAME"],
                    values = PurposeValues,
                    get = function() return rec.purpose end,
                    set = function(_, v) SetPurposeFor(rec, key, v); ns.RefreshOptions() end,
                },
                override = {
                    type = "input", order = 2, name = L["OPT_OVERRIDE_NAME"],
                    desc = L["OPT_OVERRIDE_DESC"], usage = "<gold>",
                    get = function() return rec.goldOverride and tostring(rec.goldOverride) or "" end,
                    validate = function(_, v)
                        v = tostring(v or ""):gsub("%s", "")
                        return v == "" or ParseGold(v) ~= nil or L["OPT_OVERRIDE_DESC"]
                    end,
                    set = function(_, v)
                        v = tostring(v or ""):gsub("%s", "")
                        rec.goldOverride = (v == "") and nil or ParseGold(v)
                    end,
                },
                managed = {
                    type = "toggle", order = 3, name = L["OPT_MANAGE_NAME"], desc = L["OPT_MANAGE_DESC"],
                    get = function() return rec.managed ~= false end,
                    set = function(_, v) rec.managed = v and true or false end,
                },
                autopurpose = {
                    type = "toggle", order = 4, name = L["OPT_AUTOPURPOSE_NAME"], desc = L["OPT_AUTOPURPOSE_DESC"],
                    get = function() return rec.autoPurpose ~= false end,
                    set = function(_, v) rec.autoPurpose = v and true or false end,
                },
                del = {
                    type = "execute", order = 5, name = L["OPT_ROSTER_DEL_NAME"],
                    hidden = function() return isCurrent end,
                    confirm = true, confirmText = L["CONFIRM_ROSTER_DEL"]:format(ns.Roster:Display(rec)),
                    func = function() ns.Roster:Delete(key); ns.RefreshOptions() end,
                },
            },
        }
        order = order + 1
    end
    if order == 1 then
        args._empty = { type = "description", order = 1, name = L["ROSTER_EMPTY"] }
    end
    return args
end

--============================================================================
-- Static options tree (top-level keys -> short /dwm commands)
--============================================================================

local options = {
    type = "group",
    name = L["ADDON_NAME"],
    args = {
        summary = {
            type = "description", order = 0, fontSize = "medium",
            name = function() return CurrentSummary() .. "\n" end,
        },
        enabled = {
            type = "toggle", order = 1, name = L["OPT_ENABLED_NAME"], desc = L["OPT_ENABLED_DESC"],
            get = function() return P().enabled end, set = function(_, v) P().enabled = v end,
        },
        mode = {
            type = "select", order = 2, name = L["OPT_MODE_NAME"], desc = L["OPT_MODE_DESC"],
            values = { deposit = L["MODE_DEPOSIT"], withdraw = L["MODE_WITHDRAW"], both = L["MODE_BOTH"] },
            sorting = { "deposit", "withdraw", "both" },
            get = function() return P().mode end, set = function(_, v) P().mode = v end,
        },
        simulate = {
            type = "toggle", order = 3, name = L["OPT_SIMULATE_NAME"], desc = L["OPT_SIMULATE_DESC"],
            get = function() return P().simulate end, set = function(_, v) P().simulate = v end,
        },
        pause = {
            type = "execute", order = 4, name = L["OPT_PAUSE_NAME"], desc = L["OPT_PAUSE_DESC"],
            func = function()
                ns.sessionPaused = not ns.sessionPaused
                DWM:Print(L["STATUS_PAUSED"]:format(ns.sessionPaused and L["YES"] or L["NO"]))
            end,
        },

        hdr_char = {
            type = "header", order = 10,
            name = function()
                local r = CurRec()
                return (r and ns.Roster)
                    and L["OPT_THISCHAR_NAMED"]:format(ns.Roster:Display(r))
                    or L["OPT_THISCHAR"]
            end,
        },
        purpose = {
            type = "select", order = 11, name = L["OPT_PURPOSE_NAME"], desc = L["OPT_PURPOSE_DESC"],
            values = PurposeValues,
            get = function() local r = CurRec(); return r and r.purpose end,
            set = function(_, v)
                local r, k = CurRec()
                if r then
                    SetPurposeFor(r, k, v)
                    DWM:Print(L["MSG_PURPOSE_SET"]:format(v))
                    ns.RefreshOptions()
                end
            end,
        },
        set = {
            type = "input", order = 12, name = L["OPT_CHAR_TARGET_NAME"], desc = L["OPT_CHAR_TARGET_DESC"],
            usage = "<gold>",
            get = function() local r = CurRec(); return r and r.goldOverride and tostring(r.goldOverride) or "" end,
            validate = function(_, v)
                v = tostring(v or ""):gsub("%s", "")
                return v == "" or ParseGold(v) ~= nil or L["OPT_CHAR_TARGET_DESC"]
            end,
            set = function(_, v)
                local r = CurRec(); if not r then return end
                v = tostring(v or ""):gsub("%s", "")
                if v == "" then r.goldOverride = nil; ns.RefreshOptions(); return end
                local g = ParseGold(v); if not g then return end
                r.goldOverride = g
                DWM:Print(L["MSG_SET_TARGET"]:format(UnitName("player"), DWM:FormatMoney(g * 10000)))
                ns.RefreshOptions()
            end,
        },
        clearoverride = {
            type = "execute", order = 13, name = L["OPT_CLEAROVERRIDE_NAME"], desc = L["OPT_CLEAROVERRIDE_DESC"],
            func = function()
                local r = CurRec(); if not r then return end
                r.goldOverride = nil
                DWM:Print(L["MSG_CLEARED_OVERRIDE"]:format(tostring(r.purpose or "?")))
                ns.RefreshOptions()
            end,
        },
        autopurpose = {
            type = "toggle", order = 14, name = L["OPT_AUTOPURPOSE_NAME"], desc = L["OPT_AUTOPURPOSE_DESC"],
            get = function() local r = CurRec(); return r and r.autoPurpose ~= false end,
            set = function(_, v) local r = CurRec(); if r then r.autoPurpose = v and true or false end end,
        },
        manage = {
            type = "toggle", order = 15, name = L["OPT_MANAGE_NAME"], desc = L["OPT_MANAGE_DESC"],
            get = function() local r = CurRec(); return r and r.managed ~= false end,
            set = function(_, v)
                local r = CurRec()
                if r then r.managed = v and true or false; ns.RefreshOptions() end
            end,
        },

        hdr_purposes = { type = "header", order = 20, name = L["OPT_PURPOSES"] },
        defaultpurpose = {
            type = "select", order = 21, name = L["OPT_DEFAULTPURPOSE_NAME"], desc = L["OPT_DEFAULTPURPOSE_DESC"],
            values = PurposeValues,
            get = function() return P().defaultPurpose end,
            set = function(_, v) P().defaultPurpose = v end,
        },
        purposeedit = { type = "group", order = 22, name = L["OPT_PURPOSES"], args = {} },
        rostertab   = { type = "group", order = 23, name = L["OPT_ROSTER"],   args = {} },

        hdr_items = { type = "header", order = 24, name = L["OPT_ITEMS"] },
        itemenable = {
            type = "toggle", order = 25,
            name = L["OPT_ITEMENABLED_NAME"], desc = L["OPT_ITEMENABLED_DESC"],
            get = function() return P().itemEnabled end,
            set = function(_, v)
                P().itemEnabled = v
                DWM:Print(L["MSG_ITEM_TOGGLED"]:format(v and L["ON"] or L["OFF"]))
            end,
        },
        itemsconfirm = {
            type = "execute", order = 26,
            name = L["OPT_ITEMCONFIRM_NAME"], desc = L["OPT_ITEMCONFIRM_DESC"],
            confirm = true, confirmText = L["OPT_ITEMCONFIRM_DESC"],
            disabled = function() return P().itemFirstRunConfirmed end,
            func = function()
                P().itemFirstRunConfirmed = true
                DWM:Print(L["MSG_ITEMS_CONFIRMED"])
            end,
        },
        items = {
            type = "execute", order = 27,
            name = L["OPT_ITEMS_LIST_NAME"], desc = L["OPT_ITEMS_LIST_DESC"],
            func = PrintItems,
        },
        item = {
            type = "input", order = 110, guiHidden = true,
            name = L["CMD_HELP_ITEM"], usage = "<link|id> <qty> [keepmin|exact|depositall]",
            get = function() return "" end,
            set = function(_, v)
                local id, qty, md = ParseItemArgs(v)
                if not id then DWM:Print(L["MSG_ITEM_BADID"]); return end
                local r = CurRec(); if not r then return end
                r.itemOverrides = r.itemOverrides or {}
                r.itemOverrides[id] = { qty = qty or 0, mode = ITEM_MODES[md] and md or "keepmin" }
                DWM:Print(L["MSG_ITEM_SET"]:format(
                    ItemDisplayName(id), qty or 0, (ITEM_MODES[md] and md or "keepmin")))
            end,
        },
        itemclear = {
            type = "input", order = 111, guiHidden = true,
            name = "itemclear", usage = "<link|id>",
            get = function() return "" end,
            set = function(_, v)
                local id = (ParseItemArgs(v))
                if not id then DWM:Print(L["MSG_ITEM_BADID"]); return end
                local r = CurRec(); if not r or not r.itemOverrides then return end
                r.itemOverrides[id] = nil
                DWM:Print(L["MSG_ITEM_CLEARED"]:format(ItemDisplayName(id)))
            end,
        },
        purposeitem = {
            type = "input", order = 112, guiHidden = true,
            name = "purposeitem", usage = "<purpose> <link|id> <qty> [mode]",
            get = function() return "" end,
            set = function(_, v)
                local pn, rest = tostring(v):match("^(%S+)%s+(.+)$")
                if not pn then return end
                local id, qty, md = ParseItemArgs(rest)
                if not id then DWM:Print(L["MSG_ITEM_BADID"]); return end
                local ok = ns.Purposes:SetItem(pn, id, qty or 0, md)
                if ok then
                    DWM:Print(L["MSG_PURPOSE_ITEM_SET"]:format(
                        pn, ItemDisplayName(id), qty or 0, md or "keepmin"))
                    ns.RefreshOptions()
                else
                    DWM:Print(L["MSG_PURPOSE_MISSING"]:format(pn))
                end
            end,
        },
        purposeitemdel = {
            type = "input", order = 113, guiHidden = true,
            name = "purposeitemdel", usage = "<purpose> <link|id>",
            get = function() return "" end,
            set = function(_, v)
                local pn, rest = tostring(v):match("^(%S+)%s+(.+)$")
                if not pn then return end
                local id = (ParseItemArgs(rest))
                if not id then DWM:Print(L["MSG_ITEM_BADID"]); return end
                if ns.Purposes:DelItem(pn, id) then
                    DWM:Print(L["MSG_PURPOSE_ITEM_DEL"]:format(pn, ItemDisplayName(id)))
                    ns.RefreshOptions()
                end
            end,
        },

        hdr_actions = { type = "header", order = 30, name = L["OPT_GENERAL"] },
        balance = {
            type = "execute", order = 31, name = L["OPT_BALANCE_NOW_NAME"], desc = L["OPT_BALANCE_NOW_DESC"],
            func = function()
                local B = DWM:GetModule("Balancer", true); if B then B:RunGold("manual") end
                local I = DWM:GetModule("ItemEngine", true); if I then I:Run("manual") end
            end,
        },
        status = {
            type = "execute", order = 32, name = L["OPT_STATUS_NAME"], desc = L["OPT_STATUS_DESC"],
            func = PrintStatus,
        },
        roster = {
            type = "execute", order = 33, name = L["OPT_ROSTER_PRINT_NAME"], desc = L["OPT_ROSTER_PRINT_DESC"],
            func = PrintRoster,
        },

        -- Command-only multi-token helpers (hidden from the GUI; the GUI uses
        -- the Purposes group above for the same operations).
        purposeadd = {
            type = "input", order = 100, name = L["OPT_PURPOSE_ADD_NAME"], guiHidden = true,
            get = function() return "" end,
            set = function(_, v)
                local ok, why = ns.Purposes:Add(v)
                if ok then DWM:Print(L["MSG_PURPOSE_ADDED"]:format(v)); ns.RefreshOptions()
                elseif why == "exists" then DWM:Print(L["MSG_PURPOSE_EXISTS"]:format(v)) end
            end,
        },
        purposedel = {
            type = "input", order = 101, name = L["OPT_PURPOSE_DEL_NAME"], guiHidden = true,
            get = function() return "" end,
            set = function(_, v)
                local nm = (tostring(v):gsub("^%s+", ""):gsub("%s+$", ""))
                local ok, why = ns.Purposes:Delete(nm)
                if ok then DWM:Print(L["MSG_PURPOSE_DELETED"]:format(nm)); ns.RefreshOptions()
                elseif why == "isdefault" then DWM:Print(L["MSG_PURPOSE_ISDEFAULT"])
                else DWM:Print(L["MSG_PURPOSE_MISSING"]:format(nm)) end
            end,
        },
        purposegold = {
            type = "input", order = 102, name = "purposegold", guiHidden = true, usage = "<name> <gold>",
            get = function() return "" end,
            set = function(_, v)
                local nm, g = SplitNameValue(v)
                if nm and ns.Purposes:SetGold(nm, ParseGold(g)) then
                    DWM:Print(L["MSG_PURPOSE_GOLD_SET"]:format(nm, DWM:FormatMoney((ParseGold(g) or 0) * 10000)))
                    ns.RefreshOptions()
                else
                    DWM:Print(L["MSG_PURPOSE_MISSING"]:format(tostring(nm)))
                end
            end,
        },
        purposemule = {
            type = "input", order = 103, name = "purposemule", guiHidden = true, usage = "<name> on|off",
            get = function() return "" end,
            set = function(_, v)
                local nm, s = SplitNameValue(v)
                if nm and ns.Purposes:SetMule(nm, s == "on" or s == "true" or s == "1") then
                    DWM:Print(L["MSG_PURPOSE_MULE_SET"]:format(nm, tostring(s)))
                    ns.RefreshOptions()
                else
                    DWM:Print(L["MSG_PURPOSE_MISSING"]:format(tostring(nm)))
                end
            end,
        },
    },
}

--============================================================================
-- Registration
--============================================================================

function ns.RefreshOptions()
    options.args.purposeedit.args = BuildPurposeEditArgs()
    options.args.rostertab.args   = BuildRosterArgs()
    local reg = LibStub("AceConfigRegistry-3.0", true)
    if reg then reg:NotifyChange(ADDON_NAME) end
end

function ns.SetupOptions()
    local AceConfig = LibStub("AceConfig-3.0")
    local AceConfigDialog = LibStub("AceConfigDialog-3.0")
    local AceConfigCmd = LibStub("AceConfigCmd-3.0")

    options.args.purposeedit.args = BuildPurposeEditArgs()
    options.args.rostertab.args   = BuildRosterArgs()

    options.args.profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(DWM.db)
    options.args.profiles.order = 40

    AceConfig:RegisterOptionsTable(ADDON_NAME, options)
    AceConfigDialog:AddToBlizOptions(ADDON_NAME, L["ADDON_NAME"])

    DWM:RegisterChatCommand("dwm", function(input)
        input = input and input:trim() or ""
        if input == "" or input == "options" or input == "config" then
            AceConfigDialog:Open(ADDON_NAME)
        elseif input == "help" or input == "?" then
            DWM:Print(L["CMD_HELP_HEADER"])
            DWM:Print(L["CMD_HELP_OPTIONS"]);  DWM:Print(L["CMD_HELP_PURPOSE"])
            DWM:Print(L["CMD_HELP_SET"]);      DWM:Print(L["CMD_HELP_CLEAR"])
            DWM:Print(L["CMD_HELP_MANAGE"]);   DWM:Print(L["CMD_HELP_MODE"])
            DWM:Print(L["CMD_HELP_ENABLE"]);   DWM:Print(L["CMD_HELP_SIMULATE"])
            DWM:Print(L["CMD_HELP_PAUSE"]);    DWM:Print(L["CMD_HELP_BALANCE"])
            DWM:Print(L["CMD_HELP_ROSTER"]);   DWM:Print(L["CMD_HELP_STATUS"])
            DWM:Print(L["CMD_HELP_ITEMS"]);    DWM:Print(L["CMD_HELP_ITEM"])
            DWM:Print(L["CMD_HELP_ITEMLIST"])
        else
            AceConfigCmd.HandleCommand(DWM, "dwm", ADDON_NAME, input)
        end
    end)

    DWM.db.RegisterCallback(DWM, "OnProfileChanged", "RefreshConfig")
    DWM.db.RegisterCallback(DWM, "OnProfileCopied", "RefreshConfig")
    DWM.db.RegisterCallback(DWM, "OnProfileReset", "RefreshConfig")
end
