-- autolooting.lua
-- Auto Loot module for OTClient

AutoLoot = {}

local autoLootWindow = nil
local itemSelectorWindow = nil
local ruleCreatorWindow = nil
local lootRules = {}
local lootItemCache = {}
local selectedItemData = nil

-- LootItems table - populated from items.lua or equivalent data source.
-- Format: { [id] = { name = "item name", ... }, ... }
-- This table is expected to be defined globally by the client's item data loader.
-- If not available, buildLootItemCache() will return an empty cache.
local LootItems = LootItems or {}

-- ---------------------------------------------------------------------------
-- Cache helpers
-- ---------------------------------------------------------------------------

--- Builds a flat list cache of all lootable items from the LootItems table.
-- Each entry contains { id, name } and is sorted alphabetically by name.
-- @return table  list of { id=number, name=string } sorted by name
function AutoLoot.buildLootItemCache()
    lootItemCache = {}
    for id, data in pairs(LootItems) do
        local name = type(data) == 'table' and (data.name or data[1]) or tostring(data)
        if name and #name > 0 then
            table.insert(lootItemCache, { id = tonumber(id), name = name })
        end
    end
    table.sort(lootItemCache, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    return lootItemCache
end

--- Finds the numeric item ID for a given name using the cache.
-- Falls back to a linear scan of LootItems when the cache is empty.
-- @param name  string  item name (case-insensitive)
-- @return number|nil  item ID or nil when not found
function AutoLoot.findItemIdByName(name)
    if not name or #name == 0 then return nil end
    local lower = name:lower()

    -- Search cache first (O(n) but avoids rebuilding frequently)
    for _, entry in ipairs(lootItemCache) do
        if entry.name:lower() == lower then
            return entry.id
        end
    end

    -- Fallback: scan LootItems directly
    for id, data in pairs(LootItems) do
        local itemName = type(data) == 'table' and (data.name or data[1]) or tostring(data)
        if itemName and itemName:lower() == lower then
            return tonumber(id)
        end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Item selector window
-- ---------------------------------------------------------------------------

--- Opens the item selector window, building the cache if necessary.
function AutoLoot.openItemSelector()
    if itemSelectorWindow then
        itemSelectorWindow:destroy()
        itemSelectorWindow = nil
    end

    if #lootItemCache == 0 then
        AutoLoot.buildLootItemCache()
    end

    itemSelectorWindow = g_ui.displayUI('item_selector')
    if not itemSelectorWindow then return end

    AutoLoot.populateItemGrid(lootItemCache)
end

--- Closes and destroys the item selector window.
function AutoLoot.closeItemSelector()
    if itemSelectorWindow then
        itemSelectorWindow:destroy()
        itemSelectorWindow = nil
    end
end

--- Populates the item grid inside the selector window with the provided list.
-- @param items  table  list of { id, name } entries
function AutoLoot.populateItemGrid(items)
    if not itemSelectorWindow then return end
    local scroll = itemSelectorWindow:getChildById('itemsScroll')
    if not scroll then return end

    scroll:destroyChildren()

    for _, entry in ipairs(items) do
        local cell = g_ui.createWidget('ItemSelectorCell', scroll)
        if cell then
            -- Label with item name
            local label = cell:getChildById('cellLabel')
            if label then
                label:setText(entry.name)
            end

            -- Optional: set item sprite when UIItem widget is present
            local icon = cell:getChildById('cellIcon')
            if icon and icon.setItemId then
                icon:setItemId(entry.id)
                icon:setVisible(true)
            end

            -- Click handler: pick this item
            cell:setTooltip(entry.name .. ' (id: ' .. tostring(entry.id) .. ')')
            cell.itemId = entry.id
            cell.itemName = entry.name
            cell.onClick = function()
                AutoLoot.closeItemSelector()
                AutoLoot.openRuleCreatorWithItem(entry.name, entry.id)
            end
        end
    end
end

--- Filters the item grid to show only items whose name contains the query string.
-- Called on every keystroke in the search box.
-- @param query  string  search string (case-insensitive)
function AutoLoot.filterItemSelector(query)
    if not itemSelectorWindow then return end
    local lower = (query or ''):lower()
    local filtered = {}
    for _, entry in ipairs(lootItemCache) do
        if lower == '' or entry.name:lower():find(lower, 1, true) then
            table.insert(filtered, entry)
        end
    end
    AutoLoot.populateItemGrid(filtered)
end

-- ---------------------------------------------------------------------------
-- Rule creator window
-- ---------------------------------------------------------------------------

--- Opens the rule creator pre-filled with the chosen item.
-- @param itemName  string  display name of the selected item
-- @param itemId    number  numeric ID of the selected item
function AutoLoot.openRuleCreatorWithItem(itemName, itemId)
    if ruleCreatorWindow then
        ruleCreatorWindow:destroy()
        ruleCreatorWindow = nil
    end

    selectedItemData = { name = itemName, id = itemId }

    ruleCreatorWindow = g_ui.displayUI('rule_creator')
    if not ruleCreatorWindow then return end

    -- Populate item info labels
    local nameLabel = ruleCreatorWindow:getChildById('selectedItemLabel')
    if nameLabel then
        nameLabel:setText(itemName)
    end

    local idLabel = ruleCreatorWindow:getChildById('itemIdLabel')
    if idLabel then
        idLabel:setText('ID: ' .. tostring(itemId))
    end

    -- Show item icon when UIItem is supported
    local icon = ruleCreatorWindow:getChildById('itemIcon')
    local placeholder = ruleCreatorWindow:getChildById('itemIconPlaceholder')
    if icon and icon.setItemId then
        icon:setItemId(itemId)
        icon:setVisible(true)
        if placeholder then placeholder:setVisible(false) end
    end
end

--- Confirms the rule creator: reads the container input and adds the rule.
function AutoLoot.confirmRuleCreator()
    if not ruleCreatorWindow or not selectedItemData then return end

    local containerInput = ruleCreatorWindow:getChildById('containerInput')
    local container = containerInput and containerInput:getText() or ''
    container = container:match('^%s*(.-)%s*$') -- trim whitespace

    if #container == 0 then
        -- Show a simple error tooltip on the input field
        if containerInput then
            containerInput:setTooltip(tr('Please enter a target container name or ID.'))
        end
        return
    end

    AutoLoot.addRule(selectedItemData.name, selectedItemData.id, container)
    AutoLoot.closeRuleCreator()
end

--- Closes and destroys the rule creator window.
function AutoLoot.closeRuleCreator()
    if ruleCreatorWindow then
        ruleCreatorWindow:destroy()
        ruleCreatorWindow = nil
    end
    selectedItemData = nil
end

-- ---------------------------------------------------------------------------
-- Rule management
-- ---------------------------------------------------------------------------

--- Adds a new loot rule and refreshes the rules list in the main window.
-- @param itemName   string  item name
-- @param itemId     number  item ID
-- @param container  string  target container name or ID
function AutoLoot.addRule(itemName, itemId, container)
    local rule = { itemName = itemName, itemId = itemId, container = container }
    table.insert(lootRules, rule)
    AutoLoot.refreshRulesList()
end

--- Removes the loot rule at the given index.
-- @param index  number  1-based index into lootRules
function AutoLoot.removeRule(index)
    table.remove(lootRules, index)
    AutoLoot.refreshRulesList()
end

--- Rebuilds the rules list widget inside the main auto-loot window.
function AutoLoot.refreshRulesList()
    if not autoLootWindow then return end
    local scroll = autoLootWindow:getChildById('rulesScroll')
    if not scroll then return end

    scroll:destroyChildren()

    for i, rule in ipairs(lootRules) do
        local row = g_ui.createWidget('LootRuleRow', scroll)
        if row then
            local label = row:getChildById('ruleLabel')
            if label then
                label:setText(rule.itemName .. '  →  ' .. rule.container)
            end
            local removeBtn = row:getChildById('removeButton')
            if removeBtn then
                local idx = i
                removeBtn.onClick = function()
                    AutoLoot.removeRule(idx)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Main window lifecycle
-- ---------------------------------------------------------------------------

--- Opens the main auto-loot window.
function AutoLoot.open()
    if autoLootWindow then
        autoLootWindow:show()
        autoLootWindow:raise()
        autoLootWindow:focus()
        return
    end

    autoLootWindow = g_ui.displayUI('autolooting')
    if autoLootWindow then
        AutoLoot.refreshRulesList()
    end
end

--- Closes the main auto-loot window and all child windows.
function AutoLoot.close()
    AutoLoot.closeItemSelector()
    AutoLoot.closeRuleCreator()
    if autoLootWindow then
        autoLootWindow:destroy()
        autoLootWindow = nil
    end
end

--- Module initialization – called by the client module loader.
function AutoLoot.init()
    AutoLoot.buildLootItemCache()
end

--- Module termination – called by the client module loader.
function AutoLoot.terminate()
    AutoLoot.close()
    lootRules = {}
    lootItemCache = {}
end
