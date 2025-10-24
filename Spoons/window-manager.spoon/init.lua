local obj = {}
obj.__index = obj

-- Metadata
obj.name = "window-manager"
obj.version = "0.1"
obj.author = "osbo <osbo@mit.edu>"
obj.license = "MIT - https://opensource.org/licenses/MIT"
obj.homepage = "https://github.com/osbo/window-manager"

-- Node class for the window tree
local Node = {}
Node.__index = Node

function Node:new(id, leaf, parent, selected, windows, position, size, split_type, split_ratio, child1, child2)
    local node = {
        id = id,
        leaf = leaf, -- boolean: true for leaf, false for internal
        parent = parent,
        position = position,
        size = size,
        
        -- leaf properties:
        selected = selected,
        windows = windows,

        -- internal properties:
        child1 = child1,
        child2 = child2,
        split_type = split_type, -- boolean: true for horizontal, false for vertical
        split_ratio = split_ratio, -- float: 0.0 to 1.0
    }
    setmetatable(node, self)
    return node
end

-- Depth-first search for the leaf node containing a given window
function Node:findNode(window)
    if self.leaf then -- leaf node
        for _, w in ipairs(self.windows) do
            -- FIX: Compare window IDs, not objects. This is more robust.
            if w:id() == window:id() then
                return self
            end
        end
        return nil
    else
        -- FIX: Added check for child1 and child2
        if self.child1 then
            local found = self.child1:findNode(window)
            if found then return found end
        end
        if self.child2 then
            local found = self.child2:findNode(window)
            if found then return found end
        end
        return nil
    end
end

    obj.trees = {} -- Array: [space_id] = { root = node, selected = node, focused_window = window }
    obj._eventListenersActive = true -- Flag to control event listener activity

-- Initialize the spoon
function obj:init()
    return self
end

-- Start the spoon
function obj:start()
    hs.window.animationDuration = 0.0
    self:setupWindowWatcher()
    self:initializeTree()
    
    -- NEW: Watch for space changes
    self.spaceWatcher = hs.spaces.watcher.new(function()
        if not obj._eventListenersActive then return end
        obj:onSpaceChanged()
    end)
    self.spaceWatcher:start()
    
    return self
end

-- Stop the spoon
function obj:stop()
    if self.windowWatcher then
        self.windowWatcher:delete()
        self.windowWatcher = nil
    end
    
    -- NEW: Stop space watcher
    if self.spaceWatcher then
        self.spaceWatcher:stop()
        self.spaceWatcher = nil
    end
    
    return self
end

---
--- NEW: Helper to check if a window should be managed
---
function obj:isWindowManageable(window)
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
        "Raycast", "System Settings", "Spotlight", "Dock", "Control Center", "Notification Center",
        "Hammerspoon", "Finder" -- Added these
    }, appName) then
        return false
    end
    
    return true
end


-- Set up window watcher
function obj:setupWindowWatcher()
    self.windowWatcher = hs.window.filter.new()

    self.windowWatcher:subscribe(hs.window.filter.windowCreated, function(window)
        if not obj._eventListenersActive then return end
        
        -- Add error handling for window operations
        local success, err = pcall(function()
            -- FIX: Add filtering
            if obj:isWindowManageable(window) then
                -- This is correct: new windows are always created on the focused space.
                local space_id = hs.spaces.focusedSpace()
                local screen = window:screen()
                if not screen then return end -- No screen
                local screen_id = screen:id()
                obj:addNode(window, space_id)
            end
        end)
        
        if not success then
            print("Error in windowCreated handler: " .. tostring(err))
        end
    end)

    self.windowWatcher:subscribe(hs.window.filter.windowFocused, function(window)
        if not obj._eventListenersActive then return end

        -- Add error handling for window operations
        local success, err = pcall(function()
            -- FIX: Add nil checks for robustness
            local screen = window:screen()
            if not screen then return end
            local screen_id = screen:id()
            local space_id = hs.spaces.focusedSpace()
            
            local tree = obj:getTreeForSpace(space_id)
            if not tree then return end
            
            -- Always track the focused window, even if not manageable
            tree.focused_window = window
            
            -- Only update selected node if the window is manageable
            if obj:isWindowManageable(window) and tree.root then
                local foundNode = tree.root:findNode(window)
                if foundNode then
                    tree.selected = foundNode
                end
            end
        end)
        
        if not success then
            print("Error in windowFocused handler: " .. tostring(err))
        end
    end)

    self.windowWatcher:subscribe(hs.window.filter.windowDestroyed, function(window)
        if not obj._eventListenersActive then return end
        -- FIX: Call the new parameterized function.
        -- It will find the window in *any* tree and remove it.
        obj:closeWindow(window)
    end)

    -- FIX: All move events now call the same robust handler
    self.windowWatcher:subscribe(hs.window.filter.windowMoved, function(window)
        -- print("Spaces: " .. hs.inspect(hs.spaces.allSpaces())) -- all spaces
        if not obj._eventListenersActive then return end
        if obj:isWindowManageable(window) then
            obj:windowMovedHandler(window)
        end
    end)
