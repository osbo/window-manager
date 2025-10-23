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
local selected_node = nil

function Node:new(id, type, parent, position, size, split_type, split_ratio)
  local node = {
    id = id,
    type = type, -- boolean: true for internal, false for leaf
    selected = 1, -- index of selected child or window
    windows = {},
    parent = parent,
    child1 = nil,
    child2 = nil,
    position = position,
    size = size,
    split_type = split_type,
    split_ratio = split_ratio,
  }
  setmetatable(node, self)
  return node
end

-- Initialize the spoon
function obj:init()
  return self
end

-- Start the spoon
function obj:start()
--   self:setupWindowWatcher()
--   self:initializeTree()
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
    print("New window created: " .. window:title())
  end)

  self.windowWatcher:subscribe(hs.window.filter.windowFocused, function(window)
    print("Window focused: " .. window:title())
  end)
end

return obj