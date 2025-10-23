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

obj.selected_node = nil

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
            if w == window then
                return self
            end
        end
        return nil
    else
        local found = self.child1:findNode(window)
        if found then return found end
        return self.child2:findNode(window)
    end
end

obj.root_node = nil

-- Initialize the spoon
function obj:init()
    return self
end

-- Start the spoon
function obj:start()
    print("Windows in current space: " .. #hs.window.allWindows())
    -- self:setupWindowWatcher()
    -- self:initializeTree()
    return self
end

-- Stop the spoon
function obj:stop()
    if self.windowWatcher then
        self.windowWatcher:delete()
        self.windowWatcher = nil
    end
    return self
end

-- Set up window watcher
function obj:setupWindowWatcher()
    self.windowWatcher = hs.window.filter.new()

    self.windowWatcher:subscribe(hs.window.filter.windowCreated, function(window)
        obj:addNode(window)
    end)

    self.windowWatcher:subscribe(hs.window.filter.windowFocused, function(window)
        if obj.root_node then
            obj.selected_node = obj.root_node:findNode(window)
        end
    end)

    self.windowWatcher:subscribe(hs.window.filter.windowDestroyed, function(window)
        obj:closeWindow(window)
    end)
end

---
--- Applies the layout from the tree to the actual windows
--- @param node (Node) The node to start applying layout from (usually root)
---
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
      win:setFrame(frame)
    end
  end
end
  
function obj:addNode(window)
    print("Adding new window: " .. window:title())
  
    -- Case 1: No root node. This is the first window.
    if not obj.root_node then
        local frame = hs.screen.mainScreen():frame()
        obj.root_node = Node:new(
            hs.host.uuid(),  -- Generate unique UUID for node ID
            true,        -- true = leaf node
            nil,          -- no parent
            1,
            {window},
            {x=frame.x, y=frame.y},
            {w=frame.w, h=frame.h},
            nil, -- no split type
            nil, -- no split ratio
            nil, -- no child1
            nil -- no child2
        )
        obj.selected_node = obj.root_node
        obj:applyLayout(obj.root_node)
        return
    end

    if obj.selected_node == nil then
        print("Error: selected_node is nil. Cannot add window.")
        -- As a fallback, let's select the root node
        obj.selected_node = obj.root_node
        -- TODO: We should probably find the first leaf, but this is safer for now
        if not obj.selected_node.leaf then
            print("Error: Root is not a leaf and selected_node was nil. Giving up.")
            return
        end
    end

    -- Case 2a: Selected leaf is empty.
    if obj.selected_node.leaf and #obj.selected_node.windows == 0 then
        print("Adding window to empty leaf: " .. obj.selected_node.id)
        table.insert(obj.selected_node.windows, window)
        obj.selected_node.selected = 1
        obj:applyLayout(obj.root_node)
        return
    end
  
    -- Case 2b: Split selected leaf node into internal node, select new window.
    if not obj.selected_node.leaf then
        print("Error: selected_node is an internal node. Cannot split.")
        -- TODO: We should find the first leaf *under* this internal node
        return
    end

    print("Splitting leaf node: " .. obj.selected_node.id)
    local internal = obj.selected_node

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
    obj.selected_node = child2
    
    -- 5. Apply the layout. This will do all the math.
    obj:applyLayout(obj.root_node)
    return
end

function obj:closeWindow(window)
    if not obj.root_node then return end
    
    local node = obj.root_node:findNode(window)
    if not node then return end
    
    -- Remove window from the node's windows list
    for i, w in ipairs(node.windows) do
        if w == window then
            table.remove(node.windows, i)
            break
        end
    end
    
    -- If node is now empty, collapse it
    if #node.windows == 0 then
        obj:collapseNode(node)
    else
        -- Reapply layout after window removal
        obj:applyLayout(obj.root_node)
    end
end

function obj:collapseNode(node)
    if not node.parent then
        -- This is the root node, set it to nil
        obj.root_node = nil
        obj.selected_node = nil
        return
    end
    
    local parent = node.parent
    local sibling = (parent.child1 == node) and parent.child2 or parent.child1
    
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
        obj.root_node = sibling
        sibling.parent = nil
        -- The sibling's position and size must be updated to fill the root frame
        sibling.position = parent.position
        sibling.size = parent.size
    end
    
    -- Update selected node if it was the collapsed node
    if obj.selected_node == node then
        obj.selected_node = sibling
    end
    
    -- Reapply layout
    obj:applyLayout(obj.root_node)
end

function obj:initializeTree()
    -- Add all windows in current space to the tree, in z order
    for _, window in ipairs(hs.window.allWindows()) do
        obj:addNode(window)
    end
end

return obj

