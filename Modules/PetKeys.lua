--[[
    PetKeys (card 0006): how the AH plan names a caged battle pet.

    Every caged pet is item 82800, so a pet is keyed by its species as a
    NEGATIVE number, which never meets a real item ID. A bag or bank slot names
    the species in its battlepet: hyperlink. A guild bank slot does not (seen in
    game 2026-10-08: 62 cages, 0 read), so pets never go through the guild bank.
]]

local ADDON_NAME, ns = ...

ns.PET_CAGE = 82800

function ns.IsPetKey(key)
    return type(key) == "number" and key < 0
end

-- The key for what sits in a bag or bank slot: the item ID, or -species for a
-- caged pet. nil for an empty slot.
function ns.SlotKey(bag, slot)
    local id = C_Container.GetContainerItemID(bag, slot)
    if id ~= ns.PET_CAGE then return id end
    local info = C_Container.GetContainerItemInfo(bag, slot)
    local link = info and info.hyperlink
    if not link or (issecretvalue and issecretvalue(link)) then return id end
    local species = tonumber(link:match("battlepet:(%d+)"))
    return species and -species or id
end

function ns.KeyName(key)
    if ns.IsPetKey(key) then
        local name = C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID
            and C_PetJournal.GetPetInfoBySpeciesID(-key)
        return name or ("pet:" .. tostring(-key))
    end
    return C_Item.GetItemInfo(key) or ("item:" .. tostring(key))
end

function ns.KeyIcon(key)
    if ns.IsPetKey(key) then
        return C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID
            and select(2, C_PetJournal.GetPetInfoBySpeciesID(-key))
    end
    return C_Item.GetItemIconByID(key)
end
