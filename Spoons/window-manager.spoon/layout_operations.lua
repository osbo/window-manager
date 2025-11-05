-- Layout application and persistence operations

local layout_operations = {}

function layout_operations.applyLayout(obj, helpers, node)
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
            layout_operations.applyLayout(obj, helpers, node.child1)
        end
        if node.child2 then
            node.child2.position = pos2
            node.child2.size = size2
            layout_operations.applyLayout(obj, helpers, node.child2)
        end
    
    else
        -- This is a leaf node, apply our frame to all windows in our stack
        local frame = {
            x = node.position.x,
            y = node.position.y,
            w = node.size.w,
            h = node.size.h
        }
        
        -- Safety check: if node has no windows, it's an empty leaf node - this is safe
        if not node.windows or #node.windows == 0 then
            -- Empty leaf node - this is normal and safe, just return
            return
        end
        
        for _, win in ipairs(node.windows) do
            if helpers.isWindowManageable(win) then
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
end

---
--- NEW: Master function to apply layout to ALL trees
---
function layout_operations.applyAllLayouts(obj, helpers)
    -- Prevent re-entrancy loops. If we're already in this function, just return.
    if obj._applyingLayout then return end
    
    obj._applyingLayout = true
    
    -- Apply layout to all known trees
    for space_id, tree in pairs(obj.trees) do
        if tree.root then
            layout_operations.applyLayout(obj, helpers, tree.root)
        end
    end
    
    obj._applyingLayout = false
end

--- Saves the current layout tree to a JSON file
function layout_operations.saveLayout(obj, helpers)
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
        
        -- IMPORTANT: Save window titles and application names for reconstruction
        if node.windows then
            for _, win in ipairs(node.windows) do
                if win and win:id() then
                    local success, app = pcall(win.application, win)
                    local app_name = "unknown"
                    local window_index = nil
                    local window_title = "Unknown"
                    local window_id = win:id()
                    
                    -- Safely get window title
                    local title_success, title = pcall(win.title, win)
                    if title_success and title then
                        window_title = title
                    end
                    
                    -- Safely get application info
                    if success and app then
                        local app_success, name = pcall(app.name, app)
                        if app_success and name then
                            app_name = name
                        end
                        
                        -- Find the window's index within its application's window list
                        local windows_success, windows = pcall(app.allWindows, app)
                        if windows_success and windows then
                            for i, app_win in ipairs(windows) do
                                local win_id_success, app_win_id = pcall(app_win.id, app_win)
                                if win_id_success and app_win_id and app_win_id == window_id then
                                    window_index = i
                                    break
                                end
                            end
                        end
                    end
                    
                    local window_info = {
                        id = window_id,
                        title = window_title,
                        appName = app_name,
                        windowIndex = window_index
                    }
                    table.insert(clean_node.windows, window_info)
                    print("Saving window: " .. window_title .. " (ID: " .. window_id .. ", App: " .. app_name .. ", Index: " .. tostring(window_index) .. ")")
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
        print("WindowManager: Failed to serialize layout.")
        return
    end
    
    local file, err = io.open(obj.save_path, "w")
    if not file then
        print("WindowManager: Failed to open layout file for writing: " .. err)
        return
    end
    
    file:write(json_data)
    file:close()
    print("WindowManager: Window layout saved.")
    
    -- Debug: Print the current layout before saving
    print("=== LAYOUT BEFORE SAVING ===")
    for space_id, tree in pairs(obj.trees) do
        print("Space " .. space_id .. ":")
        if tree.root then
            helpers.printTreeWindows(obj, tree.root, 0)
        end
    end
    print("=== END LAYOUT BEFORE SAVING ===")
end

