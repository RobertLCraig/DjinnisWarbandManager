-- Dumps every item the four AH characters hold, plus their guild banks and the warband bank.
-- Output: TSV to arg[2] (or stdout): owner, location, itemID, petSpecies, count, bound, quality,
-- name, link, expiry. Writes the file itself so the UTF-8 realm names survive byte for byte.
-- Usage: lua dump.lua <Syndicator.lua> [out.tsv]
dofile(arg[1])
if arg[2] then io.output(arg[2]) end
local function print(s) io.write(s, "\n") end
local D = SYNDICATOR_DATA
local chars = {"Buyme-Aggra(Português)", "What-Shadowsong", "Loamint-Moonglade", "Hotwheel-Ghostlands"}

local function name(link)
  return (link and link:match("%[(.-)%]") or "?"):gsub("|A.-|a", ""):gsub("%s+$", "")
end
local function emit(owner, loc, it)
  if type(it) ~= "table" or not it.itemID then return end
  local species = ""
  if it.itemLink then species = it.itemLink:match("battlepet:(%d+)") or "" end
  print(table.concat({owner, loc, it.itemID, species, it.itemCount or 1,
    tostring(it.isBound), it.quality or "", name(it.itemLink), it.itemLink and it.itemLink:gsub("\t", " ") or "",
    it.expirationTime or ""}, "\t"))
end
local function walk(owner, loc, t)
  if type(t) ~= "table" then return end
  if t.itemID then emit(owner, loc, t) return end
  for _, v in pairs(t) do walk(owner, loc, v) end
end

local guilds = {}
for _, key in ipairs(chars) do
  local c = D.Characters[key]
  if not c then io.stderr:write("missing " .. key .. "\n") else
    io.stderr:write(key .. " guild=" .. tostring(c.details.guild) .. " money=" .. tostring(c.money) .. "\n")
    if c.details.guild then guilds[c.details.guild] = true end
    walk(key, "auction", c.auctions)
    walk(key, "bags", c.bags)
    walk(key, "bank", c.bank)
    walk(key, "bankTabs", c.bankTabs)
    walk(key, "mail", c.mail)
    walk(key, "void", c.void)
  end
end
-- Feeders whose stock sits in their own bags (card 0006): only caged pets, whose bag link carries
-- the species that a guild bank cage does not. Owner "BAGS:<character>".
local bagFeeders = {"Lostpets-Aggra(Português)"}
local function walkPets(owner, t)
  if type(t) ~= "table" then return end
  if t.itemID then
    if t.itemLink and t.itemLink:find("battlepet:", 1, true) then emit(owner, "bags", t) end
    return
  end
  for _, v in pairs(t) do walkPets(owner, v) end
end
for _, key in ipairs(bagFeeders) do
  local c = D.Characters[key]
  if c then walkPets("BAGS:" .. key, c.bags) else io.stderr:write("missing " .. key .. "\n") end
end

-- Every guild bank with data, not only the AH characters' own guild: stock in a big storage
-- guild can reach an AH character through the warband bank.
for g, gd in pairs(D.Guilds) do walk("GUILD:" .. g, "guildbank", gd.bank) end
walk("WARBAND", "warband", D.Warband)
