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

function Node:new(id, leaf, parent, windows, position, size, split_type, split_ratio, child1, child2)
    local node = {
        id = id,
        leaf = leaf, -- boolean: true for leaf, false for internal
        parent = parent,
        position = position,
        size = size,
        
        -- leaf properties:
        windows = windows, -- ordered table: first element is furthest back

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

    obj.trees = {} -- Array: [space_id] = { root = node, selected = node }
    obj._eventListenersActive = true -- Flag to control event listener activity
    obj.stopWM = false -- Dedicated flag to completely stop window manager functionality
    obj._lastWindowPositions = {} -- Track window positions to detect user vs system moves
    obj.lastMoveTime = 0 -- Track last window move time using absoluteTime for throttling
    obj.lastRefreshTime = 0 -- Track last refresh time using absoluteTime for throttling
    obj.current_space = nil

-- Initialize the spoon
function obj:init()
    obj.save_path = hs.configdir .. "/window-manager.layout.json"
    obj.logTag = "WindowManager"
    return self
end

function Node:getAllLeafWindows()
    local windows = {}
    if self.leaf then
        -- This is a leaf, add all its windows
        for _, w in ipairs(self.windows) do
            table.insert(windows, w)
        end
    else
        -- This is an internal node, recurse into children
        if self.child1 then
            local child1_windows = self.child1:getAllLeafWindows()
            for _, w in ipairs(child1_windows) do table.insert(windows, w) end
        end
        if self.child2 then
            local child2_windows = self.child2:getAllLeafWindows()
            for _, w in ipairs(child2_windows) do table.insert(windows, w) end
        end
    end
    return windows
end

-- Start the spoon
function obj:start()
    -- print("WindowManager: Starting")
    
    -- Load the previous layout FIRST
    obj:loadLayout()

    hs.window.animationDuration = 0.0
    self:setupWindowWatcher()
    self:refreshTree()
    
    -- NEW: Watch for space changes
    self.spaceWatcher = hs.spaces.watcher.new(function()
        if not obj._eventListenersActive then return end
        obj:onSpaceChanged()
    end)
    self.spaceWatcher:start()
    
    -- Initialize and start the sleep watcher
    obj.caffeinateWatcher = hs.caffeinate.watcher.new(function(event)
        if event == hs.caffeinate.watcher.screensDidSleep then
            -- print("WindowManager: Screens going to sleep - saving layout")
            obj:saveLayout()
        elseif event == hs.caffeinate.watcher.screensDidWake then
            -- print("WindowManager: Screens waking up - loading layout")
            -- Wait longer for spaces and windows to settle
            hs.timer.doAfter(3, function()
                obj:loadLayout()
            end)
        end
    end)
    obj.caffeinateWatcher:start()
    
    return self
end

-- Stop the spoon
function obj:stop()
    -- print("WindowManager: Stopping")
    
    if self.windowWatcher then
        self.windowWatcher:delete()
        self.windowWatcher = nil
    end
    
    -- NEW: Stop space watcher
    if self.spaceWatcher then
        self.spaceWatcher:stop()
        self.spaceWatcher = nil
    end
    
    -- Stop and remove the sleep watcher
    if obj.caffeinateWatcher then
        obj.caffeinateWatcher:stop()
        obj.caffeinateWatcher = nil
    end
    
    -- Save the layout one last time on stop/reload
    obj:saveLayout()
    
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
        "Raycast", "System Settings", "Spotlight", "Dock", "Control Center", "Notification Center"
    }, appName) then
        return false
    end
    
    return true
end


-- Set up window watcher
function obj:setupWindowWatcher()
    self.windowWatcher = hs.window.filter.new()

    self.windowWatcher:subscribe(hs.window.filter.windowCreated, function(window)
        if not obj._eventListenersActive or obj.stopWM then return end
        
        -- Add error handling for window operations
        local success, err = pcall(function()
            -- FIX: Add filtering
            if obj:isWindowManageable(window) then
                -- This is correct: new windows are always created on the focused space.
                local current_space = hs.spaces.focusedSpace()
                local tree = obj:getTreeForSpace(current_space)
                if not tree then return end
                obj:addNode(window, tree)
            end
        end)
        
        if not success then
            -- print("Error in windowCreated handler: " .. tostring(err))
        end
    end)

    self.windowWatcher:subscribe(hs.window.filter.windowFocused, function(window)
        if not obj._eventListenersActive or obj.stopWM then return end
        
        -- Add error handling for window operations
        local success, err = pcall(function()
            -- FIX: Add nil checks for robustness
            local screen = window:screen()
            if not screen then return end
            local screen_id = screen:id()
            local space_id = hs.spaces.focusedSpace()
            
            local tree = obj:getTreeForSpace(space_id)
            if not tree then return end
            
            -- Track focused window for selection purposes
            
            -- Only update selected node if the window is manageable
            if obj:isWindowManageable(window) and tree.root then
                local foundNode = tree.root:findNode(window)
                if foundNode then
                    tree.selected = foundNode
                    -- Only reorder window in stack if not in a manual operation
                    if not obj._refreshing then
                        -- Reorder window in stack: remove from current position and append to end (front)
                        for i, w in ipairs(foundNode.windows) do
                            if w:id() == window:id() then
                                table.remove(foundNode.windows, i)
                                break
                            end
                        end
                        table.insert(foundNode.windows, window)
                    end
                end
            end

            obj:refreshTree()
        end)
        
        if not success then
            -- print("Error in windowFocused handler: " .. tostring(err))
        end
    end)

    self.windowWatcher:subscribe(hs.window.filter.windowDestroyed, function(window)
        if not obj._eventListenersActive or obj.stopWM then return end
        -- FIX: Call the new parameterized function.
        -- It will find the window in *any* tree and remove it.
        obj:closeWindow(window, nil)
    end)

    -- FIX: All move events now call the same robust handler
    self.windowWatcher:subscribe(hs.window.filter.windowMoved, function(window)
        -- print("Spaces: " .. hs.inspect(hs.spaces.allSpaces())) -- all spaces
        if not obj._eventListenersActive or obj.stopWM then return end
        if obj:isWindowManageable(window) then
            obj:windowMovedHandler(window)
        end
    end)

    self.windowWatcher:subscribe(hs.window.filter.windowInCurrentSpace, function(window)
        if not obj._eventListenersActive or obj.stopWM then return end
        if obj:isWindowManageable(window) then
            obj:refreshTree()
        end
    end)

    self.windowWatcher:subscribe(hs.window.filter.windowNotInCurrentSpace, function(window)
        if not obj._eventListenersActive or obj.stopWM then return end
        if obj:isWindowManageable(window) then
            obj:refreshTree()
        end
    end)

    -- Handle window maximization - clear focus tracking when window becomes maximized
    self.windowWatcher:subscribe(hs.window.filter.windowFullscreened, function(window)
        if not obj._eventListenersActive or obj.stopWM then return end
        -- print("Window maximized: " .. window:title())
        -- Maximized windows create their own space, no special handling needed
    end)

    self.windowWatcher:subscribe(hs.window.filter.windowMinimized, function(window)
        if not obj._eventListenersActive or obj.stopWM then return end
        if obj:isWindowManageable(window) then
            -- print("Window minimized: " .. window:title())
            obj:refreshTree()
        end
    end)

    self.windowWatcher:subscribe(hs.window.filter.windowHidden, function(window)
        if not obj._eventListenersActive or obj.stopWM then return end
        if obj:isWindowManageable(window) then
            -- print("Window hidden: " .. window:title())
            obj:refreshTree()
        end
    end)

    self.windowWatcher:subscribe(hs.window.filter.windowUnminimized, function(window)
        if not obj._eventListenersActive or obj.stopWM then return end
        if obj:isWindowManageable(window) then
            -- print("Window unminimized: " .. window:title())
            obj:refreshTree()
        end
    end)

    self.windowWatcher:subscribe(hs.window.filter.windowUnhidden, function(window)
        if not obj._eventListenersActive or obj.stopWM then return end
        if obj:isWindowManageable(window) then
            -- print("Window unhidden: " .. window:title())
            obj:refreshTree()
        end
    end)
