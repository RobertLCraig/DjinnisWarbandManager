local H = require("tests.wow_stub")

-- Arrange a single managed item (id 1001) on the current character's purpose.
local function manage(env, qty, mode)
    env.defineItem(1001, "Widget", 200)
    env.DWM.db.profile.purposes.TestP = { gold = 0, items = { [1001] = { qty = qty, mode = mode } } }
    env.setPurpose("TestP")
end

local function ItemEngine(env) return env.DWM:GetModule("ItemEngine") end

describe("ItemEngine:BuildPlan", function()
    local env
    before_each(function() env = H.reset() end)

    it("keepmin deposits the surplus above the target", function()
        manage(env, 10, "keepmin")
        env.setBags({ [1001] = 30 })
        local plan = ItemEngine(env):BuildPlan()
        assert.equals(1, #plan)
        assert.equals("deposit", plan[1].dir)
        assert.equals(20, plan[1].amount)
    end)

    it("keepmin never withdraws when below the target", function()
        manage(env, 10, "keepmin")
        env.setBags({ [1001] = 5 })
        env.setWarband({ { id = 1001, count = 100 } })
        assert.equals(0, #ItemEngine(env):BuildPlan())
    end)

    it("exact withdraws the deficit, bounded by warband contents", function()
        manage(env, 50, "exact")
        env.setBags({ [1001] = 10 })
        env.setWarband({ { id = 1001, count = 100 } })
        local plan = ItemEngine(env):BuildPlan()
        assert.equals(1, #plan)
        assert.equals("withdraw", plan[1].dir)
        assert.equals(40, plan[1].amount)
    end)

    it("exact caps a withdraw at what the warband actually holds", function()
        manage(env, 50, "exact")
        env.setBags({ [1001] = 10 })
        env.setWarband({ { id = 1001, count = 12 } })
        local plan = ItemEngine(env):BuildPlan()
        assert.equals(12, plan[1].amount)
    end)

    it("depositall deposits everything carried", function()
        manage(env, 0, "depositall")
        env.setBags({ [1001] = 25 })
        local plan = ItemEngine(env):BuildPlan()
        assert.equals("deposit", plan[1].dir)
        assert.equals(25, plan[1].amount)
    end)

    it("respects deposit-only mode (no withdraws)", function()
        manage(env, 50, "exact")
        env.setBags({ [1001] = 10 })
        env.setWarband({ { id = 1001, count = 100 } })
        env.DWM.db.profile.mode = "deposit"
        assert.equals(0, #ItemEngine(env):BuildPlan())
    end)
end)

describe("ItemEngine:ResidualShortfalls", function()
    local env
    before_each(function() env = H.reset() end)

    it("quantifies what is still missing after draining the warband", function()
        manage(env, 50, "exact")
        env.setBags({ [1001] = 10 })
        env.setWarband({ { id = 1001, count = 5 } })
        local short = ItemEngine(env):ResidualShortfalls()
        assert.equals(1, #short)
        assert.equals(35, short[1].short)   -- 50 wanted - 10 have - 5 in warband
    end)

    it("reports nothing for keepmin (never withdraws)", function()
        manage(env, 50, "keepmin")
        env.setBags({ [1001] = 10 })
        assert.equals(0, #ItemEngine(env):ResidualShortfalls())
    end)
end)
