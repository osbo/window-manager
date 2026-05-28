# Window Manager

A Hammerspoon spoon that tiles macOS windows with a binary-space-partitioning tree — keyboard-first, mouse-aware, one BSP per Space.

The arrangement on each Space is a BSP tree: every internal node is a horizontal or vertical split, every leaf holds one or more windows. Insertion, focus, swap, resize, rotate, and reflect all walk the tree.

## How it works

1. **Per-Space tree** — each macOS Space holds its own independent BSP. Trees are constructed lazily: only the focused Space is actively managed, so background Spaces don't pay for tracking. Cross-Space focus is preserved through the standard macOS focus events.
2. **Insertion** — when a window appears, the mouse pointer's position picks the leaf it lands on and the edge it crosses; a new internal node splits that leaf horizontally or vertically, with the existing window on one side and the newcomer on the other. Dropping in the center stacks the windows.
3. **Operations** — focus, swap, and resize each walk from the focused leaf up to find the nearest ancestor split with a sibling in the requested direction, then apply the operation. Rotation and reflection rewrite internal-node splits without moving leaves.
4. **Stacks** — a leaf can hold multiple windows in rotation. `Hyper + Space` cycles within the stack; `Hyper + N` explodes the stack into siblings; `Hyper + H` gathers siblings back into one stack.
5. **Filtering** — system surfaces (Spotlight, Raycast, System Settings, dialogs; minimised, fullscreen, and floating windows) are excluded from the tree so they never disrupt the tiling.

## Bindings

All bindings use the Hyper key (`Cmd + Alt + Ctrl + Shift`). Layout follows QWERTY home-row groups: `asdf` for focus, `qwer` above for swap, `zxcv` below for resize.

| Group | Keys | Action |
|---|---|---|
| Focus | `a` `s` `d` `f` | focus left / down / up / right neighbour |
| | `Space` | next window in stack |
| Swap | `q` `w` `e` `r` | swap with left / down / up / right neighbour |
| Resize | `z` `x` `c` `v` | drag the split toward left / down / up / right (hold to repeat) |
| Tree | `g` `b` | rotate parent node left / right |
| | `t` | reflect (flip horizontal / vertical) |
| Stack | `h` | gather siblings into one stack |
| | `n` | explode stack into siblings |
| System | `y` | first press: pause; second press: restart |

## Mouse

Drag a window to move it. On drop, the edge of the target leaf closest to the cursor determines the new split direction; dropping in the center adds the window to the target's stack. Drags work across screens and Spaces — the target Space's BSP is updated transparently.

## Installation

Place this repo at `~/.hammerspoon/Spoons/window-manager.spoon` (or symlink it), then load from `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("window-manager")
spoon["window-manager"]:start()
```

The `init.lua` in this repo shows the full keybinding wire-up and is meant to be copy-pasted into your own Hammerspoon config.

## Stack

- **Lua** — Hammerspoon spoon, no external dependencies

## License

MIT.
