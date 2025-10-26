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

    obj.trees = {} -- Array: [space_id] = { root = node, selected = node, focused_window = window }
    obj._eventListenersActive = true -- Flag to control event listener activity
    obj._lastWindowPositions = {} -- Track window positions to detect user vs system moves
    obj.lastMoveTime = 0 -- Track last window move time using absoluteTime for throttling
    obj.current_space = nil

-- Initialize the spoon
function obj:init()
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
    hs.window.animationDuration = 0.0
    self:setupWindowWatcher()
    self:refreshTree()
    
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
                local tree = obj:getTreeForSpace(space_id)
                obj:addNode(window, tree)
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

            obj:refreshTree()
        end)
        
        if not success then
            print("Error in windowFocused handler: " .. tostring(err))
        end
    end)

    self.windowWatcher:subscribe(hs.window.filter.windowDestroyed, function(window)
        if not obj._eventListenersActive then return end
        -- FIX: Call the new parameterized function.
        -- It will find the window in *any* tree and remove it.
        obj:closeWindow(window, nil)
    end)

    -- FIX: All move events now call the same robust handler
    self.windowWatcher:subscribe(hs.window.filter.windowMoved, function(window)
        -- print("Spaces: " .. hs.inspect(hs.spaces.allSpaces())) -- all spaces
        if not obj._eventListenersActive then return end
        if obj:isWindowManageable(window) then
            obj:windowMovedHandler(window)
        end
    end)

    self.windowWatcher:subscribe(hs.window.filter.windowInCurrentSpace, function(window)
        if not obj._eventListenersActive then return end
        if obj:isWindowManageable(window) then
            obj:refreshTree()
        end
    end)

    self.windowWatcher:subscribe(hs.window.filter.windowNotInCurrentSpace, function(window)
        if not obj._eventListenersActive then return end
        if obj:isWindowManageable(window) then
            obj:refreshTree()
        end
    end)

    -- Handle window maximization - clear focus tracking when window becomes maximized
    self.windowWatcher:subscribe(hs.window.filter.windowFullscreened, function(window)
        if not obj._eventListenersActive then return end
        print("Window maximized: " .. window:title())
        -- Clear focus tracking for all spaces since maximized windows create their own space
        for space_id, tree in pairs(obj.trees) do
            if tree.focused_window and tree.focused_window:id() == window:id() then
                tree.focused_window = nil
                print("Cleared focus tracking for maximized window")
            end
        end
    end)
end

function obj:getTreeForSpace(space_id)
    if not space_id then
        print("Error: getTreeForSpace called with nil space_id")
        space_id = hs.spaces.focusedSpace()
    end

    if not obj.trees[space_id] then
        -- This is the first time we're seeing this space. Create a new tree.
        print("Creating new tree for space: " .. space_id)
        
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
            selected = new_root,
            focused_window = nil
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

function obj:getNodeAtPosition(x, y)
    print("getNodeAtPosition called with: " .. x .. ", " .. y)
    
    -- Search through all trees
    for space_id, tree in pairs(obj.trees) do
        if tree and tree.root then
            -- Quick bounds check: skip if mouse is outside the root node's bounds
            local root = tree.root
            print("Checking tree " .. space_id .. " bounds: " .. root.position.x .. ", " .. root.position.y .. " size: " .. root.size.w .. "x" .. root.size.h)
            
            if x >= root.position.x and x < root.position.x + root.size.w and
               y >= root.position.y and y < root.position.y + root.size.h then
                print("Mouse is within tree " .. space_id .. " bounds, searching...")
                
                -- Mouse is within this tree's bounds, search for the specific node
                local function findNodeAtPosition(node)
                    if not node then return nil end
                    
                    -- Check if point is within this node's bounds
                    if x >= node.position.x and x < node.position.x + node.size.w and
                       y >= node.position.y and y < node.position.y + node.size.h then
                        
                        if node.leaf then
                            -- This is a leaf node, return it
                            return node
                        else
                            -- This is an internal node, check children
                            local child1_result = findNodeAtPosition(node.child1)
                            if child1_result then 
                                return child1_result 
                            end
                            
                            local child2_result = findNodeAtPosition(node.child2)
                            if child2_result then 
                                return child2_result 
                            end
                            
                            -- If no children contain the point, return this internal node
                            return node
                        end
                    end
                    
                    return nil
                end
                
                local node = findNodeAtPosition(tree.root)
                if node then
                    return node
                end
            end
        end
    end
    
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
        print("Invalid direction: " .. tostring(direction))
        return nil
    end
    
    print("Searching for neighbor in direction '" .. direction .. "' at position: " .. searchX .. ", " .. searchY)
    
    -- Use the existing getNodeAtPosition function
    local neighborNode = obj:getNodeAtPosition(searchX, searchY)
    if neighborNode then
        print("Found neighbor: " .. (neighborNode.windows and neighborNode.windows[1] and neighborNode.windows[1]:title() or "Internal node"))
        return neighborNode
    end
    
    print("No neighbor found in direction '" .. direction .. "'")
    return nil
