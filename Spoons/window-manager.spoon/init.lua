local obj = {}
obj.__index = obj

-- Metadata
obj.name = "window-manager"
obj.version = "0.1"
obj.author = "osbo <osbo@mit.edu>"
obj.license = "MIT - https://opensource.org/licenses/MIT"
obj.homepage = "https://github.com/osbo/window-manager"

-- Load modules
-- Get the directory where this file is located
local function script_path()
    local str = debug.getinfo(1, "S").source:sub(2)
    return str:match("(.*/)")
end

local base_path = script_path()
local Node = dofile(base_path .. "node.lua")
local helpers = dofile(base_path .. "helpers.lua")
local watchers = dofile(base_path .. "watchers.lua")
local tree_operations = dofile(base_path .. "tree_operations.lua")
local window_operations = dofile(base_path .. "window_operations.lua")
local layout_operations = dofile(base_path .. "layout_operations.lua")
local menu_bar = dofile(base_path .. "menu_bar.lua")

-- Store Node class in obj for access by other modules
obj.Node = Node

-- Initialize state variables
obj.trees = {} -- Array: [space_id] = { root = node, selected = node }
obj._eventListenersActive = true -- Flag to control event listener activity
obj.stopWM = false -- Dedicated flag to completely stop window manager functionality
obj.stoppedFromCommand = false -- Track if stopped by manual command (Hyper+Y)
obj.stoppedFromScreens = false -- Track if stopped by screen count (onlyMultiScreen)
obj._lastWindowPositions = {} -- Track window positions to detect user vs system moves
obj.lastMoveTime = 0 -- Track last window move time using absoluteTime for throttling
obj.lastRefreshTime = 0 -- Track last refresh time using absoluteTime for throttling
obj.current_space = nil
obj._applyingLayout = false -- Flag to prevent re-entrancy loops during layout application

-- Initialize the spoon
function obj:init()
    obj.save_path = hs.configdir .. "/window-manager.layout.json"
    obj.logTag = "WindowManager"
    return self
end

-- Start the spoon
function obj:start(persistLayout, onlyMultiScreen)
    -- print("WindowManager: Starting")
    
    -- Default persistLayout to false
    if persistLayout == nil then
        persistLayout = false
    end
    
    -- Default onlyMultiScreen to true
    if onlyMultiScreen == nil then
        onlyMultiScreen = true
    end
    
    obj.onlyMultiScreen = onlyMultiScreen
    
    -- Check screen count and disable if only one screen (if onlyMultiScreen is enabled)
    if onlyMultiScreen then
        local screens = hs.screen.allScreens()
        if #screens <= 1 then
            print("WindowManager: Only one screen detected, disabling window manager")
            obj.stoppedFromScreens = true
            obj:updateStopState()
        end
    end
    
    -- Load the previous layout FIRST (only if persistence is enabled)
    if persistLayout then
        obj:loadLayout()
    end

    hs.window.animationDuration = 0.0
    watchers.setupWindowWatcher(obj, helpers)
    watchers.setupApplicationWatcher(obj)
    
    -- Set up screen watcher (only if onlyMultiScreen is enabled)
    if onlyMultiScreen then
        watchers.setupScreenWatcher(obj)
    end
    
    obj:refreshTrees() -- Reconciles state

    -- ADD THIS LINE:
    obj:applyAllLayouts() -- Apply any changes found during reconciliation
    
    -- Set up menu bar
    menu_bar.setup(obj, helpers)
    
    -- Initialize and start the sleep watcher (only if persistence is enabled)
    if persistLayout then
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
    end
    
    return self
end

-- Stop the spoon
function obj:stop()
    -- print("WindowManager: Stopping")
    
    if obj.windowWatcher then
        obj.windowWatcher:delete()
        obj.windowWatcher = nil
    end
    
    -- Stop and remove the application watcher
    if obj.applicationWatcher then
        obj.applicationWatcher:stop()
        obj.applicationWatcher = nil
    end
    
    -- Stop and remove the screen watcher
    if obj.screenWatcher then
        obj.screenWatcher:stop()
        obj.screenWatcher = nil
    end
    
    -- Save the layout one last time on stop/reload (only if persistence was enabled)
    -- Check if caffeinateWatcher exists before stopping it (indicates persistence was enabled)
    if obj.caffeinateWatcher then
        obj:saveLayout()
    end
    
    -- Stop and remove the sleep watcher
    if obj.caffeinateWatcher then
        obj.caffeinateWatcher:stop()
        obj.caffeinateWatcher = nil
    end
    
    -- Remove menu bar item
    if obj.menubar then
        obj.menubar:delete()
        obj.menubar = nil
    end
    
    return self
end

-- ============================================================================
-- Helper functions (delegate to helpers module)
-- ============================================================================

obj.isWindowManageable = function(self, window)
    return helpers.isWindowManageable(window)
end

obj.getTreeForSpace = function(self, space_id)
    return helpers.getTreeForSpace(self, space_id)
end

obj.getScreenForSpace = function(self, space_id)
    return helpers.getScreenForSpace(self, space_id)
end

obj.getCurrentTree = function(self)
    return helpers.getCurrentTree(self)