end

---
--- NEW: Get or create the tree for a specific space
--- @param space_id (string) The space ID
--- @return (table) The tree object { root, selected }
---
function obj:getTreeForSpace(space_id)
    if not space_id then
        print("Error: getTreeForSpace called with nil space_id")
        space_id = hs.spaces.focusedSpace()
    end

    if not obj.trees[space_id] then
        -- This is the first time we're seeing this space. Create a new tree.
        print("Creating new tree for space: " .. space_id)
        
        -- Get the main screen for the frame
        local screen = hs.screen.mainScreen()
        if not screen then return nil end -- No screens
        
        local frame = screen:frame()
        local new_root = Node:new(
            hs.host.uuid(),  -- Generate unique UUID for node ID
            true,        -- true = leaf node
            nil,          -- no parent
            1,
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
            selected = new_root,
            focused_window = nil
        }
    end
    
    return obj.trees[space_id]
end

---
--- NEW: Get tree for current space
--- @return (string) space_id
--- @return (table) The tree object { root, selected }
---
function obj:getCurrentTree()
    local space_id = hs.spaces.focusedSpace()
    return space_id, obj:getTreeForSpace(space_id)
end

function obj:getTreeForWindow(window)
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

-- Helper function to get window space safely
function obj:getWindowSpace(window)
    if not window then return nil end
    
    -- Get the screen this window is on
    local screen = window:screen()
    if not screen then return hs.spaces.focusedSpace() end
    
    local screen_uuid = screen:getUUID()
    
    -- Get all spaces for this screen
    local all_spaces = hs.spaces.allSpaces()
    local screen_spaces = all_spaces[screen_uuid]
    if not screen_spaces then return hs.spaces.focusedSpace() end
    
    -- Get all windows for each space on this screen and check if our window is in any of them
    for _, space_id in ipairs(screen_spaces) do
        local space_windows = hs.spaces.windowsForSpace(space_id)
        for _, space_window_id in ipairs(space_windows) do
            if space_window_id == window:id() then
                return space_id
            end
        end
    end
    
    -- Fallback: assume window is in current space
    return hs.spaces.focusedSpace()
end

-- Debug helper to print all windows in a tree
function obj:printTreeWindows(node, depth)
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
            obj:printTreeWindows(node.child1, depth + 2)
        end
        if node.child2 then
            print(indent .. "  Child2:")
            obj:printTreeWindows(node.child2, depth + 2)
        end
    end
end