end

-- Focus a neighbor window in a given direction
-- @param direction String: "left", "right", "up", "down"
-- @return true if neighbor was found and focused, false otherwise
function obj:focusNeighbor(direction)
    print("Focusing neighbor in direction '" .. direction .. "'")

    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        print("No focused window found")
        return false
    end
    
    local neighborNode = obj:findNeighbor(currentWindow, direction)
    if neighborNode and neighborNode.windows and neighborNode.windows[1] then
        neighborNode.windows[1]:focus()
        print("Focused neighbor: " .. neighborNode.windows[1]:title())
        return true
    else
        print("No neighbor found in direction '" .. direction .. "'")
        return false
    end
end

-- Swap the focused node with a neighbor node
-- @param direction String: "left", "right", "up", "down"
-- @return true if swap was successful, false otherwise
function obj:swapNeighbor(direction)
    print("Swapping with neighbor in direction '" .. direction .. "'")
    
    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        print("No focused window found")
        return false
    end
    
    -- Find the node containing the focused window
    local space_id, tree = obj:getTreeForWindow(currentWindow)
    if not tree or not tree.root then
        print("No tree found for focused window: " .. currentWindow:title())
        return false
    end
    
    local focusedNode = tree.root:findNode(currentWindow)
    if not focusedNode or not focusedNode.leaf then
        print("Focused window not found in tree or not a leaf node")
        return false
    end
    
    -- Find the neighbor node
    local neighborNode = obj:findNeighbor(currentWindow, direction)
    if not neighborNode or not neighborNode.leaf then
        print("No neighbor found in direction '" .. direction .. "' or neighbor is not a leaf")
        return false
    end
    
    print("Swapping focused node with neighbor node")
    
    -- Find the neighbor's tree
    local neighborSpace_id, neighborTree = obj:getTreeForWindow(neighborNode.windows[1])
    if not neighborTree then
        print("Could not find tree for neighbor node")
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
    
    print("Successfully swapped nodes")
    return true
end

