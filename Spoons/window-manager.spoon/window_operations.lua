-- Window-focused operations

local window_operations = {}

-- Focus a neighbor window in a given direction
-- @param direction String: "left", "right", "up", "down"
-- @return true if neighbor was found and focused, false otherwise
function window_operations.focusNeighbor(obj, helpers, direction)
    -- print("Focusing neighbor in direction '" .. direction .. "'")

    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        -- print("No focused window found")
        return false
    end
    
    local neighborNode = helpers.findNeighbor(obj, currentWindow, direction)
    if neighborNode and neighborNode.windows and neighborNode.windows[1] then
        local neighborWindow = neighborNode.windows[1]
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
function window_operations.nextWindow(obj, helpers)
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
    
    -- Rotate the windows table: move the front window to the back
    local frontWindow = table.remove(node.windows, 1)
    table.insert(node.windows, frontWindow)
    
    -- Focus the new front window
    node.windows[1]:focus()
    
    -- Update tree selection
    tree.selected = node
    
    -- Apply layout to all trees
    obj:applyLayout(node)
    
    -- print("Rotated windows in node, now focused: " .. node.windows[1]:title())
    return true
end

-- Resize the current window by adjusting split ratios
-- @param direction String: "left", "right", "up", "down"
-- @return true if resize was successful, false otherwise
function window_operations.resizeWindow(obj, helpers, direction)
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
        
        -- Apply layout to the tree
        if targetParent then
            obj:applyLayout(targetParent)
        end
    end)
    
    -- print("Started continuous resizing in direction: " .. direction)
    return true
end

-- Stop resizing in a specific direction
function window_operations.stopResize(obj, direction)
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
function window_operations.swapNeighbor(obj, helpers, direction)
    -- print("Swapping with neighbor in direction '" .. direction .. "'")
    
    local currentWindow = hs.window.focusedWindow()
    if not currentWindow then
        -- print("No focused window found")
        return false
    end
    
    -- Find the node containing the focused window
    local space_id, tree = helpers.getTreeForWindow(obj, currentWindow)
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
    local neighborNode = helpers.findNeighbor(obj, currentWindow, direction)
    if not neighborNode or not neighborNode.leaf then
        -- print("No neighbor found in direction '" .. direction .. "' or neighbor is not a leaf")
        return false
    end
    
    -- print("Swapping focused node with neighbor node")
    
    -- Find the neighbor's tree
    local neighborSpace_id, neighborTree = helpers.getTreeForWindow(obj, neighborNode.windows[1])
    if not neighborTree then
        -- print("Could not find tree for neighbor node")
        return false
    end
    
    -- Swap contents
    focusedNode.windows, neighborNode.windows = neighborNode.windows, focusedNode.windows

    -- Update tree selections
    neighborTree.selected = neighborNode

    -- Apply layout to all trees
    if tree and tree.root then
        obj:applyLayout(tree.root)
    end
    if neighborTree and neighborTree.root and neighborTree.root ~= tree.root then
        obj:applyLayout(neighborTree.root)
    end
    
    -- print("Successfully swapped nodes")
    return true
end

---
--- REWRITTEN: Handles all window movement and space invalidation
---
function window_operations.windowMovedHandler(obj, helpers, tree_ops, window)
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
        return
    end

    local targetScreen = hs.mouse.getCurrentScreen()
    print("Target screen: " .. targetScreen:name())
    local targetSpace = hs.spaces.activeSpaceOnScreen(targetScreen)
    print("Target space: " .. targetSpace)
    local targetTree = helpers.getTreeForSpace(obj, targetSpace)

    print("Target tree before move:")
    helpers.printTreeWindows(obj, targetTree.root, 0)

    local windowSpaceId, windowTree = helpers.getTreeForWindow(obj, window)
    local windowScreen = helpers.getScreenForSpace(obj, windowSpaceId)
    if windowScreen then
        print("Window screen: " .. windowScreen:name())
    else
        print("Window screen not found")
    end

    if windowTree then
        print("Window tree before move:")
        helpers.printTreeWindows(obj, windowTree.root, 0)
    else
        print("Window tree not found")
    end

    if lastFrame and (math.abs(currentFrame.w - lastFrame.w) > 1 or math.abs(currentFrame.h - lastFrame.h) > 1) and targetScreen == windowScreen then
        print("Window resized: " .. window:title())
        window_operations.handleWindowResize(obj, window, currentFrame, lastFrame, targetTree)

        obj:applyLayout(targetTree.root)
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

    local node = helpers.getNodeAtPosition(obj, mousePosition.x, mousePosition.y, window)
    if not node then
        node = helpers.getTreeForSpace(obj, targetSpace).root
    end
    
    if node then
        -- Store node info in local variables to prevent corruption
        local nodeX = node.position.x
        local nodeY = node.position.y
        local nodeW = node.size.w
        local nodeH = node.size.h
        
        tree_ops.closeWindow(obj, helpers, window, windowTree)
        
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
        print("Node dimensions: " .. nodeW .. "x" .. nodeH)
        print("Mouse distances - Left: " .. distToLeft .. ", Right: " .. distToRight .. ", Top: " .. distToTop .. ", Bottom: " .. distToBottom)
        print("Min distance: " .. minDistance .. ", Center threshold: " .. centerThreshold)
        
        if minDistance > centerThreshold then
            print("Adding to stack (center area)")
            tree_ops.addWindowToStack(obj, window, targetTree)
        elseif minDistance == distToLeft then
            print("Splitting left (closest to left edge)")
            tree_ops.addNode(obj, obj.Node, helpers, window, targetTree, 1, true)
        elseif minDistance == distToRight then
            print("Splitting right (closest to right edge)")
            tree_ops.addNode(obj, obj.Node, helpers, window, targetTree, 2, true)
        elseif minDistance == distToTop then
            print("Splitting up (closest to top edge)")
            tree_ops.addNode(obj, obj.Node, helpers, window, targetTree, 1, false)
        elseif minDistance == distToBottom then
            print("Splitting down (closest to bottom edge)")
            tree_ops.addNode(obj, obj.Node, helpers, window, targetTree, 2, false)
        else
            print("Adding to stack (fallback)")
            tree_ops.addWindowToStack(obj, window, targetTree)
        end
    else
        print("No node at mouse position")
    end

    print("Target tree after move:")
    helpers.printTreeWindows(obj, targetTree.root, 0)

    print("Window tree after move:")
    if windowTree and windowTree.root then
        helpers.printTreeWindows(obj, windowTree.root, 0)
    else
        print("Window tree not found")
    end

    -- Apply layout to all trees after window move operations
    obj:applyLayout(targetTree.root)
    if windowTree and windowTree.root and windowTree.root ~= targetTree.root then
        obj:applyLayout(windowTree.root)
    end
end

function window_operations.handleWindowResize(obj, window, currentFrame, lastFrame, tree)
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
end

return window_operations

