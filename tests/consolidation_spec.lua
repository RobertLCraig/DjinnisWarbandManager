local H = require("tests.wow_stub")

-- Manage item 1001 (mode/qty don't matter for consolidation - it scans the
-- managed item set and merges partial warband stacks of those items).
local function manage(env, max)
    env.defineItem(1001, "Widget", max or 200)
    env.DWM.db.profile.purposes.TestP = { gold = 0, items = { [1001] = { qty = 0, mode = "keepmin" } } }
    env.setPurpose("TestP")
end

local function ItemEngine(env) return env.DWM:GetModule("ItemEngine") end

describe("ItemEngine:_PickMerge (managed-stack consolidation)", function()
    local env
    before_each(function() env = H.reset() end)

    it("merges the smallest partial stack into another", function()
        manage(env, 200)
        env.setWarband({ { id = 1001, count = 50 }, { id = 1001, count = 60 } })
        local src, dst, amount = ItemEngine(env):_PickMerge()
        assert.is_not_nil(src)
        assert.equals(50, src.count)        -- smallest is the source
        assert.equals(60, dst.count)
        assert.equals(50, amount)           -- whole source fits (200 - 60 = 140 room)
    end)

    it("only fills the destination up to max (no overflow)", function()
        manage(env, 200)
        env.setWarband({ { id = 1001, count = 150 }, { id = 1001, count = 180 } })
        local src, dst, amount = ItemEngine(env):_PickMerge()
        assert.equals(150, src.count)
        assert.equals(180, dst.count)
        assert.equals(20, amount)           -- only 20 fits before dst hits 200
    end)

    it("returns nothing for a single stack", function()
        manage(env, 200)
        env.setWarband({ { id = 1001, count = 50 } })
        assert.is_nil(ItemEngine(env):_PickMerge())
    end)

    it("ignores already-full stacks", function()
        manage(env, 200)
        env.setWarband({ { id = 1001, count = 200 }, { id = 1001, count = 200 } })
        assert.is_nil(ItemEngine(env):_PickMerge())
    end)

    it("ignores unmanaged items", function()
        manage(env, 200)
        env.defineItem(2002, "Other", 200)
        env.setWarband({ { id = 2002, count = 10 }, { id = 2002, count = 20 } })
        assert.is_nil(ItemEngine(env):_PickMerge())
    end)
end)
