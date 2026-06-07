local H = require("tests.wow_stub")

describe("Purposes:ResolveGoldForCurrent", function()
    local env
    before_each(function() env = H.reset() end)

    it("uses the default purpose for a fresh character", function()
        -- Default preset is 1000 gold.
        local copper, source, isMule = env.ns.Purposes:ResolveGoldForCurrent()
        assert.equals(1000 * 10000, copper)
        assert.equals("purpose", source)
        assert.is_false(isMule)
    end)

    it("resolves a non-default purpose's gold", function()
        env.setPurpose("Raider")   -- 50000 preset
        local copper, source = env.ns.Purposes:ResolveGoldForCurrent()
        assert.equals(50000 * 10000, copper)
        assert.equals("purpose", source)
    end)

    it("lets a per-character override win over the purpose", function()
        env.setPurpose("Raider")
        env.setOverrideGold(7)
        local copper, source = env.ns.Purposes:ResolveGoldForCurrent()
        assert.equals(7 * 10000, copper)
        assert.equals("override", source)
    end)

    it("reports a mule purpose with a zero target", function()
        env.setPurpose("Mule")
        local copper, source, isMule = env.ns.Purposes:ResolveGoldForCurrent()
        assert.equals(0, copper)
        assert.equals("mule", source)
        assert.is_true(isMule)
    end)
end)

describe("DWM core helpers", function()
    local env
    before_each(function() env = H.reset() end)

    it("considers the warband usable when a tab is purchased", function()
        assert.is_true(env.DWM:IsWarbandUsable())
    end)

    it("counts only carried bags as on-character", function()
        env.defineItem(1001, "Widget", 200)
        env.setBags({ [1001] = 42 })
        assert.equals(42, env.DWM:GetOnCharacterCount(1001))
    end)
end)