---
--- REWRITTEN: Handles all window movement and space invalidation
---
function obj:windowMovedHandler(window)
    obj._eventListenersActive = false
    -- print("Event listeners inactive - windowMovedHandler")
    
    -- 1. Find the window's OLD tree
    local oldSpaceId, oldTree = obj:getTreeForWindow(window)
    
    -- 2. Get the window's NEW space
    -- FIX: Use helper function for safe space detection
    local newSpaceId = obj:getWindowSpace(window)

    if not newSpaceId then
        -- Window is likely moving to a fullscreen app or mission control
        -- print("Window moved to an invalid location (fullscreen?), re-enabling listeners.")
        
        -- Just remove it from its old tree, don't add it anywhere new
        if oldTree then
            obj:closeWindow(window, oldTree)
            if oldTree.root then
                obj:applyLayout(oldTree.root)
            end
        end
        
        obj._eventListenersActive = true -- Re-enable before returning
        return
    end
    
    -- 3. Check if the window actually moved to a new space
    if newSpaceId ~= oldSpaceId then
        local oldSpaceStr = oldSpaceId and tostring(oldSpaceId) or "nil"
        print("Window '"..window:title().."' moved trees: (" .. oldSpaceStr .. ") -> (" .. newSpaceId .. ")")
        
        -- 4. Move window: Remove from old tree
        if oldTree then
            -- print("Removing window from old tree...")
            -- We pass the specific tree to close from
            obj:closeWindow(window, oldTree) 
            if oldTree.root then
                obj:applyLayout(oldTree.root) -- I don't think this is needed
            end
        end
        
        -- 5. Move window: Add to new tree
        -- print("Adding window to new tree...")
        -- We pass the specific space to add to
        obj:addNode(window, newSpaceId) 
        
        -- No need to apply layout, addNode does it.
    end
    
    -- Re-enable event listeners after a short delay
    hs.timer.doAfter(0.1, function()
        obj._eventListenersActive = true
        -- print("Event listeners re-enabled")
    end)
end

---
--- NEW: Handle space switching
---
function obj:onSpaceChanged()    
    obj._eventListenersActive = false
    -- print("Event listeners inactive - onSpaceChanged")

    print("Space changed.")
    -- FIX: Use hs.spaces.focusedSpace() directly
    local space_id = hs.spaces.focusedSpace()
    local mainScreen = hs.screen.mainScreen()
    if not mainScreen then 
        obj._eventListenersActive = true
        return 
    end
    local screen_id = mainScreen:id()
    
    print("New space: " .. space_id .. ", main screen: " .. screen_id)
    
    -- Get the tree for the new space
    local tree = obj:getTreeForSpace(space_id)
    
    -- First, try to focus the tracked focused window (even if not manageable)
    if tree.focused_window then
        -- Check if window is still valid by trying to get its title
        local success, title = pcall(function() return tree.focused_window:title() end)
        if success and title then
            print("Focusing tracked window: " .. title)
            tree.focused_window:focus()
            -- Re-enable and return *early*
            hs.timer.doAfter(0.1, function() obj._eventListenersActive = true end)
            return
        else
            -- Window is no longer valid, clear it
            tree.focused_window = nil
        end
    end
    
    -- Fallback: Focus the selected window if available
    if tree.selected and tree.selected.leaf and #tree.selected.windows > 0 then
        if tree.selected.selected < 1 or tree.selected.selected > #tree.selected.windows then
            tree.selected.selected = 1 -- Reset index if out of bounds
        end
        print("Focusing selected window: " .. tree.selected.windows[tree.selected.selected]:title())
        tree.selected.windows[tree.selected.selected]:focus()
    elseif tree.root and tree.root.leaf and #tree.root.windows > 0 then
        if tree.root.selected < 1 or tree.root.selected > #tree.root.windows then
            tree.root.selected = 1 -- Reset index
        end
        print("Focusing root window: " .. tree.root.windows[tree.root.selected]:title())
        tree.root.windows[tree.root.selected]:focus()
    else
        print("No windows to focus in this space")
    end
    
    -- Re-enable event listeners after a short delay
    hs.timer.doAfter(0.1, function()
        obj._eventListenersActive = true
        -- print("Event listeners re-enabled")
    end)
end

