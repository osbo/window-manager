-- Helper utility functions

local helpers = {}

-- Helper to check if a window should be managed
function helpers.isWindowManageable(window)
    if not window then return false end
    
    -- FIX: Add check for window:id() as it can be nil during creation
    local success, _ = pcall(function() return window:id() end)
    if not success then return false end
    
    -- Check for valid window state
    if not window:isStandard() or window:isMinimized() or window:isFullScreen() then
        return false
    end

    -- Check for floating windows or dialogs
    local subrole = window:subrole()
    if subrole == "AXFloatingWindow" or subrole == "AXDialog" or subrole == "AXSystemDialog" then
        return false
    end
    
    -- Filter out specific apps
    local app = window:application()
    if not app then return false end
    
    local appName = app:name()
    if hs.fnutils.contains({
        "Raycast", "System Settings", "Spotlight", "Dock", "Control Center", "Notification Center", "Finder", "FaceTime"
    }, appName) then
        return false
    end
    
    return true
end

function helpers.getTreeForSpace(obj, space_id)
    if not space_id then
        -- print("Error: getTreeForSpace called with nil space_id")
        space_id = hs.spaces.focusedSpace()
    end

    if not obj.trees[space_id] then
        -- This is the first time we're seeing this space. Create a new tree.
        -- print("Creating new tree for space: " .. space_id)
        
        -- Get the main screen for the frame
        local screen = helpers.getScreenForSpace(obj, space_id)
        if not screen then return nil end -- No screens
        
        local frame = screen:frame()
        local Node = obj.Node
        local new_root = Node:new(
            hs.host.uuid(),  -- Generate unique UUID for node ID
            true,        -- true = leaf node
            nil,          -- no parent
            {},           -- empty windows
            {x=frame.x, y=frame.y},
            {w=frame.w, h=frame.h},
            nil, -- no split type
            nil, -- no split ratio
            nil, -- no child1
            nil -- no child2
        )
        obj.trees[space_id] = {
            root = new_root,
            selected = new_root
        }
    end
    
    return obj.trees[space_id]
end

---
--- Get screen for a given space ID using hs.spaces.allSpaces()
--- @param space_id (string) The space ID to find the screen for
--- @return (hs.screen|nil) The screen object for the space, or nil if not found
---
function helpers.getScreenForSpace(obj, space_id)
    if not space_id then return nil end
    
    local allSpaces = hs.spaces.allSpaces()
    if not allSpaces then return nil end
    
    -- Iterate through all screens and their spaces
    for screen_id, spaces in pairs(allSpaces) do
        if spaces then
            for _, space in ipairs(spaces) do
                if space == space_id then
                    return hs.screen.find(screen_id)
                end
            end
        end
    end
    
    return nil
end

---
--- NEW: Get tree for current space
--- @return (string) space_id
--- @return (table) The tree object { root, selected }
---
function helpers.getCurrentTree(obj)
    local space_id = hs.spaces.focusedSpace()
    return space_id, helpers.getTreeForSpace(obj, space_id)
end

function helpers.getTreeForWindow(obj, window)
    if not window then return nil, nil end
    
    -- Loop through all trees
    for space_id, tree in pairs(obj.trees) do
        if tree and tree.root then
            -- FIX: Pass window object, findNode will compare ID
            if tree.root:findNode(window) then
                return space_id, tree
            end
        end
    end
    
    return nil, nil
end

function helpers.getNodeAtPosition(obj, x, y, ignoreWindow)
    -- print("getNodeAtPosition called with: " .. x .. ", " .. y)
    
    -- Get all windows and find the first one that contains the point
    local allWindows = hs.window.orderedWindows()
    for _, window in ipairs(allWindows) do
        if helpers.isWindowManageable(window) and (not ignoreWindow or window:id() ~= ignoreWindow:id()) then
            local frame = window:frame()
            if x >= frame.x and x < frame.x + frame.w and
               y >= frame.y and y < frame.y + frame.h then
                -- print("Found window at position: " .. window:title())
                
                -- Find the node containing this window
                local space_id, tree = helpers.getTreeForWindow(obj, window)
                if tree and tree.root then
                    local node = tree.root:findNode(window)
                    if node then
                        return node
                    end
                end
            end
        end
    end
    
    -- print("No window found at position: " .. x .. ", " .. y)
    return nil
end

-- Find a neighbor node in a given direction, working across trees
-- @param window The window to find a neighbor for
-- @param direction String: "left", "right", "up", "down"
-- @return The neighbor node if found, nil otherwise
function helpers.findNeighbor(obj, window, direction)
    if not window then
        return nil
    end
    
    -- Get the window's frame directly
    local frame = window:frame()
    
    -- Calculate the midpoint of the appropriate edge
    local searchX, searchY
    local displacement = 10 -- Small displacement to search beyond the edge
    
    if direction == "left" then
        -- Search to the left of the left edge
        searchX = frame.x - displacement
        searchY = frame.y + frame.h / 2 -- Middle of the left edge
    elseif direction == "right" then
        -- Search to the right of the right edge
        searchX = frame.x + frame.w + displacement
        searchY = frame.y + frame.h / 2 -- Middle of the right edge
    elseif direction == "up" then
        -- Search above the top edge
        searchX = frame.x + frame.w / 2 -- Middle of the top edge
        searchY = frame.y - displacement
    elseif direction == "down" then
        -- Search below the bottom edge
        searchX = frame.x + frame.w / 2 -- Middle of the bottom edge
        searchY = frame.y + frame.h + displacement
    else
        -- print("Invalid direction: " .. tostring(direction))
        return nil
    end
    
    -- print("Searching for neighbor in direction '" .. direction .. "' at position: " .. searchX .. ", " .. searchY)
    
    -- Use the existing getNodeAtPosition function
    local neighborNode = helpers.getNodeAtPosition(obj, searchX, searchY)
    if neighborNode then
        -- print("Found neighbor: " .. (neighborNode.windows and neighborNode.windows[1] and neighborNode.windows[1]:title() or "Internal node"))
        return neighborNode
    end
    
    -- print("No neighbor found in direction '" .. direction .. "'")
    return nil
end

-- Debug helper to print all windows in a tree
function helpers.printTreeWindows(obj, node, depth)
    if not node then
        print(string.rep("  ", depth) .. "nil")
        return
    end
    
    local indent = string.rep("  ", depth)
    if node.leaf then
        local windowTitles = {}
        for _, win in ipairs(node.windows) do
            -- FIX: Add pcall for safety, window might be invalid
            local success, title = pcall(function() return win:title() end)
            if success then
                table.insert(windowTitles, title)
            else
                table.insert(windowTitles, "[Invalid Window]")
            end
        end
        print(indent .. "Leaf: [" .. table.concat(windowTitles, ", ") .. "]")
    else
        print(indent .. "Internal (split: " .. (node.split_type and "horizontal" or "vertical") .. ")")
        if node.child1 then
            print(indent .. "  Child1:")
            helpers.printTreeWindows(obj, node.child1, depth + 2)
        end
        if node.child2 then
            print(indent .. "  Child2:")
            helpers.printTreeWindows(obj, node.child2, depth + 2)
        end
    end
end

return helpers