end

function obj:getTreeForSpace(space_id)
    if not space_id then
        -- print("Error: getTreeForSpace called with nil space_id")
        space_id = hs.spaces.focusedSpace()
    end

    if not obj.trees[space_id] then
        -- This is the first time we're seeing this space. Create a new tree.
        -- print("Creating new tree for space: " .. space_id)
        
        -- Get the main screen for the frame
        local screen = obj:getScreenForSpace(space_id)
        if not screen then return nil end -- No screens
        
        local frame = screen:frame()
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
function obj:getScreenForSpace(space_id)
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

function obj:getNodeAtPosition(x, y, ignoreWindow)
    -- print("getNodeAtPosition called with: " .. x .. ", " .. y)
    
    -- Get all windows and find the first one that contains the point
    local allWindows = hs.window.orderedWindows()
    for _, window in ipairs(allWindows) do
        if obj:isWindowManageable(window) and (not ignoreWindow or window:id() ~= ignoreWindow:id()) then
            local frame = window:frame()
            if x >= frame.x and x < frame.x + frame.w and
               y >= frame.y and y < frame.y + frame.h then
                -- print("Found window at position: " .. window:title())
                
                -- Find the node containing this window
                local space_id, tree = obj:getTreeForWindow(window)
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
function obj:findNeighbor(window, direction)
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
    local neighborNode = obj:getNodeAtPosition(searchX, searchY)
    if neighborNode then
        -- print("Found neighbor: " .. (neighborNode.windows and neighborNode.windows[1] and neighborNode.windows[1]:title() or "Internal node"))
        return neighborNode
    end
    
    -- print("No neighbor found in direction '" .. direction .. "'")
    return nil
end