end

obj.getTreeForWindow = function(self, window)
    return helpers.getTreeForWindow(self, window)
end

obj.getNodeAtPosition = function(self, x, y, ignoreWindow)
    return helpers.getNodeAtPosition(self, x, y, ignoreWindow)
end

obj.findNeighbor = function(self, window, direction)
    return helpers.findNeighbor(self, window, direction)
end

obj.printTreeWindows = function(self, node, depth)
    return helpers.printTreeWindows(self, node, depth)
end

-- ============================================================================
-- Watcher functions (delegate to watchers module)
-- ============================================================================

obj.setupWindowWatcher = function(self)
    return watchers.setupWindowWatcher(self, helpers)
end

obj.setupApplicationWatcher = function(self)
    return watchers.setupApplicationWatcher(self)
end

obj.setupScreenWatcher = function(self)
    return watchers.setupScreenWatcher(self)
end

obj.updateStopState = function(self)
    return watchers.updateStopState(self)
end

-- ============================================================================
-- Tree operations (delegate to tree_operations module)
-- ============================================================================

obj.addNode = function(self, window, tree, child, split_type)
    return tree_operations.addNode(self, Node, helpers, window, tree, child, split_type)
end

obj.addWindowToStack = function(self, window, tree)
    return tree_operations.addWindowToStack(self, window, tree)
end

obj.closeWindow = function(self, window, optionalTree)
    return tree_operations.closeWindow(self, helpers, window, optionalTree)
end

obj.collapseNode = function(self, tree, node)
    return tree_operations.collapseNode(self, tree, node)
end

obj.cleanupEmptyNodesInTree = function(self, tree)
    return tree_operations.cleanupEmptyNodesInTree(self, tree)
end

obj.cleanupEmptyNodes = function(self)
    return tree_operations.cleanupEmptyNodes(self)
end

obj.refreshTree = function(self, tree, windows, space_id)
    return tree_operations.refreshTree(self, helpers, tree, windows, space_id)
end

obj.refreshTrees = function(self)
    return tree_operations.refreshTrees(self, helpers)
end

obj.rotateLeft = function(self)
    return tree_operations.rotateLeft(self, Node, helpers)
end

obj.rotateRight = function(self)
    return tree_operations.rotateRight(self, Node, helpers)
end

obj.reflect = function(self)
    return tree_operations.reflect(self, helpers)
end

obj.reflectNode = function(self, node)
    return tree_operations.reflectNode(self, node)
end

obj.gatherNodes = function(self)
    return tree_operations.gatherNodes(self, helpers)
end

obj.explodeNode = function(self)
    return tree_operations.explodeNode(self, helpers)
end

-- ============================================================================
-- Window operations (delegate to window_operations module)
-- ============================================================================

obj.focusNeighbor = function(self, direction)
    return window_operations.focusNeighbor(self, helpers, direction)
end

obj.nextWindow = function(self)
    return window_operations.nextWindow(self, helpers)
end

obj.resizeWindow = function(self, direction)
    return window_operations.resizeWindow(self, helpers, direction)
end

obj.stopResize = function(self, direction)
    return window_operations.stopResize(self, direction)
end

obj.swapNeighbor = function(self, direction)
    return window_operations.swapNeighbor(self, helpers, direction)
end

obj.windowMovedHandler = function(self, window)
    return window_operations.windowMovedHandler(self, helpers, tree_operations, window)
end

obj.handleWindowResize = function(self, window, currentFrame, lastFrame, tree)
    return window_operations.handleWindowResize(self, window, currentFrame, lastFrame, tree)
end

-- ============================================================================
-- Layout operations (delegate to layout_operations module)
-- ============================================================================

obj.applyLayout = function(self, node)
    return layout_operations.applyLayout(self, helpers, node)
end

obj.applyAllLayouts = function(self)
    return layout_operations.applyAllLayouts(self, helpers)
end

obj.saveLayout = function(self)
    return layout_operations.saveLayout(self, helpers)
end

obj.loadLayout = function(self)
    return layout_operations.loadLayout(self, Node, helpers)
end

obj.reconstructNode = function(self, node_data)
    return layout_operations.reconstructNode(self, Node, node_data)
end

obj.loadTree = function(self, space_id, tree_data)
    return layout_operations.loadTree(self, Node, helpers, space_id, tree_data)
end

-- ============================================================================
-- Shutdown/restart functionality
-- ============================================================================

-- Shutdown/restart window manager system
-- First press: Delete all trees, set stopWM to true
-- Second press: Set stopWM to false and refresh tree
function obj:toggleShutdownRestart()
    if obj.stoppedFromCommand then
        -- Currently stopped from command, restart the system (if screens allow)
        obj.stoppedFromCommand = false
        -- Check if screens want to stop us - if so, keep stopped
        if obj.stoppedFromScreens then
            print("Window manager restart prevented - only one screen detected")
            return false
        else
            print("Window manager RESTARTED")
            obj:updateStopState()
            return true
        end
    else
        -- Currently running, shutdown the system
        obj.stoppedFromCommand = true
        print("Window manager SHUTDOWN")
        obj:updateStopState()
        return false
    end
end

return obj