---
--- Applies the layout from the tree to the actual windows
--- @param node (Node) The node to start applying layout from (usually root)
---
function obj:applyLayout(node)

    obj._eventListenersActive = false

    if not node then return end

    if node.leaf == false then -- This is an internal node
        -- This is an internal node, calculate child frames and recurse
        
        -- Calculate child frames based on split_type and split_ratio
        local f = {x = node.position.x, y = node.position.y, w = node.size.w, h = node.size.h}
        local pos1, size1, pos2, size2
    
        if node.split_type == true then -- horizontal
            pos1 = {x = f.x, y = f.y}
            size1 = {w = f.w * node.split_ratio, h = f.h}
            pos2 = {x = f.x + f.w * node.split_ratio, y = f.y}
            size2 = {w = f.w * (1.0 - node.split_ratio), h = f.h}
        else -- vertical
            pos1 = {x = f.x, y = f.y}
            size1 = {w = f.w, h = f.h * node.split_ratio}
            pos2 = {x = f.x, y = f.y + f.h * node.split_ratio}
            size2 = {w = f.w, h = f.h * (1.0 - node.split_ratio)}
        end
        
        -- Update children's frames
        if node.child1 then
            node.child1.position = pos1
            node.child1.size = size1
            obj:applyLayout(node.child1)
        end
        if node.child2 then
            node.child2.position = pos2
            node.child2.size = size2
            obj:applyLayout(node.child2)
        end
    
    else
        -- This is a leaf node, apply our frame to all windows in our stack
        local frame = {
            x = node.position.x,
            y = node.position.y,
            w = node.size.w,
            h = node.size.h
        }
        for _, win in ipairs(node.windows) do
            -- FIX: Add pcall for safety, window might be invalid
            pcall(function() win:setFrame(frame) end)
        end
    end

    hs.timer.doAfter(0.1, function()
        obj._eventListenersActive = true
    end)
end
  
