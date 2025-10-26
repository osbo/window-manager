hs.loadSpoon("window-manager")
local wm = spoon["window-manager"]
wm:start()

-- Keybindings for focusing neighbors
-- Hyper + (a, s, d, f) for (left, down, up, right)
hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "a", function()
    wm:focusNeighbor("left")
end)

hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "s", function()
    wm:focusNeighbor("down")
end)

hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "d", function()
    wm:focusNeighbor("up")
end)

hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "f", function()
    wm:focusNeighbor("right")
end)

-- Keybindings for swapping with neighbors
-- Hyper + (q, w, e, r) for (left, down, up, right)
hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "q", function()
    wm:swapNeighbor("left")
end)

hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "w", function()
    wm:swapNeighbor("down")
end)

hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "e", function()
    wm:swapNeighbor("up")
end)

hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "r", function()
    wm:swapNeighbor("right")
end)

-- Keybinding for reflecting nodes
-- Hyper + T to reflect the parent of the focused window's node
hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "t", function()
    wm:reflect()
end)

-- Keybinding for toggling event listeners
-- Hyper + Y to toggle window manager event listeners
hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "y", function()
    wm:toggleEventListeners()
end)

-- Keybinding for gathering nodes
-- Hyper + H to gather all windows from parent's children into a stack
hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "h", function()
    wm:gatherNodes()
end)

-- Keybinding for exploding nodes
-- Hyper + N to explode current node's windows into separate nodes
hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "n", function()
    wm:explodeNode()
end)

-- Keybinding for rotating windows in current node
-- Hyper + Space to rotate windows in the current node's stack
hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "space", function()
    wm:nextWindow()
    wm:nextWindow()
end)

-- Keybindings for resizing windows (repeatedly while held)
-- Hyper + (z, x, c, v) for (left, down, up, right) resize
hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "z", function()
    wm:resizeWindow("left")
end, function()
    wm:stopResize("left")
end)

hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "x", function()
    wm:resizeWindow("down")
end, function()
    wm:stopResize("down")
end)

hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "c", function()
    wm:resizeWindow("up")
end, function()
    wm:stopResize("up")
end)

hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "v", function()
    wm:resizeWindow("right")
end, function()
    wm:stopResize("right")
end)

hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "g", function()
    wm:rotateLeft()
end)

hs.hotkey.bind({"cmd", "alt", "ctrl", "shift"}, "b", function()
    wm:rotateRight()
end)