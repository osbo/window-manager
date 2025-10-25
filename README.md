# Window Manager Spoon

A Hammerspoon spoon for managing windows using a Binary Space Partitioning (BSP) tree structure. This window manager automatically organizes windows into a tiled layout and provides focus management across multiple macOS Spaces.

## How It Works

### Core Architecture

The window manager uses a **lazy-loading approach** that only manages windows in the currently focused space. This avoids complex space detection issues and provides better performance.

**Key Components:**
- **Tree Structure**: Each space has its own BSP tree (`obj.trees[space_id]`)
- **Lazy Loading**: Only the current space is actively managed
- **Space Detection**: Automatically detects maximized windows and skips focus management
- **Event Handling**: Responds to window movements, space changes, and focus events

### Tree Structure

Each space maintains a tree with:
- **Root Node**: Contains all windows in the space
- **Leaf Nodes**: Contain actual windows (can have multiple windows in a stack)
- **Internal Nodes**: Split the space horizontally or vertically
- **Selected Node**: Currently active leaf node
- **Focused Window**: The window that should receive focus when switching spaces

### Space Management

- **Current Space Only**: Only manages windows in the currently focused space
- **Maximized Window Detection**: Automatically detects when a space contains only maximized windows and skips focus management
- **Cross-Space Focus**: Tracks focused windows across spaces but validates they're in the current space before focusing

## Available Functions

### Core Functions

#### `obj:start()`
Starts the window manager and sets up event listeners.

#### `obj:stop()`
Stops the window manager and cleans up event listeners.

#### `obj:refreshTree()`
Manually refreshes the tree structure for the current space. Useful for debugging or manual updates.

### Tree Management

#### `obj:getTreeForSpace(space_id)`
Gets or creates a tree for a specific space.

#### `obj:getCurrentTree()`
Gets the tree for the currently focused space.

#### `obj:getTreeForWindow(window)`
Finds which tree contains a specific window.

### Window Operations

#### `obj:addNode(window, forceSpaceId)`
Adds a window to the tree. If `forceSpaceId` is provided, adds to that specific space.

#### `obj:closeWindow(window, optionalTree)`
Removes a window from the tree and cleans up empty nodes.

#### `obj:isWindowManageable(window)`
Checks if a window should be managed by the window manager.

### Layout and Display

#### `obj:applyLayout(node)`
Applies the BSP layout to windows in a tree node.

#### `obj:printTreeWindows(node, depth)`
Prints the tree structure for debugging purposes.

### Event Handlers

#### `obj:windowMovedHandler(window)`
Handles window movement events.

#### `obj:onSpaceChanged()`
Handles space switching events.

## Configuration

### Window Filtering

The window manager automatically filters out certain types of windows:

**Excluded Window Types:**
- Non-standard windows
- Minimized windows
- Full-screen windows
- Floating windows and dialogs
- System windows (Raycast, System Settings, Spotlight, Dock, etc.)

### Space Management

- **Lazy Loading**: Spaces are only initialized when first accessed
- **Maximized Window Detection**: Automatically detects maximized window spaces
- **Focus Tracking**: Maintains focus state across space switches

## Event System

The window manager subscribes to several Hammerspoon events:

- **Window Focus**: Updates selected node and focused window
- **Window Movement**: Refreshes tree structure
- **Window Creation/Destruction**: Adds/removes windows from trees
- **Space Changes**: Switches between space trees
- **Window Maximization**: Clears focus tracking for maximized windows