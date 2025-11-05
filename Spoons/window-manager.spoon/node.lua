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

return Node