-- Helper function to reconstruct a node from saved data
function layout_operations.reconstructNode(obj, Node, node_data)
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
    
    -- Reconstruct windows using improved matching logic
    if node_data.windows then
        for _, window_info in ipairs(node_data.windows) do
            local appName = window_info.appName
            local savedTitle = window_info.title
            local savedId = window_info.id
            local windowIndex = window_info.windowIndex
            
            print("Looking for window: " .. savedTitle .. " (ID: " .. savedId .. ", App: " .. appName .. ", Index: " .. tostring(windowIndex) .. ")")
            
            local window = nil
            
            -- Method 1: Try to find by window ID first (most reliable)
            if savedId then
                local success, allWindows = pcall(hs.window.allWindows)
                if success and allWindows then
                    for _, win in ipairs(allWindows) do
                        local winId = win and win:id()
                        if winId and winId == savedId then
                            window = win
                            print("Found window by ID: " .. (win:title() or "Unknown"))
                            break
                        end
                    end
                end
            end
            
            -- Method 2: If not found by ID, try by application + title
            if not window and appName and savedTitle then
                local success, app = pcall(hs.application.get, appName)
                if success and app then
                    local success2, windows = pcall(app.allWindows, app)
                    if success2 and windows then
                        for _, win in ipairs(windows) do
                            local winTitle = win and win:title()
                            if winTitle and winTitle == savedTitle then
                                window = win
                                print("Found window by app+title: " .. winTitle)
                                break
                            end
                        end
                    end
                end
            end
            
            -- Method 3: If still not found, try by application + index (fallback)
            if not window and appName and windowIndex then
                local success, app = pcall(hs.application.get, appName)
                if success and app then
                    local success2, windows = pcall(app.allWindows, app)
                    if success2 and windows and windows[windowIndex] then
                        window = windows[windowIndex]
                        local winTitle = window and window:title()
                        print("Found window by app+index: " .. (winTitle or "Unknown"))
                    end
                end
            end
            
            -- Method 4: If still not found, try to find any window from the same app
            if not window and appName then
                local success, app = pcall(hs.application.get, appName)
                if success and app then
                    local success2, windows = pcall(app.allWindows, app)
                    if success2 and windows and #windows > 0 then
                        window = windows[1] -- Take the first available window
                        local winTitle = window and window:title()
                        print("Found window by app only (first available): " .. (winTitle or "Unknown"))
                    end
                end
            end
            
            if window then
                table.insert(node.windows, window)
                local winTitle = window and window:title()
                print("Successfully reconstructed window: " .. (winTitle or "Unknown"))
            else
                print("Failed to reconstruct window: " .. (savedTitle or "Unknown") .. " from app: " .. (appName or "Unknown"))
            end
        end
    end
    
    -- Reconstruct children
    if node_data.child1 then
        node.child1 = layout_operations.reconstructNode(obj, Node, node_data.child1)
        node.child1.parent = node
    end
    if node_data.child2 then
        node.child2 = layout_operations.reconstructNode(obj, Node, node_data.child2)
        node.child2.parent = node
    end
    
    return node
end

function layout_operations.loadTree(obj, Node, helpers, space_id, tree_data)
    print("Lazy loading tree for space: " .. space_id)
    local tree = {
        root = layout_operations.reconstructNode(obj, Node, tree_data.root),
        selected = nil
    }
    print("Tree: " .. hs.inspect(tree))
    
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
    
    -- Only add the tree if it has a valid root after cleanup
    if tree.root then
        print("Successfully loaded tree for space: " .. space_id)
        obj.trees[space_id] = tree
        return true
    else
        print("Failed to load tree for space: " .. space_id .. " - no valid root")
        return false
    end
end

--- Loads the layout tree from a JSON file
function layout_operations.loadLayout(obj, Node, helpers)
    local file, err = io.open(obj.save_path, "r")
    if not file then
        print("WindowManager: No layout file found to load.")
        return
    end
    
    local content = file:read("*a")
    file:close()
    
    if not content or content == "" then
        print("WindowManager: Layout file is empty.")
        return
    end
    
    local success, decoded_layout = pcall(hs.json.decode, content)

    if not success or not decoded_layout then
        print("WindowManager: Failed to decode layout file. Starting fresh.")
        return
    end

    local activeSpaces = hs.spaces.activeSpaces()
    local currentSpaces = {}
    for space_id, space in pairs(activeSpaces) do
        currentSpaces[space] = true
    end

    -- Clear existing trees and load the saved ones
    obj.trees = {}
    for space_id_str, tree_data in pairs(decoded_layout) do
        local space_id = tonumber(space_id_str)
        if currentSpaces[space_id] then
            local success = layout_operations.loadTree(obj, Node, helpers, space_id, tree_data)
            if not success then
                print("Failed to load tree for space: " .. space_id)
            end
        else
            print("Space " .. space_id .. " not active, skipping")
        end
    end
    
    -- Apply layout to all loaded trees
    layout_operations.applyAllLayouts(obj, helpers)
    
    print("WindowManager: Window layout loaded.")
    
    -- Debug: Print the loaded layout after loading
    print("=== LAYOUT AFTER LOADING ===")
    for space_id, tree in pairs(obj.trees) do
        print("Space " .. space_id .. ":")
        if tree.root then
            helpers.printTreeWindows(obj, tree.root, 0)
        else
            print("  (empty tree - no valid windows found)")
        end
    end
    print("=== END LAYOUT AFTER LOADING ===")
end

return layout_operations