---
--- REFACTORED: Can now be told which space to add to
--- @param window (hs.window) The window to add
--- @param forceSpaceId (string) Optional space ID to add to
---
function obj:addNode(window, forceSpaceId)
    -- FIX: Add check for nil window to prevent crash
    if not window or not window:id() then
        print("addNode called with invalid window, ignoring.")
        return
    end

    -- Check if window is already in any tree
    local existingTreeSpaceId, existingTree = obj:getTreeForWindow(window)
    if existingTree then
        -- This can happen if events fire out of order.
        -- If it's already in the *correct* tree, we're done.
        local targetSpaceId = forceSpaceId or obj:getWindowSpace(window)

        if existingTreeSpaceId == targetSpaceId then
            print("Window " .. window:title() .. " already in correct tree, ignoring addNode")
            return
        else
            -- It's in the *wrong* tree. This shouldn't happen, but
            -- we should remove it from the old one first.
            print("Window " .. window:title() .. " in wrong tree, removing...")
            obj:closeWindow(window, existingTree)
        end
    end

    -- NEW: Use passed-in space, or find it if nil
    local space_id = forceSpaceId
    
    if not space_id then
        space_id = obj:getWindowSpace(window)
        if not space_id then
            print("No space found for window, using focused space.")
            space_id = hs.spaces.focusedSpace()
        end
    end
    
    local tree = self:getTreeForSpace(space_id) -- Either existing or new tree for the space
    
    print("Adding new window: " .. window:title() .. " to tree (" .. space_id .. ")")
  
    -- Case 1: No root node (this is handled by getTreeForSpace,
    -- but the root might be an empty leaf).
    if tree.root.leaf and #tree.root.windows == 0 then
        print("Case 1: Adding first window to root")
        table.insert(tree.root.windows, window)
        tree.root.selected = 1
        tree.selected = tree.root
        self:applyLayout(tree.root)
        return
    end
    
    if tree.selected == nil then
        print("Error: selected_node is nil. Cannot add window.")
        -- As a fallback, let's select the root node
        tree.selected = tree.root
        if not tree.selected.leaf then
            -- Root is internal, find first leaf
            local first_leaf = tree.root
            while first_leaf and not first_leaf.leaf do
                first_leaf = first_leaf.child1 or first_leaf.child2
            end
            if first_leaf then
                tree.selected = first_leaf
            else
                print("Error: Root is internal and has no leaves. Giving up.")
                return
            end
        end
    end

    -- Case 2a: Selected leaf is empty.
    if tree.selected.leaf and #tree.selected.windows == 0 then
        print("Adding window to empty leaf: " .. tree.selected.id)
        table.insert(tree.selected.windows, window)
        tree.selected.selected = 1
        self:applyLayout(tree.root)
        return
    end
  
    -- Case 2b: Split selected leaf node into internal node, select new window.
    if not tree.selected.leaf then
        print("Error: selected_node is an internal node. Cannot split.")
        -- Find the first leaf *under* this internal node
        local first_leaf = tree.selected
        while first_leaf and not first_leaf.leaf do
            first_leaf = first_leaf.child1 -- Default to traversing left
        end
        if first_leaf then
            print("Selected node was internal, found first leaf: " .. first_leaf.id)
            tree.selected = first_leaf
        else
            print("Error: Could not find any leaf under internal node.")
            return
        end
    end

    print("Splitting leaf node: " .. tree.selected.id)
    local internal = tree.selected

    -- 1. Create child1 (for old windows)
    -- We pass the internal's (old leaf's) position/size as a placeholder.
    -- applyLayout will fix it.
    local child1 = Node:new(
        hs.host.uuid(),  -- Generate unique UUID for node ID
        true, -- leaf node
        internal, -- parent
        internal.selected, -- selected index
        internal.windows, -- windows
        {x=internal.position.x, y=internal.position.y}, -- position
        {w=internal.size.w, h=internal.size.h}, -- size
        nil, -- split type
        nil, -- split ratio
        nil, -- child1
        nil -- child2
    )

    -- 2. Create child2 (for new window)
    local child2 = Node:new(
        hs.host.uuid(),  -- Generate unique UUID for node ID
        true, -- leaf node
        internal, -- parent
        1, -- selected index
        {window}, -- windows
        {x=internal.position.x, y=internal.position.y}, -- position
        {w=internal.size.w, h=internal.size.h}, -- size
        nil, -- split type
        nil, -- split ratio
        nil, -- child1
        nil -- child2
    )

    -- 3. Convert the (formerly) selected leaf into an internal node
    if internal.parent then
        -- Alternate split direction from parent
        internal.split_type = not internal.parent.split_type
    else 
        -- No parent, this is the root node, default to horizontal
        internal.split_type = true
    end
    internal.split_ratio = 0.5
    internal.child1 = child1
    internal.child2 = child2
    internal.windows = nil
    internal.selected = nil
    internal.leaf = false

    -- 4. Set the new leaf as selected
    tree.selected = child2
    
    -- 5. Apply the layout. This will do all the math.
    self:applyLayout(tree.root)
    return
end

---
--- REFACTORED: Can now be told which tree to close from
--- @param window (hs.window) The window to close
--- @param optionalTree (table) An optional tree to search in first
---
function obj:closeWindow(window, optionalTree)
    -- FIX: Add check for window and window:id()
    if not window or not window:id() then return end
    
    local tree = optionalTree
    local node = nil
    
    -- If we weren't given a tree (e.g., from windowDestroyed), find it.
    if not tree then
        local space_id, screen_id
        space_id, tree = obj:getTreeForWindow(window)
        if not tree then
            -- print("closeWindow: Window not found in any tree.")
            return -- Window wasn't managed
        end
    end

    if not tree.root then return end -- Tree is empty
    
    node = tree.root:findNode(window)
    if not node then 
        -- print("closeWindow: Window not found in provided tree.")
        return 
    end -- Window wasn't in this tree
    
    -- print("Closing window in tree: " .. window:title())
    
    -- FIX: Loop compares IDs
    local found = false
    for i, w in ipairs(node.windows) do
        if w:id() == window:id() then
            table.remove(node.windows, i)
            found = true
            break
        end
    end
    
    if not found then return end -- Window wasn't in this node?
    
    -- If node is now empty, collapse it
    if #node.windows == 0 then
        obj:collapseNode(tree, node) -- NEW: Pass the tree object
    else
        -- FIX: Adjust selected index if it's now out of bounds
        if node.selected > #node.windows then
            node.selected = #node.windows
        end
        -- Reapply layout after window removal
        self:applyLayout(tree.root)
    end
