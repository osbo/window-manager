Node class:
- id
- type boolean (internal/leaf)
- selected index (child or window)
- parent / child1 / child2
- position (top left corner)
- size (width and height)
- split type (internal only) (vertical/horizontal)
- split ratio (internal only) (0.5 default)


Global:
- Current node (id)
- Hold (Boolean: turn on while not using bsp, or while bsp is calculating. Windows only move/resize while false)


BSP functions:

AddNew (node/window):
Split leaf node into internal node: assign full current node to first child, new window to second child.

Rotate (L/R):
Rotate the tree

Flip (horizontal/vertical):
Reflect along x or y axis


Node functions:

FindNeighbor (directional):
Return node neighbor in requested direction

Close window:
Remove window from stack. If stack empty, make other element in the internal node the second leaf of the prior internal node

Swap (directional) (node/window):
Swap position and size of node/window with neighbor node/window

Push (directional) (node/window):
Insert node into where its neighbor would be, splitting its neighbors space. Where one node would be, 2 now are. If window, remove window from current stack, pushing into new node.

Join (directional) (node/window):
Insert into neighbor node. If node, insert windows in current order into neighbor node. If window, take only active window from node and merge into neighbor node’s stack.

Resize (directional):
Find the correct split: either parent or parent.parent, adjust the split ratio.

Explode node:
Turn all windows in current node into new nodes containing one window each.

Gather nodes:
Gather all windows from nodes lower than current node into current node preserving order.

Reflect:
Switch between horizontal/vertical orientation