-- Exports TSM accounting rows (sales, expired, cancelled) for the four AH realm groups.
-- Output TSV to arg[2] (or stdout): kind, realm, then the CSV columns as TSM stored them.
-- Usage: lua tsmacct.lua <TradeSkillMaster.lua> [out.tsv]
dofile(arg[1])
if arg[2] then io.output(arg[2]) end
local function print(s) io.write(s, "\n") end
local db = TradeSkillMasterDB
local realms = {
  ["Aggra (Português)"] = 1, ["Grim Batol"] = 1, ["Frostmane"] = 1,
  ["Shadowsong"] = 1, ["Aszune"] = 1,
  ["Moonglade"] = 1, ["Steamwheedle Cartel"] = 1, ["The Sha'tar"] = 1,
  ["Ghostlands"] = 1, ["Dragonblight"] = 1, ["Deathwing"] = 1, ["The Maelstrom"] = 1,
  ["Lightning's Blade"] = 1, ["Karazhan"] = 1,
}
for key, val in pairs(db) do
  local realm, kind = key:match("^r@(.-)@internalData@csv(%a+)$")
  if realm and realms[realm] and (kind == "Sales" or kind == "Expired" or kind == "Cancelled") and type(val) == "string" then
    local first = true
    for line in val:gmatch("[^\n]+") do
      if first then
        io.stderr:write(kind .. " header: " .. line .. "\n")
        first = false
      else
        print(kind .. "\t" .. realm .. "\t" .. line:gsub("\t", " "))
      end
    end
  end
end
