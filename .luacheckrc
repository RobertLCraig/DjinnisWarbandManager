std = "lua51"
max_line_length = false
codes = true

-- Ace methods are declared `function X:Method(self, ...)` by convention, so an
-- unused `self`/vararg is expected, not a smell. `ADDON_NAME` from the standard
-- `local ADDON_NAME, ns = ...` header is often unused in a given file.
ignore = {
    "212/self",
    "212/...",
    "211/ADDON_NAME",
    "431", "432",   -- shadowing in the test stub's nested Ace shims
}

-- Third-party libraries are vendored; don't lint them.
exclude_files = {
    "libs/",
    ".luarocks/",
}

-- The addon's own globals (set intentionally).
globals = {
    "DjinnisWarbandManager",
    "SLASH_DWM1", "SLASH_DWM2",
}

-- WoW client API surface the addon reads. Not exhaustive for the whole client,
-- just what this addon touches - keeps luacheck honest about real typos.
read_globals = {
    -- core Lua-ish globals WoW exposes
    "time", "date", "wipe", "strsplit", "strtrim", "strjoin", "tContains",
    "hooksecurefunc", "geterrorhandler",
    -- libraries / framework
    "LibStub", "CreateFrame", "UIParent", "GameTooltip",
    -- namespaces
    "C_Bank", "C_Container", "C_Item", "C_Timer", "C_CurrencyInfo",
    "Enum", "ItemLocation",
    -- money / player / unit
    "GetMoney", "GetCoinTextureString", "GetMoneyString",
    "UnitName", "UnitGUID", "UnitFullName", "UnitClass", "UnitLevel",
    "GetRealmName", "GetNormalizedRealmName",
    -- professions
    "GetProfessions", "GetProfessionInfo",
    -- cursor / containers
    "GetCursorInfo", "ClearCursor", "PickupContainerItem",
    "NUM_BAG_SLOTS", "NUM_TOTAL_EQUIPPED_BAG_SLOTS",
    -- frames referenced by name for the bank-button anchor
    "BankFrame", "BankPanel",
}

-- Tests install the fake client by assigning to _G; allow that there.
files["tests/"] = {
    std = "lua51+busted",
    globals = {
        "time", "date", "print", "NUM_BAG_SLOTS", "Enum",
        "UnitGUID", "UnitName", "UnitFullName", "UnitClass", "GetRealmName",
        "GetMoney", "GetProfessions", "GetProfessionInfo",
        "GetCursorInfo", "ClearCursor", "CreateFrame",
        "C_Item", "C_Bank", "C_Container", "ItemLocation", "LibStub",
    },
}
