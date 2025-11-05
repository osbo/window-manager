-- Tree manipulation operations

local tree_operations = {}

function tree_operations.addNode(obj, Node, helpers, window, tree, child, split_type)
    if not window or not window:id() then return end
    
    -- Use current space tree if none provided
    if not tree then
        local space_id = hs.spaces.focusedSpace()
        tree = helpers.getTreeForSpace(obj, space_id)
    end
    
    -- Default to child2 if no child specified
    child = child or 2
    
    -- Use existing logic for split_type if not provided
    if split_type == nil then
        if tree.selected and tree.selected.parent then
            split_type = not tree.selected.parent.split_type
        else
            split_type = true -- default to horizontal
        end
    end
    
    -- print("Adding window: " .. window:title() .. " to tree")
    
    -- Case 1: Empty root
    if tree.root.leaf and #tree.root.windows == 0 then
        table.insert(tree.root.windows, 1, window)
        tree.selected = tree.root
        return
    end
    
    -- Case 2: Empty selected leaf
    if tree.selected and tree.selected.leaf and #tree.selected.windows == 0 then
        table.insert(tree.selected.windows, 1, window)
        return
    end
    
    -- Case 3: Split the selected leaf
    local internal = tree.selected or tree.root
    
    -- Create child1 (existing windows)
    local child1 = Node:new(
        hs.host.uuid(), true, internal, internal.windows or {},
        {x=internal.position.x, y=internal.position.y}, {w=internal.size.w, h=internal.size.h},
        nil, nil, nil, nil
    )
    
    -- Create child2 (new window)
    local child2 = Node:new(
        hs.host.uuid(), true, internal, {window},
        {x=internal.position.x, y=internal.position.y}, {w=internal.size.w, h=internal.size.h},
        nil, nil, nil, nil
    )
    
    -- Convert to internal node
    internal.split_type = split_type
    internal.split_ratio = 0.5
    internal.windows = nil
    internal.leaf = false
    
    -- Assign children based on position parameter
    if child == 1 then
        -- New window goes to child1 (left/top), existing windows to child2
        internal.child1 = child2  -- new window
        internal.child2 = child1 -- existing windows
        tree.selected = child2   -- select the new window
    else
        -- New window goes to child2 (right/bottom), existing windows to child1
        internal.child1 = child1 -- existing windows
        internal.child2 = child2 -- new window
        tree.selected = child2   -- select the new window
    end
end

function tree_operations.addWindowToStack(obj, window, tree)
    if not window or not window:id() then return end
    if not tree or not tree.selected then return end
    
    -- Add window to the front of the stack (first position for frontmost)
    table.insert(tree.selected.windows, 1, window)
    
    -- print("Added window to stack: " .. window:title() .. " (index 1)")
end

function tree_operations.closeWindow(obj, helpers, window, optionalTree)
    -- FIX: Add check for window and window:id()
    if not window or not window:id() then return end
    
    local tree = optionalTree
    local node = nil
    
    -- If we weren't given a tree (e.g., from windowDestroyed), find it.
    if not tree then
        local space_id, screen_id
        space_id, tree = helpers.getTreeForWindow(obj, window)
        if not tree then
            print("closeWindow: Window not found in any tree.")
            return -- Window wasn't managed
        end
    end

    if not tree.root then return end -- Tree is empty
    
    node = tree.root:findNode(window)
    if not node then 
        print("closeWindow: Window not found in provided tree.")
        return 
    end -- Window wasn't in this tree
    
    print("Closing window in tree: " .. window:title())
    
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
        tree_operations.collapseNode(obj, tree, node)
    end
end

function tree_operations.collapseNode(obj, tree, node)
    if not node.parent then
        -- This is a root node that became empty - reset it to empty leaf state
        print("Root node became empty, resetting to empty leaf state")
        node.leaf = true
        node.windows = {}
        node.child1 = nil
        node.child2 = nil
        node.split_type = nil
        node.split_ratio = nil
        tree.selected = node
        return
    end
    
    local parent = node.parent
    local sibling = (parent.child1 == node) and parent.child2 or parent.child1
    
    if not sibling then
        -- This should not happen, but if it does, collapse the parent
        print("Error: Node to collapse has no sibling. Collapsing parent.")
        tree_operations.collapseNode(obj, tree, parent)
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
end