-- Reflect the parent of the currently focused window
-- @return true if reflection was successful, false otherwise
function obj:reflect()
    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        print("No focused window found")
        return false
    end
    
    local space_id, tree = obj:getTreeForWindow(currentWindow)
    if not tree or not tree.root then
        print("No tree found for focused window: " .. currentWindow:title())
        return false
    end
    
    local node = tree.root:findNode(currentWindow)
    if not node then
        print("Focused window not found in tree")
        return false
    end
    
    local parent = node.parent
    if not parent then
        print("Focused window's node has no parent (it's the root)")
        return false
    end
    
    print("Reflecting parent node of focused window")
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
    
    print("Reflecting node with split_type: " .. tostring(node.split_type))
    
    -- Switch split type
    node.split_type = not node.split_type
    
    -- If switching from vertical to horizontal, swap children
    if node.split_type then -- now horizontal (was vertical)
        print("Swapping children for vertical to horizontal transition")
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
    print("Window moved: " .. window:title())
    
    -- Throttle window move events to prevent excessive calls
    local currentTime = hs.timer.absoluteTime()
    if obj.lastMoveTime > 0 and (currentTime - obj.lastMoveTime) < 1000000000 then -- 1 second in nanoseconds
        print("Throttling window move event - too soon since last move")
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
        print("System move detected - ignoring")
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
        print("User drag detected - allowing window to move freely")
        -- Just refresh the tree to clean up any orphaned references
        obj:refreshTree()
        return
    end

    local targetScreen = hs.mouse.getCurrentScreen()
    local targetSpace = hs.spaces.activeSpaceOnScreen(targetScreen)
    local targetTree = obj:getTreeForSpace(targetSpace)

    print("Target tree before move:")
    obj:printTreeWindows(targetTree.root, 0)

    local windowSpaceId, windowTree = obj:getTreeForWindow(window)
    local windowScreen = obj:getScreenForSpace(windowSpaceId)
    if windowScreen then
        print("Window screen: " .. windowScreen:name())
    else
        print("Window screen not found")
    end

    if windowTree then
        print("Window tree before move:")
        obj:printTreeWindows(windowTree.root, 0)
    else
        print("Window tree not found")
    end

    if lastFrame and (math.abs(currentFrame.w - lastFrame.w) > 1 or math.abs(currentFrame.h - lastFrame.h) > 1) and targetScreen == windowScreen then
        print("Window resized: " .. window:title())
        obj:handleWindowResize(window, currentFrame, lastFrame, targetTree)
        return
    end

    -- Use absolute mouse position (no coordinate transformation needed)
    local mousePosition = hs.mouse.absolutePosition()

    print("Mouse position: " .. mousePosition.x .. ", " .. mousePosition.y)
    print("Number of trees: " .. (function() local count = 0; for _ in pairs(obj.trees) do count = count + 1 end; return count end)())
    
    -- Debug: Print all tree bounds
    for space_id, tree in pairs(obj.trees) do
        if tree and tree.root then
            local root = tree.root
            print("Tree " .. space_id .. " bounds: " .. root.position.x .. ", " .. root.position.y .. " size: " .. root.size.w .. "x" .. root.size.h)
        end
    end

    local node = obj:getNodeAtPosition(mousePosition.x, mousePosition.y)
    
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
        
        local distToLeft = mouseX - nodeX
        local distToRight = (nodeX + nodeW) - mouseX
        local distToTop = mouseY - nodeY
        local distToBottom = (nodeY + nodeH) - mouseY
        
        -- Find the minimum distance to determine closest edge
        local minDistance = math.min(distToLeft, distToRight, distToTop, distToBottom)
        
        -- Check if mouse is in center area (not too close to any edge)
        local centerThreshold = math.min(nodeW, nodeH) * 0.33 -- 33% of smaller dimension
        if minDistance > centerThreshold then
            print("Adding to stack (center area)")
            obj:addWindowToStack(window, targetTree)
        elseif minDistance == distToLeft then
            print("Splitting left (closest to left edge)")
            obj:addNode(window, targetTree, 1, true)
        elseif minDistance == distToRight then
            print("Splitting right (closest to right edge)")
            obj:addNode(window, targetTree, 2, true)
        elseif minDistance == distToTop then
            print("Splitting up (closest to top edge)")
            obj:addNode(window, targetTree, 1, false)
        elseif minDistance == distToBottom then
            print("Splitting down (closest to bottom edge)")
            obj:addNode(window, targetTree, 2, false)
        else
            print("Adding to stack (fallback)")
            obj:addWindowToStack(window, targetTree)
        end
    else
        print("No node at mouse position")
    end

    print("Target tree after move:")
    obj:printTreeWindows(targetTree.root, 0)

    print("Window tree after move:")
    if windowTree and windowTree.root then
        obj:printTreeWindows(windowTree.root, 0)
    else
        print("Window tree not found")
    end
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
        print("Node not found")
        return
    end

    local parent = node.parent
    if not parent then
        print("Parent not found, node is root")
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
                print("Resizing left: " .. parentNode.split_ratio)
                found = true
                break
            end
            childNode = parentNode
            parentNode = parentNode.parent
        end
        if not found then
            print("Reached root node, no internal node found, not resizing left")
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
                print("Resizing down: " .. parentNode.split_ratio)
                found = true
                break
            end
            childNode = parentNode
            parentNode = parentNode.parent
        end
        if not found then
            print("Reached root node, no internal node found, not resizing down")
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
                print("Resizing up: " .. parentNode.split_ratio)
                found = true
                break
            end
            childNode = parentNode
            parentNode = parentNode.parent
        end
        if not found then
            print("Reached root node, no internal node found, not resizing up")
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
                print("Resizing right: " .. parentNode.split_ratio)
                found = true
                break
            end
            childNode = parentNode
            parentNode = parentNode.parent
        end
        if not found then
            print("Reached root node, no internal node found, not resizing right")
        end
    end

    self:applyLayout(tree.root)