end

function obj:collapseNode(tree, node) -- NEW: Takes tree and node
    if not node.parent then
        -- This is the root node. We don't delete it,
        -- we just reset it to be an empty leaf.
        print("Collapsing root node.")
        local frame = node.position
        local size = node.size
        -- Reset root to a clean leaf state
        tree.root = Node:new(
            hs.host.uuid(), true, nil, 1, {},
            frame, size, nil, nil, nil, nil
        )
        tree.selected = tree.root
        return
    end
    
    local parent = node.parent
    local sibling = (parent.child1 == node) and parent.child2 or parent.child1
    
    if not sibling then
        -- This should not happen, but if it does, collapse the parent
        print("Error: Node to collapse has no sibling. Collapsing parent.")
        obj:collapseNode(tree, parent)
        return
    end
    
    if parent.parent then
        -- Parent has a parent, replace parent with sibling
        if parent.parent.child1 == parent then
            parent.parent.child1 = sibling
        else
            parent.parent.child2 = sibling
        end
        sibling.parent = parent.parent
        -- The sibling's position and size must be updated to fill the parent's frame
        sibling.position = parent.position
        sibling.size = parent.size
    else
        -- Parent is root, make sibling the new root
        tree.root = sibling
        sibling.parent = nil
        -- The sibling's position and size must be updated to fill the root frame
        sibling.position = parent.position
        sibling.size = parent.size
    end
    
    -- Update selected node if it was the collapsed node
    if tree.selected == node or tree.selected == parent then
        -- Find the first leaf in the sibling to select
        local new_selected = sibling
        while new_selected and not new_selected.leaf do
            new_selected = new_selected.child1 or new_selected.child2
        end
        tree.selected = new_selected or tree.root -- Fallback to root
    end
    
    -- Reapply layout
    self:applyLayout(tree.root)
end

function obj:initializeTree()
    -- Initialize all spaces using proper space detection
    print("Initializing trees for all spaces...")

    obj._eventListenersActive = false
    print("Event listeners inactive - initializeTree")
    
    -- Get all spaces from all screens
    local all_spaces = hs.spaces.allSpaces()
    print("All spaces: " .. hs.inspect(all_spaces))
    
    -- Loop over each screen's spaces
    for screen_uuid, spaces in pairs(all_spaces) do
        print("Screen " .. screen_uuid .. " has spaces: " .. hs.inspect(spaces))
        
        -- For each space on this screen
        for _, space_id in ipairs(spaces) do
            print("Initializing space " .. space_id)
            
            -- Get windows in this specific space using hs.spaces.windowsForSpace
            local space_window_ids = hs.spaces.windowsForSpace(space_id)
            print("  Raw window IDs in space " .. space_id .. ": " .. #space_window_ids)
            
            -- Convert window IDs to window objects and filter manageable ones
            local manageable_windows = {}
            for _, window_id in ipairs(space_window_ids) do
                -- Find the window object by ID
                local window = hs.window.find(window_id)
                if window and obj:isWindowManageable(window) then
                    table.insert(manageable_windows, window)
                    print("    -> manageable window: " .. (window:title() or "unknown"))
                end
            end
            
            print("Space " .. space_id .. " has " .. #manageable_windows .. " manageable windows")
            
            -- Initialize tree for this space
            local tree = self:getTreeForSpace(space_id)
            
            -- Add all windows to the tree
            for _, window in ipairs(manageable_windows) do
                obj:addNode(window, space_id)
            end
        end
    end

    hs.timer.doAfter(0.1, function()
        obj._eventListenersActive = true
        print("Event listeners re-enabled - initializeTree")
    end)
end

return obj