-- Recursively find and collapse all empty leaf nodes in a single tree
function tree_operations.cleanupEmptyNodesInTree(obj, tree)
    if not tree or not tree.root then return false end
    
    local changed = true
    local iterations = 0
    local max_iterations = 10  -- Safety limit to prevent infinite loops
    
    -- Keep cleaning until no more changes
    while changed and iterations < max_iterations do
        changed = false
        iterations = iterations + 1
        
        -- Recursively process all nodes
        local function processNode(node)
            if not node then return false end
            
            local nodeChanged = false
            
            if not node.leaf then
                -- Internal node: recurse into children first
                if node.child1 then
                    nodeChanged = processNode(node.child1) or nodeChanged
                end
                if node.child2 then
                    nodeChanged = processNode(node.child2) or nodeChanged
                end
            else
                -- Leaf node: remove invalid windows first
                if node.windows then
                    local valid_windows = {}
                    for _, win in ipairs(node.windows) do
                        if win then
                            -- Safely check if window is still valid
                            local success, id = pcall(function() return win:id() end)
                            if success and id then
                                -- Try to access a property to verify window is still valid
                                local screenSuccess = pcall(function() return win:screen() end)
                                if screenSuccess then
                                    table.insert(valid_windows, win)
                                end
                            end
                        end
                    end
                    if #valid_windows ~= #node.windows then
                        node.windows = valid_windows
                        nodeChanged = true
                    end
                end
                
                -- If node is now empty, collapse it
                if not node.windows or #node.windows == 0 then
                    if node.parent or (tree.root == node) then
                        tree_operations.collapseNode(obj, tree, node)
                        nodeChanged = true
                    end
                end
            end
            
            return nodeChanged
        end
        
        changed = processNode(tree.root) or changed
    end
    
    return changed
end

-- Clean up empty nodes in all trees (wrapper for backward compatibility)
function tree_operations.cleanupEmptyNodes(obj)
    local anyChanged = false
    for space_id, tree in pairs(obj.trees) do
        if tree and tree.root then
            local changed = tree_operations.cleanupEmptyNodesInTree(obj, tree)
            anyChanged = anyChanged or changed
        end
    end
    return anyChanged
end

function tree_operations.refreshTree(obj, helpers, tree, windows, space_id)
    local windows_in_tree = {}
    if tree.root then
        windows_in_tree = tree.root:getAllLeafWindows()
    end

    local screen_windows_by_id = {}
    for _, window in ipairs(windows) do
        local id_success, window_id = pcall(function() return window:id() end)
        if id_success and window_id then
            screen_windows_by_id[window_id] = window
        end
    end

    local tree_windows_by_id = {}
    for _, window in ipairs(windows_in_tree) do
        local id_success, window_id = pcall(function() return window:id() end)
        if id_success and window_id then
            tree_windows_by_id[window_id] = window
        end
    end

    local windows_to_add = {}
    for _, window in ipairs(windows) do
        local id_success, window_id = pcall(function() return window:id() end)
        if id_success and window_id and not tree_windows_by_id[window_id] then
            table.insert(windows_to_add, window)
        end
    end
    
    -- Find windows to remove (in tree but not in the provided window list, not manageable, or on wrong space)
    local windows_to_remove = {}
    local seen_window_ids = {} -- Track window IDs to detect duplicates
    
    -- Get the screen for this space to validate window locations
    local space_screen = nil
    if space_id then
        space_screen = helpers.getScreenForSpace(obj, space_id)
    end
    
    for _, window in ipairs(windows_in_tree) do
        local should_remove = false
        
        -- Safely get window ID - if we can't, trust previous state and skip
        local id_success, window_id = pcall(function() return window:id() end)
        if not id_success or not window_id then
            -- Can't get window ID - trust previous state, let cleanup handle invalid refs
            goto continue
        end
        
        -- Check if this window ID has been seen before (duplicate detection)
        if seen_window_ids[window_id] then
            should_remove = true
        else
            -- Mark this window ID as seen
            seen_window_ids[window_id] = true
            
            -- Only remove if window is clearly not in the current window list for this space
            -- Don't call isWindowManageable here as it may fail on invalid windows
            -- Trust that if it's in the current list, it's valid
            if not screen_windows_by_id[window_id] then
                should_remove = true
            end
        end
        
        if should_remove then
            table.insert(windows_to_remove, window)
        end
        
        ::continue::
    end

    for _, window in ipairs(windows_to_remove) do
        tree_operations.closeWindow(obj, helpers, window, tree)
    end

    for _, window in ipairs(windows_to_add) do
        tree_operations.addNode(obj, obj.Node, helpers, window, tree)
    end
    
    -- Final cleanup pass: remove any invalid window references and collapse empty nodes
    if tree.root then
        tree_operations.cleanupEmptyNodesInTree(obj, tree)
    end
