-- Menu bar functionality for window manager

local menu_bar = {}

-- Helper function to safely get window title
local function getWindowTitle(window)
    local success, title = pcall(function() return window:title() end)
    if success and title then
        return title
    end
    return "[Invalid Window]"
end

-- Helper function to format tree structure as menu items
local function buildTreeMenuItems(node, depth)
    local items = {}
    local indent = string.rep("  ", depth)
    
    if not node then
        return items
    end
    
    if node.leaf then
        -- Leaf node: show windows
        if #node.windows > 0 then
            local windowTitles = {}
            for _, win in ipairs(node.windows) do
                table.insert(windowTitles, getWindowTitle(win))
            end
            local title = indent .. "Leaf: [" .. table.concat(windowTitles, ", ") .. "]"
            table.insert(items, { title = title })
        else
            table.insert(items, { title = indent .. "Leaf: [empty]" })
        end
    else
        -- Internal node: show split type
        local splitType = node.split_type and "horizontal" or "vertical"
        table.insert(items, { title = indent .. "Internal (" .. splitType .. ")" })
        
        -- Add children
        if node.child1 then
            local child1Items = buildTreeMenuItems(node.child1, depth + 1)
            for _, item in ipairs(child1Items) do
                table.insert(items, item)
            end
        end
        if node.child2 then
            local child2Items = buildTreeMenuItems(node.child2, depth + 1)
            for _, item in ipairs(child2Items) do
                table.insert(items, item)
            end
        end
    end
    
    return items
end

-- Build the complete menu structure
function menu_bar.buildMenu(obj, helpers)
    local menu = {}
    
    -- State information
    local state = "Active"
    if obj.stopWM then
        state = "Paused"
        if obj.stoppedFromCommand then
            state = state .. " (Command)"
        elseif obj.stoppedFromScreens then
            state = state .. " (Single Screen)"
        end
    end
    table.insert(menu, { title = "State: " .. state })
    table.insert(menu, { title = "-" }) -- Separator
    
    -- Tree structure for each space
    local hasTrees = false
    for space_id, tree in pairs(obj.trees) do
        if tree and tree.root then
            hasTrees = true
            local spaceTitle = "Space: " .. tostring(space_id)
            table.insert(menu, { title = spaceTitle })
            
            -- Add tree structure
            local treeItems = buildTreeMenuItems(tree.root, 0)
            for _, item in ipairs(treeItems) do
                table.insert(menu, item)
            end
            
            -- Show selected node indicator if available
            if tree.selected then
                local selectedWindows = {}
                if tree.selected.leaf then
                    for _, win in ipairs(tree.selected.windows) do
                        table.insert(selectedWindows, getWindowTitle(win))
                    end
                end
                if #selectedWindows > 0 then
                    table.insert(menu, { title = "  → Selected: [" .. table.concat(selectedWindows, ", ") .. "]" })
                end
            end
            
            table.insert(menu, { title = "-" }) -- Separator
        end
    end
    
    if not hasTrees then
        table.insert(menu, { title = "No trees" })
        table.insert(menu, { title = "-" }) -- Separator
    end
    
    -- All manageable windows
    table.insert(menu, { title = "All Manageable Windows:" })
    local allWindows = hs.window.orderedWindows()
    local manageableCount = 0
    for _, window in ipairs(allWindows) do
        if helpers.isWindowManageable(window) then
            manageableCount = manageableCount + 1
            local title = getWindowTitle(window)
            local app = window:application()
            local appName = app and app:name() or "Unknown"
            local windowInfo = "  " .. appName .. ": " .. title
            table.insert(menu, { title = windowInfo })
        end
    end
    
    if manageableCount == 0 then
        table.insert(menu, { title = "  (none)" })
    end
    
    return menu
end

-- Setup the menu bar item
function menu_bar.setup(obj, helpers)
    -- Create menubar item
    obj.menubar = hs.menubar.new()
    
    -- Set initial title
    obj.menubar:setTitle("WM")
    
    -- Set menu with dynamic content
    obj.menubar:setMenu(function()
        return menu_bar.buildMenu(obj, helpers)
    end)
    
    return obj.menubar
end

return menu_bar