-- Focus a neighbor window in a given direction
-- @param direction String: "left", "right", "up", "down"
-- @return true if neighbor was found and focused, false otherwise
function obj:focusNeighbor(direction)
    -- print("Focusing neighbor in direction '" .. direction .. "'")

    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        -- print("No focused window found")
        return false
    end
    
    local neighborNode = obj:findNeighbor(currentWindow, direction)
    if neighborNode and neighborNode.windows and neighborNode.windows[1] then
        local neighborWindow = neighborNode.windows[#neighborNode.windows]
        neighborWindow:focus()
        
        -- Center the mouse position in the focused window
        local windowFrame = neighborWindow:frame()
        local centerX = windowFrame.x + windowFrame.w / 2
        local centerY = windowFrame.y + windowFrame.h / 2
        hs.mouse.absolutePosition({x = centerX, y = centerY})
        
        -- print("Focused neighbor: " .. neighborWindow:title())
        return true
    else
        -- print("No neighbor found in direction '" .. direction .. "'")
        return false
    end
end

-- Rotate the windows in the current node's stack
-- @return true if rotation was successful, false otherwise
function obj:nextWindow()
    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        -- print("No focused window found")
        return false
    end
    
    local space_id, tree = obj:getTreeForWindow(currentWindow)
    if not tree or not tree.root then
        -- print("No tree found for focused window: " .. currentWindow:title())
        return false
    end
    
    local node = tree.root:findNode(currentWindow)
    if not node or not node.leaf then
        -- print("Focused window not found in tree or not in a leaf node")
        return false
    end
    
    if #node.windows <= 1 then
        -- print("Node has only one window, nothing to rotate")
        return false
    end
    
    -- Temporarily disable refresh to prevent interference
    local wasRefreshing = obj._refreshing
    obj._refreshing = true
    
    -- Rotate the windows table: move the last window to the front
    local lastWindow = table.remove(node.windows)
    table.insert(node.windows, 1, lastWindow)
    
    -- Focus the new front window
    node.windows[1]:focus()
    
    -- Update tree selection
    tree.selected = node
    
    -- Apply layout to update the display
    obj:applyLayout(tree.root)
    
    -- Restore refresh state
    obj._refreshing = wasRefreshing
    
    -- print("Rotated windows in node, now focused: " .. node.windows[1]:title())
    return true
end

-- Resize the current window by adjusting split ratios
-- @param direction String: "left", "right", "up", "down"
-- @return true if resize was successful, false otherwise
function obj:resizeWindow(direction)
    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        -- print("No focused window found")
        return false
    end
    
    local space_id, tree = obj:getTreeForWindow(currentWindow)
    if not tree or not tree.root then
        -- print("No tree found for focused window: " .. currentWindow:title())
        return false
    end
    
    local node = tree.root:findNode(currentWindow)
    if not node or not node.leaf then
        -- print("Focused window not found in tree or not in a leaf node")
        return false
    end
    
    local adjustment = 0.001
    local adjustment_factor = 1.3
    local found = false
    local targetParent = nil
    
    -- Find the appropriate split parent
    if direction == "left" or direction == "right" then
        -- Find first horizontal split
        local parentNode = node.parent
        while parentNode do
            if parentNode.split_type == true then
                targetParent = parentNode
                found = true
                break
            end
            parentNode = parentNode.parent
        end
    elseif direction == "up" or direction == "down" then
        -- Find first vertical split
        local parentNode = node.parent
        while parentNode do
            if parentNode.split_type == false then
                targetParent = parentNode
                found = true
                break
            end
            parentNode = parentNode.parent
        end
    end
    
    if not found then
        -- print("No appropriate split found for resizing in direction: " .. direction)
        return false
    end
    
    -- Start continuous resizing timer
    if obj.resizeTimers and obj.resizeTimers[direction] then
        obj.resizeTimers[direction]:stop()
    end
    
    if not obj.resizeTimers then
        obj.resizeTimers = {}
    end
    
    -- Set up a flag to track if we should continue resizing
    obj.resizeActive = obj.resizeActive or {}
    obj.resizeActive[direction] = true
    
    obj.resizeTimers[direction] = hs.timer.doEvery(0.01, function()
        -- Check if resize is still active
        if not obj.resizeActive or not obj.resizeActive[direction] then
            -- Resize stopped, clean up timer
            if obj.resizeTimers[direction] then
                obj.resizeTimers[direction]:stop()
                obj.resizeTimers[direction] = nil
            end
            return
        end
        
        -- Adjust split ratio based on direction and which side we're on
        if direction == "left" then
            -- Moving left on left side: decrease ratio (make left side smaller)
            targetParent.split_ratio = math.max(math.min(targetParent.split_ratio - adjustment, 1.0), 0.0)
        elseif direction == "right" then
            -- Moving right on left side: increase ratio (make left side bigger)
            targetParent.split_ratio = math.max(math.min(targetParent.split_ratio + adjustment, 1.0), 0.0)
        elseif direction == "up" then
            -- Moving up on top side: decrease ratio (make top side smaller)
            targetParent.split_ratio = math.max(math.min(targetParent.split_ratio - adjustment, 1.0), 0.0)
        elseif direction == "down" then
            -- Moving down on top side: increase ratio (make top side bigger)
            targetParent.split_ratio = math.max(math.min(targetParent.split_ratio + adjustment, 1.0), 0.0)
        end

        adjustment = adjustment * adjustment_factor
        
        -- Apply layout
        obj:applyLayout(tree.root)
    end)
    
    -- print("Started continuous resizing in direction: " .. direction)
    return true
end

-- Stop resizing in a specific direction
function obj:stopResize(direction)
    if obj.resizeActive then
        obj.resizeActive[direction] = false
    end
    if obj.resizeTimers and obj.resizeTimers[direction] then
        obj.resizeTimers[direction]:stop()
        obj.resizeTimers[direction] = nil
    end
    -- print("Stopped resizing in direction: " .. direction)
end

-- Swap the focused node with a neighbor node
-- @param direction String: "left", "right", "up", "down"
-- @return true if swap was successful, false otherwise
function obj:swapNeighbor(direction)
    -- print("Swapping with neighbor in direction '" .. direction .. "'")
    
    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        -- print("No focused window found")
        return false
    end
    
    -- Find the node containing the focused window
    local space_id, tree = obj:getTreeForWindow(currentWindow)
    if not tree or not tree.root then
        -- print("No tree found for focused window: " .. currentWindow:title())
        return false
    end
    
    local focusedNode = tree.root:findNode(currentWindow)
    if not focusedNode or not focusedNode.leaf then
        -- print("Focused window not found in tree or not a leaf node")
        return false
    end
    
    -- Find the neighbor node
    local neighborNode = obj:findNeighbor(currentWindow, direction)
    if not neighborNode or not neighborNode.leaf then
        -- print("No neighbor found in direction '" .. direction .. "' or neighbor is not a leaf")
        return false
    end
    
    -- print("Swapping focused node with neighbor node")
    
    -- Find the neighbor's tree
    local neighborSpace_id, neighborTree = obj:getTreeForWindow(neighborNode.windows[1])
    if not neighborTree then
        -- print("Could not find tree for neighbor node")
        return false
    end
    
    -- Swap contents
    focusedNode.windows, neighborNode.windows = neighborNode.windows, focusedNode.windows

    -- Update tree selections
    neighborTree.selected = neighborNode

    -- Apply layout to both trees
    obj:applyLayout(tree.root)
    if neighborTree ~= tree then
        obj:applyLayout(neighborTree.root)
    end
    
    -- print("Successfully swapped nodes")
    return true
end

-- Reflect the parent of the currently focused window
-- @return true if reflection was successful, false otherwise
function obj:reflect()
    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        -- print("No focused window found")
        return false
    end
    
    local space_id, tree = obj:getTreeForWindow(currentWindow)
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
    obj:reflectNode(parent)
    
    -- Apply layout to update visual representation
    obj:applyLayout(tree.root)
    
    return true
end

-- Reflect a node by switching between horizontal and vertical split types (recursive)
-- @param node The node to reflect
function obj:reflectNode(node)
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
        obj:reflectNode(node.child1)
    end
    if node.child2 then
        obj:reflectNode(node.child2)
    end
end

function obj:rotateLeft()
    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        -- print("No focused window found")
        return false
    end
    
    local space_id, tree = obj:getTreeForWindow(currentWindow)
    if not tree or not tree.root or tree.root.leaf then
        -- print("No tree found for focused window: " .. currentWindow:title())
        return false
    end

    -- print("Tree before rotate left:")
    obj:printTreeWindows(tree.root, 0)
    
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
    obj:printTreeWindows(tree.root, 0)
    
    obj:applyLayout(tree.root)
    return true
end

function obj:rotateRight()
    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        -- print("No focused window found")
        return false
    end
    
    local space_id, tree = obj:getTreeForWindow(currentWindow)
    if not tree or not tree.root or tree.root.leaf then
        -- print("No tree found for focused window: " .. currentWindow:title())
        return false
    end

    -- print("Tree before rotate right:")
    obj:printTreeWindows(tree.root, 0)
    
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
    obj:printTreeWindows(tree.root, 0)
    
    obj:applyLayout(tree.root)
    return true
end

-- Shutdown/restart window manager system
-- First press: Delete all trees, set stopWM to true
-- Second press: Set stopWM to false and refresh tree
function obj:toggleShutdownRestart()
    if obj.stopWM then
        -- Currently stopped, restart the system
        obj.stopWM = false
        obj._eventListenersActive = true
        -- print("Window manager RESTARTED")
        obj:refreshTree()
        return true
    else
        -- Currently running, shutdown the system
        obj.stopWM = true
        obj._eventListenersActive = false
        -- Delete all trees
        obj.trees = {}
        -- print("Window manager SHUTDOWN - all trees deleted")
        return false
    end
end

-- Gather all windows from the parent's children and convert parent to leaf
-- @return true if successful, false otherwise
function obj:gatherNodes()
    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        -- print("No focused window found")
        return false
    end
    
    local space_id, tree = obj:getTreeForWindow(currentWindow)
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
    
    -- Apply layout to update visual representation
    obj:applyLayout(tree.root)
    
    -- print("Successfully gathered " .. #allWindows .. " windows into parent node")
    return true
end

-- Explode current node's windows into separate nodes
-- @return true if successful, false otherwise
function obj:explodeNode()
    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        -- print("No focused window found")
        return false
    end
    
    local space_id, tree = obj:getTreeForWindow(currentWindow)
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
    
    -- Reverse the table so most recently focused windows are added first
    for i = 1, math.floor(#windowsToSplit / 2) do
        local j = #windowsToSplit - i + 1
        windowsToSplit[i], windowsToSplit[j] = windowsToSplit[j], windowsToSplit[i]
    end
    
    -- Keep the first window (now the most recently focused) in the current node
    local firstWindow = windowsToSplit[1]
    node.windows = {firstWindow}
    
    -- Add each remaining window as a new node (in reverse order)
    for i = 2, #windowsToSplit do
        local window = windowsToSplit[i]
        -- print("Adding window as new node: " .. window:title())
        obj:addNode(window, tree)
    end
    
    -- Apply layout to update visual representation
    obj:applyLayout(tree.root)
    
    -- print("Successfully exploded node into " .. #windowsToSplit .. " separate nodes")
    return true
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
    -- print("Window moved: " .. window:title())
    
    -- Throttle window move events to prevent excessive calls
    local currentTime = hs.timer.absoluteTime()
    if obj.lastMoveTime > 0 and (currentTime - obj.lastMoveTime) < 1000000000 then -- 1 second in nanoseconds
        -- print("Throttling window move event - too soon since last move")
        return
    end
    
    -- Update lastMoveTime
    obj.lastMoveTime = currentTime
    
    -- Check if this is a system-initiated move by comparing positions
    local windowId = window:id()
    local currentFrame = window:frame()
    local lastFrame = obj._lastWindowPositions[windowId]
    
    -- Only block moves if the position hasn't changed at all (true system move)
    -- Allow all other moves to proceed
    if lastFrame and 
       math.abs(currentFrame.x - lastFrame.x) < 1 and 
       math.abs(currentFrame.y - lastFrame.y) < 1 and
       math.abs(currentFrame.w - lastFrame.w) < 1 and 
       math.abs(currentFrame.h - lastFrame.h) < 1 then
        -- print("System move detected - ignoring")
        return
    end
    
    -- Update position tracking
    obj._lastWindowPositions[windowId] = {
        x = currentFrame.x,
        y = currentFrame.y,
        w = currentFrame.w,
        h = currentFrame.h
    }
    

    -- Check if left mouse button is down - if so, this is a user drag, allow it
    local mouseButtons = hs.mouse.getButtons()
    if mouseButtons.left then
        -- print("User drag detected - allowing window to move freely")
        -- Just refresh the tree to clean up any orphaned references
        obj:refreshTree()
        return
    end

    local targetScreen = hs.mouse.getCurrentScreen()
    local targetSpace = hs.spaces.activeSpaceOnScreen(targetScreen)
    local targetTree = obj:getTreeForSpace(targetSpace)

    -- print("Target tree before move:")
    obj:printTreeWindows(targetTree.root, 0)

    local windowSpaceId, windowTree = obj:getTreeForWindow(window)
    local windowScreen = obj:getScreenForSpace(windowSpaceId)
    if windowScreen then
        -- print("Window screen: " .. windowScreen:name())
    else
        -- print("Window screen not found")
    end

    if windowTree then
        -- print("Window tree before move:")
        obj:printTreeWindows(windowTree.root, 0)
    else
        -- print("Window tree not found")
    end

    if lastFrame and (math.abs(currentFrame.w - lastFrame.w) > 1 or math.abs(currentFrame.h - lastFrame.h) > 1) and targetScreen == windowScreen then
        -- print("Window resized: " .. window:title())
        obj:handleWindowResize(window, currentFrame, lastFrame, targetTree)
        return
    end

    -- Use absolute mouse position (no coordinate transformation needed)
    local mousePosition = hs.mouse.absolutePosition()

    -- print("Mouse position: " .. mousePosition.x .. ", " .. mousePosition.y)
    -- print("Number of trees: " .. (function() local count = 0; for _ in pairs(obj.trees) do count = count + 1 end; return count end)())
    
    -- Debug: Print all tree bounds
    for space_id, tree in pairs(obj.trees) do
        if tree and tree.root then
            local root = tree.root
            -- print("Tree " .. space_id .. " bounds: " .. root.position.x .. ", " .. root.position.y .. " size: " .. root.size.w .. "x" .. root.size.h)
        end
    end

    local node = obj:getNodeAtPosition(mousePosition.x, mousePosition.y, window)
    
    if node then
        -- Store node info in local variables to prevent corruption
        local nodeX = node.position.x
        local nodeY = node.position.y
        local nodeW = node.size.w
        local nodeH = node.size.h
        
        obj:closeWindow(window, windowTree)
        
        -- Set the found node as selected in the tree
        targetTree.selected = node

        -- Calculate distances from mouse to each edge
        local mouseX = mousePosition.x
        local mouseY = mousePosition.y
        
        local distToLeft = (mouseX - nodeX) / nodeW
        local distToRight = ((nodeX + nodeW) - mouseX) / nodeW
        local distToTop = (mouseY - nodeY) / nodeH
        local distToBottom = ((nodeY + nodeH) - mouseY) / nodeH
        
        -- Find the minimum distance to determine closest edge
        local minDistance = math.min(distToLeft, distToRight, distToTop, distToBottom)
        
        -- Check if mouse is in center area (not too close to any edge)
        local centerThreshold = 0.33 -- 33% of smaller dimension
        
        -- Debug logging
        -- print("Node dimensions: " .. nodeW .. "x" .. nodeH)
        -- print("Mouse distances - Left: " .. distToLeft .. ", Right: " .. distToRight .. ", Top: " .. distToTop .. ", Bottom: " .. distToBottom)
        -- print("Min distance: " .. minDistance .. ", Center threshold: " .. centerThreshold)
        
        if minDistance > centerThreshold then
            -- print("Adding to stack (center area)")
            obj:addWindowToStack(window, targetTree)
        elseif minDistance == distToLeft then
            -- print("Splitting left (closest to left edge)")
            obj:addNode(window, targetTree, 1, true)
        elseif minDistance == distToRight then
            -- print("Splitting right (closest to right edge)")
            obj:addNode(window, targetTree, 2, true)
        elseif minDistance == distToTop then
            -- print("Splitting up (closest to top edge)")
            obj:addNode(window, targetTree, 1, false)
        elseif minDistance == distToBottom then
            -- print("Splitting down (closest to bottom edge)")
            obj:addNode(window, targetTree, 2, false)
        else
            -- print("Adding to stack (fallback)")
            obj:addWindowToStack(window, targetTree)
        end
    else
        -- print("No node at mouse position")
    end

    -- print("Target tree after move:")
    obj:printTreeWindows(targetTree.root, 0)

    -- print("Window tree after move:")
    if windowTree and windowTree.root then
        obj:printTreeWindows(windowTree.root, 0)
    else
        -- print("Window tree not found")
    end

    obj:refreshTree()
end

function obj:handleWindowResize(window, currentFrame, lastFrame, tree)
    -- Look for first internal edge in each resized direction
    -- resize left (moved x position, delta width): currentFrame.x != lastFrame.x and currentFrame.w != lastFrame.w
    -- resize down (did not move y position, delta height): currentFrame.y == lastFrame.y and currentFrame.h != lastFrame.h
    -- resize up (moved y position, delta height): currentFrame.y != lastFrame.y and currentFrame.h != lastFrame.h
    -- resize right (did not move x position, delta width): currentFrame.x == lastFrame.x and currentFrame.w != lastFrame.w
    local deltaX = currentFrame.x - lastFrame.x
    local deltaY = currentFrame.y - lastFrame.y
    local deltaWidth = currentFrame.w - lastFrame.w
    local deltaHeight = currentFrame.h - lastFrame.h

    local node = tree.root:findNode(window)
    if not node then
        -- print("Node not found")
        return
    end

    local parent = node.parent
    if not parent then
        -- print("Parent not found, node is root")
        return
    end

    if math.abs(deltaX) > 1 and math.abs(deltaWidth) > 1 then -- resize left (moved x position, delta width)
        -- find first internal node splitting horizontally where the previous node was child2
        local childNode = node
        local parentNode = node.parent
        local found = false
        while parentNode do
            if parentNode.split_type == true and parentNode.child2 == childNode then
                -- NEW MATH: Use position to determine splitter edge location
                local new_child1_width = currentFrame.x - parentNode.position.x
                parentNode.split_ratio = math.max(math.min(new_child1_width / parentNode.size.w, 1.0), 0.0)
                -- print("Resizing left: " .. parentNode.split_ratio)
                found = true
                break
            end
            childNode = parentNode
            parentNode = parentNode.parent
        end
        if not found then
            -- print("Reached root node, no internal node found, not resizing left")
        end
    end

    if math.abs(deltaY) < 1 and math.abs(deltaHeight) > 1 then -- resize down (did not move y position, delta height)
        -- find first internal node splitting vertically where the previous node was child1
        local childNode = node
        local parentNode = node.parent
        local found = false
        while parentNode do
            if parentNode.split_type == false and parentNode.child1 == childNode then
                parentNode.split_ratio = math.max(math.min(currentFrame.h / parentNode.size.h, 1.0), 0.0)
                -- print("Resizing down: " .. parentNode.split_ratio)
                found = true
                break
            end
            childNode = parentNode
            parentNode = parentNode.parent
        end
        if not found then
            -- print("Reached root node, no internal node found, not resizing down")
        end
    end

    if math.abs(deltaY) > 1 and math.abs(deltaHeight) > 1 then -- resize up (moved y position, delta height)
        -- find first internal node splitting vertically where the previous node was child2
        local childNode = node
        local parentNode = node.parent
        local found = false
        while parentNode do
            if parentNode.split_type == false and parentNode.child2 == childNode then
                -- NEW MATH: Use position to determine splitter edge location
                local new_child1_height = currentFrame.y - parentNode.position.y
                parentNode.split_ratio = math.max(math.min(new_child1_height / parentNode.size.h, 1.0), 0.0)
                -- print("Resizing up: " .. parentNode.split_ratio)
                found = true
                break
            end
            childNode = parentNode
            parentNode = parentNode.parent
        end
        if not found then
            -- print("Reached root node, no internal node found, not resizing up")
        end
    end

    if math.abs(deltaX) < 1 and math.abs(deltaWidth) > 1 then -- resize right (did not move x position, delta width)
        -- find first internal node splitting horizontally where the previous node was child1
        local childNode = node
        local parentNode = node.parent
        local found = false
        while parentNode do
            if parentNode.split_type == true and parentNode.child1 == childNode then
                parentNode.split_ratio = math.max(math.min(currentFrame.w / parentNode.size.w, 1.0), 0.0)
                -- print("Resizing right: " .. parentNode.split_ratio)
                found = true
                break
            end
            childNode = parentNode
            parentNode = parentNode.parent
        end
        if not found then
            -- print("Reached root node, no internal node found, not resizing right")
        end
    end

    self:applyLayout(tree.root)
end


---
--- NEW: Handle space switching - simplified to just track focus, let macOS handle actual focusing
---
function obj:onSpaceChanged()
    -- print("Space changed.")
    
    -- Just refresh the tree to clean up any stale references
    obj:refreshTree()
    
    -- No manual focusing - let macOS handle it naturally
    -- print("Space switched - letting macOS handle focus naturally")
end

function obj:applyLayout(node)

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
            pcall(function() 
                win:setFrame(frame)
                -- Update position tracking after system move
                local windowId = win:id()
                if windowId then
                    obj._lastWindowPositions[windowId] = {
                        x = frame.x,
                        y = frame.y,
                        w = frame.w,
                        h = frame.h
                    }
                end
            end)
        end
    end
end

function obj:addNode(window, tree, child, split_type)
    if not window or not window:id() then return end
    
    -- Use current space tree if none provided
    if not tree then
        local space_id = hs.spaces.focusedSpace()
        tree = self:getTreeForSpace(space_id)
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
        table.insert(tree.root.windows, window)
        tree.selected = tree.root
        -- Only apply layout if not refreshing (to prevent recursive calls)
        if not obj._refreshing then
            self:applyLayout(tree.root)
        end
        return
    end
    
    -- Case 2: Empty selected leaf
    if tree.selected and tree.selected.leaf and #tree.selected.windows == 0 then
        table.insert(tree.selected.windows, window)
        -- Only apply layout if not refreshing (to prevent recursive calls)
        if not obj._refreshing then
            self:applyLayout(tree.root)
        end
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
    
    -- Only apply layout if not refreshing (to prevent recursive calls)
    if not obj._refreshing then
        self:applyLayout(tree.root)
    end
end

function obj:addWindowToStack(window, tree)
    if not window or not window:id() then return end
    if not tree or not tree.selected then return end
    
    -- Add window to the selected node's windows table (at the end for frontmost)
    table.insert(tree.selected.windows, window)
    
    -- Only apply layout if not refreshing (to prevent recursive calls)
    if not obj._refreshing then
        self:applyLayout(tree.root)
    end
    
    -- print("Added window to stack: " .. window:title() .. " (index " .. #tree.selected.windows .. ")")
end

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
        -- Only apply layout if not refreshing (to prevent recursive calls)
        if not obj._refreshing then
            self:applyLayout(tree.root)
        end
    end
end

function obj:collapseNode(tree, node) -- NEW: Takes tree and node
    if not node.parent then
        -- This is the root node. We don't delete it,
        -- we just reset it to be an empty leaf.
        -- print("Collapsing root node.")
        local frame = node.position
        local size = node.size
        -- Reset root to a clean leaf state
        tree.root = Node:new(
            hs.host.uuid(), true, nil, {},
            frame, size, nil, nil, nil, nil
        )
        tree.selected = tree.root
        return
    end
    
    local parent = node.parent
    local sibling = (parent.child1 == node) and parent.child2 or parent.child1
    
    if not sibling then
        -- This should not happen, but if it does, collapse the parent
        -- print("Error: Node to collapse has no sibling. Collapsing parent.")
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
    
    -- Only apply layout if not refreshing (to prevent recursive calls)
    if not obj._refreshing then
        self:applyLayout(tree.root)
    end
end

function obj:refreshTree()
    -- Throttle refresh calls to prevent excessive calls
    local currentTime = hs.timer.absoluteTime()
    if obj.lastRefreshTime > 0 and (currentTime - obj.lastRefreshTime) < 1000000000 then -- 1 second in nanoseconds
        -- print("Throttling refresh call - too soon since last refresh")
        return
    end
    
    -- Update lastRefreshTime
    obj.lastRefreshTime = currentTime
    
    -- Prevent recursive calls
    if obj._refreshing then
        -- print("Already refreshing, skipping...")
        return
    end
    
    obj._refreshing = true
    -- print("Refreshing tree")

    local current_space = hs.spaces.focusedSpace()
    obj.current_space = current_space
    -- print("Current space: " .. current_space)

    local tree = obj:getTreeForSpace(current_space)
    local focused_screen_id = hs.screen.mainScreen():id()
    
    -- Save the list of windows on the screen as a local table
    local windows_on_screen = {}
    local all_windows = hs.window.orderedWindows()
    for _, window in ipairs(all_windows) do
        if obj:isWindowManageable(window) and window:screen():id() == focused_screen_id then
            table.insert(windows_on_screen, window)
        end
    end
    
    -- Save the list of windows in the tree before making any changes
    local windows_in_tree = {}
    if tree.root then
        windows_in_tree = tree.root:getAllLeafWindows()
    end
    
    -- Create lookup tables for efficient comparison
    local screen_windows_by_id = {}
    for _, window in ipairs(windows_on_screen) do
        screen_windows_by_id[window:id()] = window
    end
    
    local tree_windows_by_id = {}
    for _, window in ipairs(windows_in_tree) do
        tree_windows_by_id[window:id()] = window
    end
    
    -- Find windows to add (on screen but not in tree)
    local windows_to_add = {}
    for _, window in ipairs(windows_on_screen) do
        if not tree_windows_by_id[window:id()] then
            table.insert(windows_to_add, window)
        end
    end
    
    -- Find windows to remove (in tree but not on screen or not manageable)
    local windows_to_remove = {}
    for _, window in ipairs(windows_in_tree) do
        local should_remove = false
        
        -- Check if window is no longer manageable
        if not obj:isWindowManageable(window) then
            should_remove = true
        -- Check if window is not on the current screen
        elseif window:screen():id() ~= focused_screen_id then
            should_remove = true
        -- Check if window is not in the current window list
        elseif not screen_windows_by_id[window:id()] then
            should_remove = true
        end
        
        if should_remove then
            table.insert(windows_to_remove, window)
        end
    end
    
    -- print("Windows to add: " .. #windows_to_add)
    -- print("Windows to remove: " .. #windows_to_remove)
    
    -- Remove windows first (to avoid conflicts)
    for _, window in ipairs(windows_to_remove) do
        -- print("Removing stale window: " .. (window:title() or "Invalid"))
        obj:closeWindow(window, tree)
    end
    
    -- Add new windows
    for _, window in ipairs(windows_to_add) do
        -- print("Adding new window: " .. window:title())
        obj:addNode(window, tree)
    end
    
    -- Clean up duplicates: find windows that appear multiple times in the tree
    if tree.root then
        local all_tree_windows = tree.root:getAllLeafWindows()
        local window_counts = {}
        local duplicate_windows = {}
        
        -- Count occurrences of each window
        for _, window in ipairs(all_tree_windows) do
            local window_id = window:id()
            if window_id then
                window_counts[window_id] = (window_counts[window_id] or 0) + 1
                if window_counts[window_id] > 1 then
                    table.insert(duplicate_windows, window)
                end
            end
        end
        
        -- Remove duplicate windows (keep only the first occurrence)
        if #duplicate_windows > 0 then
            -- print("Found " .. #duplicate_windows .. " duplicate windows, cleaning up...")
            for _, window in ipairs(duplicate_windows) do
                -- print("Removing duplicate: " .. (window:title() or "Invalid"))
                obj:closeWindow(window, tree)
            end
        end
    end
    
    -- Apply layout only once at the end for all trees
    for space_id, tree in pairs(obj.trees) do
        if tree.root then
            obj:applyLayout(tree.root)
        end
    end
    
    -- Clear the refreshing flag
    obj._refreshing = false
end

--- Saves the current layout tree to a JSON file
function obj:saveLayout()
    local layout_to_save = {}

    -- Helper function to create a "clean" serializable node
    local function cleanNode(node)
        if not node then return nil end
        
        local clean_node = {
            id = node.id,
            leaf = node.leaf,
            position = node.position,
            size = node.size,
            split_type = node.split_type,
            split_ratio = node.split_ratio,
            windows = {},
            child1 = nil,
            child2 = nil
        }
        
        -- IMPORTANT: Save window titles and bundle IDs for reconstruction
        if node.windows then
            for _, win in ipairs(node.windows) do
                if win and win:id() then
                    local app = win:application()
                    local bundleID = app and app:bundleID() or "unknown"
                    local window_info = {
                        id = win:id(),
                        title = win:title(),
                        bundleID = bundleID
                    }
                    table.insert(clean_node.windows, window_info)
                    -- print("Saving window: " .. win:title() .. " (ID: " .. win:id() .. ", Bundle: " .. bundleID .. ")")
                end
            end
        end
        
        -- Recurse for children
        if node.child1 then
            clean_node.child1 = cleanNode(node.child1)
        end
        if node.child2 then
            clean_node.child2 = cleanNode(node.child2)
        end
        
        return clean_node
    end

    -- Clean the tree for each space
    for space_id, tree in pairs(obj.trees) do
        -- Keys in JSON must be strings, so we convert the space_id
        layout_to_save[tostring(space_id)] = {
            root = cleanNode(tree.root),
            selected = tree.selected and tree.selected.id or nil
        }
    end

    -- Encode and write to file
    local json_data = hs.json.encode(layout_to_save)
    if not json_data then
        -- print("WindowManager: Failed to serialize layout.")
        return
    end
    
    local file, err = io.open(obj.save_path, "w")
    if not file then
        -- print("WindowManager: Failed to open layout file for writing: " .. err)
        return
    end
    
    file:write(json_data)
    file:close()
    -- print("WindowManager: Window layout saved.")
    
    -- Debug: Print the current layout before saving
    -- print("=== LAYOUT BEFORE SAVING ===")
    -- for space_id, tree in pairs(obj.trees) do
    --     print("Space " .. space_id .. ":")
    --     if tree.root then
    --         obj:printTreeWindows(tree.root, 0)
    --     end
    -- end
    -- print("=== END LAYOUT BEFORE SAVING ===")
end

--- Loads the layout tree from a JSON file
function obj:loadLayout()
    local file, err = io.open(obj.save_path, "r")
    if not file then
        -- print("WindowManager: No layout file found to load.")
        return
    end
    
    local content = file:read("*a")
    file:close()
    
    if not content or content == "" then
        -- print("WindowManager: Layout file is empty.")
        return
    end
    
    local success, decoded_layout = pcall(hs.json.decode, content)
    
    if not success or not decoded_layout then
        -- print("WindowManager: Failed to decode layout file. Starting fresh.")
        return
    end
    
    -- Create lookup table for windows by bundle ID before reconstruction
    local bundleID_to_windows = {}
    local allSpaces = hs.spaces.allSpaces()
    for screen_id, spaces in pairs(allSpaces) do
        if spaces then
            for _, space_id in ipairs(spaces) do
                local window_ids = hs.spaces.windowsForSpace(space_id)
                if window_ids then
                    for _, window_id in ipairs(window_ids) do
                        local window = hs.window.get(window_id)
                        if window then
                            local app = window:application()
                            if app then
                                local bundleID = app:bundleID()
                                if bundleID then
                                    if not bundleID_to_windows[bundleID] then
                                        bundleID_to_windows[bundleID] = {}
                                    end
                                    table.insert(bundleID_to_windows[bundleID], window)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Helper function to reconstruct a node from saved data
    local function reconstructNode(node_data)
        if not node_data then return nil end
        
        local node = {
            id = node_data.id,
            leaf = node_data.leaf,
            position = node_data.position,
            size = node_data.size,
            split_type = node_data.split_type,
            split_ratio = node_data.split_ratio,
            windows = {},
            child1 = nil,
            child2 = nil,
            parent = nil
        }
        
        -- Set the metatable to give the node access to Node methods
        setmetatable(node, Node)
        
        -- Reconstruct windows using the lookup table
        if node_data.windows then
            for _, window_info in ipairs(node_data.windows) do
                local window = nil
                
                -- Handle both old format (just ID number) and new format (object with id, title, bundleID)
                if type(window_info) == "number" then
                    -- Old format: just window ID
                    window = hs.window.get(window_info)
                else
                    -- New format: object with id, title, bundleID
                    -- First try to find by ID (in case it's still valid)
                    if window_info.id then
                        window = hs.window.get(window_info.id)
                    end
                    
                    -- If not found by ID, use lookup table to find by bundle ID
                    if not window and window_info.bundleID and bundleID_to_windows[window_info.bundleID] then
                        local candidates = bundleID_to_windows[window_info.bundleID]
                        -- Use the first available window for this bundle ID
                        window = candidates[1]
                    end
                end
                
                if window then
                    table.insert(node.windows, window)
                end
            end
        end
        
        -- Reconstruct children
        if node_data.child1 then
            node.child1 = reconstructNode(node_data.child1)
            node.child1.parent = node
        end
        if node_data.child2 then
            node.child2 = reconstructNode(node_data.child2)
            node.child2.parent = node
        end
        
        return node
    end
    
    -- Helper function to clean up empty leaf nodes
    local function cleanupEmptyNodes(node)
        if not node then return nil end
        
        if node.leaf then
            -- If this is a leaf node with no windows, return nil to remove it
            if #node.windows == 0 then
                return nil
            end
            return node
        else
            -- This is an internal node, clean up children first
            if node.child1 then
                node.child1 = cleanupEmptyNodes(node.child1)
            end
            if node.child2 then
                node.child2 = cleanupEmptyNodes(node.child2)
            end
            
            -- If both children are now nil, this internal node should be removed
            if not node.child1 and not node.child2 then
                return nil
            end
            
            -- If only one child remains, promote it to replace this node
            if not node.child1 and node.child2 then
                node.child2.parent = node.parent
                return node.child2
            elseif node.child1 and not node.child2 then
                node.child1.parent = node.parent
                return node.child1
            end
            
            return node
        end
    end

    -- Clear existing trees and load the saved ones
    obj.trees = {}
    for space_id_str, tree_data in pairs(decoded_layout) do
        local space_id = tonumber(space_id_str)
        local tree = {
            root = reconstructNode(tree_data.root),
            selected = nil
        }
        
        -- Clean up empty nodes after reconstruction
        if tree.root then
            tree.root = cleanupEmptyNodes(tree.root)
        end
        
        -- Find the selected node by ID (after cleanup)
        if tree_data.selected and tree.root then
            local function findNodeById(node, target_id)
                if not node then return nil end
                if node.id == target_id then return node end
                local found = findNodeById(node.child1, target_id)
                if found then return found end
                return findNodeById(node.child2, target_id)
            end
            tree.selected = findNodeById(tree.root, tree_data.selected)
        end
        
        -- Focused window tracking removed
        
        -- Only add the tree if it has a valid root after cleanup
        if tree.root then
            obj.trees[space_id] = tree
        end
    end
    
    print("WindowManager: Window layout loaded.")
    
    -- Debug: Print the loaded layout after loading
    -- print("=== LAYOUT AFTER LOADING ===")
    -- for space_id, tree in pairs(obj.trees) do
    --     print("Space " .. space_id .. ":")
    --     if tree.root then
    --         obj:printTreeWindows(tree.root, 0)
    --     else
    --         print("  (empty tree - no valid windows found)")
    --     end
    -- end
    -- print("=== END LAYOUT AFTER LOADING ===")
    
    -- Apply layout to all loaded trees, not just the current space
    for space_id, tree in pairs(obj.trees) do
        if tree.root then
            -- print("Applying layout to space " .. space_id)
            obj:applyLayout(tree.root)
        end
    end
    
    -- Also refresh the current space to handle any new windows
    obj:refreshTree()
end

return obj