end

function tree_operations.refreshTrees(obj, helpers)
    -- Throttle refresh calls to prevent excessive calls
    local currentTime = hs.timer.absoluteTime()
    if obj.lastRefreshTime > 0 and (currentTime - obj.lastRefreshTime) < 1000000000 then -- 1 second in nanoseconds
        print("Throttling refresh call - too soon since last refresh")
        return
    end
    
    -- Update lastRefreshTime
    obj.lastRefreshTime = currentTime
    
    -- Prevent recursive calls
    if obj._refreshing then
        print("Already refreshing, skipping...")
        return
    end
    
    obj._refreshing = true
    print("Refreshing trees")

    local active_windows_by_spaces = {}
    local allWindows = hs.window.orderedWindows()
    
    -- Get all active spaces (mapping space_id -> screen_id)
    local activeSpaces = hs.spaces.activeSpaces()
    local space_by_screen = {} -- Map screen_id -> space_id for active spaces
    for space_id, screen_id in pairs(activeSpaces) do
        space_by_screen[screen_id] = space_id
    end

    -- Group windows by the active space on their screen
    for _, window in ipairs(allWindows) do
        -- Safely check if window is manageable - if it fails, skip it (trust previous state)
        local manageable_success, is_manageable = pcall(function() return helpers.isWindowManageable(window) end)
        if manageable_success and is_manageable then
            local success, window_screen = pcall(function() return window:screen() end)
            if success and window_screen then
                local screen_id = window_screen:id()
                -- Use the active space on this window's screen
                local window_space = space_by_screen[screen_id]
                
                -- Fallback: if screen not in active spaces, get active space directly
                if not window_space then
                    window_space = hs.spaces.activeSpaceOnScreen(screen_id)
                end
                
                if window_space then
                    if not active_windows_by_spaces[window_space] then
                        active_windows_by_spaces[window_space] = {}
                    end
                    table.insert(active_windows_by_spaces[window_space], window)
                end
            end
        end
        -- If isWindowManageable fails or returns false, skip this window - trust previous state
    end

    -- Only refresh trees for spaces that have active windows or exist in our tree collection
    for space_id, windows in pairs(active_windows_by_spaces) do
        local tree = helpers.getTreeForSpace(obj, space_id)
        if tree then
            tree_operations.refreshTree(obj, helpers, tree, windows, space_id)
        end
    end
    
    -- Also refresh any existing trees that don't have windows (to clean up)
    for space_id, tree in pairs(obj.trees) do
        if tree and not active_windows_by_spaces[space_id] then
            -- This space has no active windows, refresh with empty list to clean up
            tree_operations.refreshTree(obj, helpers, tree, {}, space_id)
        end
    end

    -- Clear the refreshing flag
    obj._refreshing = false
end

