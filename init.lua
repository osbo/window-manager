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