end


---
--- NEW: Handle space switching - simplified to just track focus, let macOS handle actual focusing
---
function obj:onSpaceChanged()
    print("Space changed.")
    
    -- Just refresh the tree to clean up any stale references
    obj:refreshTree()
    
    -- No manual focusing - let macOS handle it naturally
    print("Space switched - letting macOS handle focus naturally")
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
    
    print("Adding window: " .. window:title() .. " to tree")
    
    -- Case 1: Empty root
    if tree.root.leaf and #tree.root.windows == 0 then
        table.insert(tree.root.windows, window)
        tree.selected = tree.root
        self:applyLayout(tree.root)
        return
    end
    
    -- Case 2: Empty selected leaf
    if tree.selected and tree.selected.leaf and #tree.selected.windows == 0 then
        table.insert(tree.selected.windows, window)
        self:applyLayout(tree.root)
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
    
    self:applyLayout(tree.root)
end

function obj:addWindowToStack(window, tree)
    if not window or not window:id() then return end
    if not tree or not tree.selected then return end
    
    -- Add window to the selected node's windows table (at the end for frontmost)
    table.insert(tree.selected.windows, window)
    
    -- Apply layout to update the display
    self:applyLayout(tree.root)
    
    print("Added window to stack: " .. window:title() .. " (index " .. #tree.selected.windows .. ")")
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

function obj:refreshTree()
    -- Prevent recursive calls
    if obj._refreshing then
        print("Already refreshing, skipping...")
        return
    end
    
    obj._refreshing = true
    print("Refreshing tree")

    local current_space = hs.spaces.focusedSpace()
    obj.current_space = current_space
    print("Current space: " .. current_space)

    local tree = obj:getTreeForSpace(current_space)
    -- print("Tree: " .. hs.inspect(tree))

    local windows = hs.window.orderedWindows()
    local focused_screen_id = hs.screen.mainScreen():id()

    for _, window in ipairs(windows) do
        if obj:isWindowManageable(window) and window:screen():id() == focused_screen_id and not tree.root:findNode(window) then
            local space_id, tree = obj:getTreeForWindow(window)
            if space_id and tree then
                obj:closeWindow(window, tree)
            end
            obj:addNode(window, tree)
        end
    end

    local all_windows_in_tree = tree.root:getAllLeafWindows()

    for _, window in ipairs(all_windows_in_tree) do
        if not obj:isWindowManageable(window) or window:screen():id() ~= focused_screen_id or not hs.fnutils.contains(windows, window) then
            print("Removing stale window: " .. (window:title() or "Invalid"))
            obj:closeWindow(window, tree)
        end
    end

    for space_id, tree in pairs(obj.trees) do
        obj:applyLayout(tree.root)
    end
    
    -- Clear the refreshing flag
    obj._refreshing = false
end

return obj