function tree_operations.rotateLeft(obj, Node, helpers)
    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        -- print("No focused window found")
        return false
    end
    
    local space_id, tree = helpers.getTreeForWindow(obj, currentWindow)
    if not tree or not tree.root or tree.root.leaf then
        -- print("No tree found for focused window: " .. currentWindow:title())
        return false
    end

    -- print("Tree before rotate left:")
    helpers.printTreeWindows(obj, tree.root, 0)
    
    local root = tree.root
    local child1 = root.child1
    local child2 = root.child2
    local selected = tree.selected

    if child2.leaf then 
        -- print("Child2 is a leaf, can't rotate left")
        return false
    end
    
    local child2child1 = child2.child1
    local child2child2 = child2.child2

    -- Create new root node - inherits root's split properties but takes child2's content
    local newRoot = Node:new(
        child2.id,
        child2.leaf,
        nil, -- parent will be set later
        child2.windows,
        root.position,
        root.size,
        root.split_type,    -- Keep root's split type
        root.split_ratio,   -- Keep root's split ratio
        nil, -- child1 will be set below
        nil  -- child2 will be set below
    )

    -- Create new child1 - inherits child2's split properties but takes root's content
    local newChild1 = Node:new(
        root.id,
        root.leaf,
        newRoot,
        root.windows,
        root.position,
        root.size,
        child2.split_type,    -- Use child2's split type
        child2.split_ratio,   -- Use child2's split ratio
        child1, -- original child1
        child2child1 -- child2's first child
    )

    -- Set up the new structure
    newRoot.child1 = newChild1
    newRoot.child2 = child2child2
    child2child2.parent = newRoot

    -- Update child1 and child2child1 parents
    if child1 then
        child1.parent = newChild1
    end
    if child2child1 then
        child2child1.parent = newChild1
    end

    -- Replace the root
    tree.root = newRoot

    -- Update selection
    if selected == root then 
        tree.selected = newRoot
    elseif selected == child2 then
        tree.selected = newRoot
    elseif selected == child1 then
        tree.selected = child2child1
    elseif selected == child2child1 then
        tree.selected = child1
    elseif selected == child2child2 then
        tree.selected = newRoot
    end
    
    -- print("Tree after rotate left:")
    helpers.printTreeWindows(obj, tree.root, 0)
    
    -- Apply layout to all trees
    obj:applyLayout(tree.root)
    return true
end

function tree_operations.rotateRight(obj, Node, helpers)
    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        -- print("No focused window found")
        return false
    end
    
    local space_id, tree = helpers.getTreeForWindow(obj, currentWindow)
    if not tree or not tree.root or tree.root.leaf then
        -- print("No tree found for focused window: " .. currentWindow:title())
        return false
    end

    -- print("Tree before rotate right:")
    helpers.printTreeWindows(obj, tree.root, 0)
    
    local root = tree.root
    local child1 = root.child1
    local child2 = root.child2
    local selected = tree.selected

    if child1.leaf then 
        -- print("Child1 is a leaf, can't rotate right")
        return false
    end
    
    local child1child1 = child1.child1
    local child1child2 = child1.child2

    -- Create new root node - inherits root's split properties but takes child1's content
    local newRoot = Node:new(
        child1.id,
        child1.leaf,
        nil, -- parent will be set later
        child1.windows,
        root.position,
        root.size,
        root.split_type,    -- Keep root's split type
        root.split_ratio,   -- Keep root's split ratio
        nil, -- child1 will be set below
        nil  -- child2 will be set below
    )

    -- Create new child2 - inherits child1's split properties but takes root's content
    local newChild2 = Node:new(
        root.id,
        root.leaf,
        newRoot,
        root.windows,
        root.position,
        root.size,
        child1.split_type,    -- Use child1's split type
        child1.split_ratio,   -- Use child1's split ratio
        child1child2, -- child1's second child
        child2 -- original child2
    )

    -- Set up the new structure
    newRoot.child1 = child1child1
    newRoot.child2 = newChild2
    child1child1.parent = newRoot

    -- Update child1child2 and child2 parents
    if child1child2 then
        child1child2.parent = newChild2
    end
    if child2 then
        child2.parent = newChild2
    end

    -- Replace the root
    tree.root = newRoot

    -- Update selection
    if selected == root then 
        tree.selected = newRoot
    elseif selected == child1 then
        tree.selected = newRoot
    elseif selected == child1child1 then
        tree.selected = newRoot
    elseif selected == child1child2 then
        tree.selected = child2
    elseif selected == child2 then
        tree.selected = child1child2
    end
    
    -- print("Tree after rotate right:")
    helpers.printTreeWindows(obj, tree.root, 0)
    
    -- Apply layout to all trees
    obj:applyLayout(tree.root)
    return true
end

