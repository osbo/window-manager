-- All watcher setup functions

local watchers = {}

-- Set up window watcher
function watchers.setupWindowWatcher(obj, helpers)
    obj.windowWatcher = hs.window.filter.new()

    obj.windowWatcher:subscribe(hs.window.filter.windowCreated, function(window)
        if not obj._eventListenersActive or obj.stopWM then return end
        
        local success, err = pcall(function()
            if helpers.isWindowManageable(window) then
                local current_space = hs.spaces.focusedSpace()
                local tree = helpers.getTreeForSpace(obj, current_space)
                if not tree then return end
                
                -- 1. Mutate State
                -- Note: addNode is in tree_operations, we'll need to pass it
                -- For now, we'll use obj:addNode which will be available
                obj:addNode(window, tree)
                
                -- 2. Apply Layout
                obj:applyLayout(tree.root)
            end
        end)
        
        if not success then
            -- print("Error in windowCreated handler: " .. tostring(err))
        end
    end)

    obj.windowWatcher:subscribe(hs.window.filter.windowFocused, function(window)
        if not obj._eventListenersActive or obj.stopWM then return end
        if not helpers.isWindowManageable(window) then return end

        -- Refresh trees to catch any changes (windows closed, minimized, etc.)
        obj:refreshTrees()
        
        local space_id, tree = helpers.getTreeForWindow(obj, window)
        if tree and tree.root then
            local node = tree.root:findNode(window)
            if node then
                tree.selected = node
            end
            -- Apply layout to the focused tree
            obj:applyLayout(tree.root)
            helpers.printTreeWindows(obj, tree.root, 0)
        end
    end)

    -- This listener is already fixed by Step 1 (adding obj._applyingLayout check)
    obj.windowWatcher:subscribe(hs.window.filter.windowMoved, function(window)
        if not obj._eventListenersActive or obj.stopWM or obj._applyingLayout then return end
        if not helpers.isWindowManageable(window) then return end
        obj:windowMovedHandler(window)
    end)

end

-- Set up application watcher (removed - using window focus handler instead)
function watchers.setupApplicationWatcher(obj)
    -- Application watcher removed - window state changes are handled via windowFocused
end

-- Update stopWM and _eventListenersActive based on tracked states
function watchers.updateStopState(obj)
    local shouldStop = obj.stoppedFromCommand or obj.stoppedFromScreens
    local wasStopped = obj.stopWM
    
    obj.stopWM = shouldStop
    obj._eventListenersActive = not shouldStop
    
    -- Only perform actions if state actually changed
    if not wasStopped and shouldStop then
        -- Just stopped - clear trees for the currently focused space
        local focused_space = hs.spaces.focusedSpace()
        if focused_space and obj.trees[focused_space] then
            obj.trees[focused_space] = nil
        end
    elseif wasStopped and not shouldStop then
        -- Just restarted - refresh trees and apply layouts
        obj:refreshTrees()
        obj:applyAllLayouts()
    end
end

-- Set up screen watcher to monitor screen count changes
function watchers.setupScreenWatcher(obj)
    if obj.screenWatcher then
        obj.screenWatcher:stop()
        obj.screenWatcher = nil
    end
    
    obj.screenWatcher = hs.screen.watcher.new(function()
        if not obj.onlyMultiScreen then return end
        
        local screens = hs.screen.allScreens()
        local screenCount = #screens
        
        if screenCount <= 1 then
            -- Only one screen - disable window manager (if not already stopped from command)
            if not obj.stoppedFromScreens then
                print("WindowManager: Screen disconnected, only one screen remaining - disabling window manager")
                obj.stoppedFromScreens = true
                watchers.updateStopState(obj)
            end
        else
            -- Multiple screens - enable window manager (if not stopped from command)
            if obj.stoppedFromScreens then
                -- Only enable if command hasn't also stopped us
                if not obj.stoppedFromCommand then
                    print("WindowManager: Multiple screens detected - enabling window manager")
                    obj.stoppedFromScreens = false
                    watchers.updateStopState(obj)
                else
                    -- Screens are back, but command still has us stopped
                    obj.stoppedFromScreens = false
                    -- Don't call updateStopState since command is still stopping us
                end
            end
        end
    end)
    
    obj.screenWatcher:start()
end

return watchers