function tree_operations.reflect(obj, helpers)
    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        -- print("No focused window found")
        return false
    end
    
    local space_id, tree = helpers.getTreeForWindow(obj, currentWindow)
    if not tree or not tree.root then
        -- print("No tree found for focused window: " .. currentWindow:title())
        return false
    end
    
    local node = tree.root:findNode(currentWindow)
    if not node then
        -- print("Focused window not found in tree")
        return false
    end
    
    local parent = node.parent
    if not parent then
        -- print("Focused window's node has no parent (it's the root)")
        return false
    end
    
    -- print("Reflecting parent node of focused window")
    tree_operations.reflectNode(obj, parent)
    
    -- Apply layout to all trees
    obj:applyLayout(parent)
    
    return true
end

-- Reflect a node by switching between horizontal and vertical split types (recursive)
-- @param node The node to reflect
function tree_operations.reflectNode(obj, node)
    if not node or node.leaf then
        return
    end
    
    -- print("Reflecting node with split_type: " .. tostring(node.split_type))
    
    -- Switch split type
    node.split_type = not node.split_type
    
    -- If switching from vertical to horizontal, swap children
    if node.split_type then -- now horizontal (was vertical)
        -- print("Swapping children for vertical to horizontal transition")
        node.child1, node.child2 = node.child2, node.child1
        node.split_ratio = 1 - node.split_ratio
    end
    
    -- Apply recursively to children
    if node.child1 then
        tree_operations.reflectNode(obj, node.child1)
    end
    if node.child2 then
        tree_operations.reflectNode(obj, node.child2)
    end
end

-- Gather all windows from the parent's children and convert parent to leaf
-- @return true if successful, false otherwise
function tree_operations.gatherNodes(obj, helpers)
    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        -- print("No focused window found")
        return false
    end
    
    local space_id, tree = helpers.getTreeForWindow(obj, currentWindow)
    if not tree or not tree.root then
        -- print("No tree found for focused window: " .. currentWindow:title())
        return false
    end
    
    local node = tree.root:findNode(currentWindow)
    if not node then
        -- print("Focused window not found in tree")
        return false
    end
    
    local parent = node.parent
    if not parent then
        -- print("Focused window's node has no parent (it's the root)")
        return false
    end
    
    -- print("Gathering nodes from parent")
    
    -- Use the existing getAllLeafWindows method
    local allWindows = parent:getAllLeafWindows()
    
    -- Convert parent to leaf node
    parent.leaf = true
    parent.windows = allWindows
    parent.child1 = nil
    parent.child2 = nil
    parent.split_type = nil
    parent.split_ratio = nil
    
    -- Update tree selection to the parent
    tree.selected = parent
    
    -- Apply layout to all trees
    obj:applyLayout(parent)
    
    -- print("Successfully gathered " .. #allWindows .. " windows into parent node")
    return true
end

-- Explode current node's windows into separate nodes
-- @return true if successful, false otherwise
function tree_operations.explodeNode(obj, helpers)
    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        -- print("No focused window found")
        return false
    end
    
    local space_id, tree = helpers.getTreeForWindow(obj, currentWindow)
    if not tree or not tree.root then
        -- print("No tree found for focused window: " .. currentWindow:title())
        return false
    end
    
    local node = tree.root:findNode(currentWindow)
    if not node then
        -- print("Focused window not found in tree")
        return false
    end
    
    -- Save the windows table before making any changes
    local windowsToSplit = {}
    for _, window in ipairs(node.windows) do
        table.insert(windowsToSplit, window)
    end
    
    if #windowsToSplit <= 1 then
        -- print("Node has only one window, nothing to split")
        return false
    end
    
    -- print("Exploding " .. #windowsToSplit .. " windows into separate nodes")
    
    -- Keep the first window (now the most recently focused) in the current node
    local firstWindow = windowsToSplit[1]
    node.windows = {firstWindow}
    
    -- Add each remaining window as a new node
    for i = 2, #windowsToSplit do
        local window = windowsToSplit[i]
        -- print("Adding window as new node: " .. window:title())
        tree_operations.addNode(obj, obj.Node, helpers, window, tree)
    end
    
    -- Apply layout to all trees
    obj:applyLayout(node)
    
    -- print("Successfully exploded node into " .. #windowsToSplit .. " separate nodes")
    return true
end

return tree_operations

