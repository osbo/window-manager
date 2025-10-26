# Window Manager Spoon

A high-performance Hammerspoon spoon for macOS window management using Binary Space Partitioning (BSP) trees. Built for rapid keyboard-only navigation and automatic tiling that works seamlessly with native macOS features.

## Overview

This window manager provides the fastest macOS window management experience by combining automatic BSP tiling with intelligent space management. It maintains separate tree structures for each macOS Space, enabling rapid keyboard navigation and automatic window organization without interfering with native macOS behavior.

## Key Features

### Automatic BSP Tiling
- **Binary Space Partitioning**: Windows are automatically organized into a tree structure with horizontal and vertical splits
- **Intelligent Splitting**: New windows are placed based on mouse position relative to existing windows
- **Dynamic Layout**: Tree structure adapts automatically as windows are added, removed, or moved
- **Stack Management**: Multiple windows can occupy the same space in a stack with rotation support

### Multi-Space Architecture
- **Per-Space Trees**: Each macOS Space maintains its own independent BSP tree
- **Lazy Loading**: Only the currently focused space is actively managed for optimal performance
- **Cross-Space Focus**: Maintains focus tracking across spaces while respecting macOS behavior
- **Space Detection**: Automatically detects maximized windows and skips management appropriately

### Advanced Window Operations
- **Neighbor Navigation**: Move focus between adjacent windows using directional commands
- **Window Swapping**: Exchange positions of windows across the tree structure
- **Dynamic Resizing**: Continuous resize operations with real-time split ratio adjustment
- **Tree Rotation**: Rotate tree structure left or right for layout optimization
- **Node Management**: Gather multiple nodes into one or explode single nodes into multiple

### Intelligent Window Filtering
- **Smart Detection**: Automatically excludes system windows, dialogs, and non-standard windows
- **App Filtering**: Filters out specific applications like Raycast, System Settings, Spotlight, and Dock
- **State Awareness**: Ignores minimized, full-screen, and floating windows
- **Performance Optimization**: Only manages windows that benefit from tiling

## User Commands

### Navigation
- **Focus Neighbor**: Move focus to adjacent windows in any direction (left, right, up, down)
- **Next Window**: Rotate through windows in the current stack
- **Window Swapping**: Exchange positions with neighboring windows

### Layout Management
- **Dynamic Resizing**: Start continuous resize operations in any direction
- **Stop Resizing**: End active resize operations
- **Tree Rotation**: Rotate the entire tree structure left or right
- **Reflect Layout**: Switch between horizontal and vertical splits in parent nodes

### Node Operations
- **Gather Nodes**: Combine multiple child nodes into a single parent node
- **Explode Node**: Split a multi-window node into separate individual nodes
- **Toggle Management**: Enable/disable window management without restarting

### Layout Persistence
- **Automatic Saving**: Layouts are automatically saved on sleep and stop events
- **Automatic Loading**: Layouts are restored on wake and startup
- **Cross-Session Persistence**: Window arrangements persist across Hammerspoon restarts

## Architecture

### Core Components

#### Tree Structure
Each macOS Space maintains an independent BSP tree with:
- **Root Node**: Contains all windows in the space with full screen dimensions
- **Internal Nodes**: Split the space horizontally or vertically with configurable ratios
- **Leaf Nodes**: Contain actual windows, supporting multiple windows per leaf (stacking)
- **Selected Node**: Currently active leaf node for operations
- **Focused Window**: The window that receives focus when switching spaces

#### Event System
The window manager subscribes to multiple Hammerspoon events:
- **Window Creation**: Automatically adds new manageable windows to the current space
- **Window Focus**: Updates selected node and maintains focus tracking
- **Window Movement**: Handles drag-and-drop operations and space transitions
- **Window Destruction**: Removes windows and collapses empty nodes
- **Space Changes**: Switches between space trees and refreshes layouts
- **Window Maximization**: Clears focus tracking for full-screen windows

#### Performance Optimizations
- **Lazy Loading**: Only the current space is actively managed
- **Event Throttling**: Window move events are throttled to prevent excessive processing
- **Position Tracking**: Tracks window positions to distinguish user vs system moves
- **Efficient Lookups**: Uses window ID-based comparisons for robust window tracking

### Algorithm Details

#### Window Placement Algorithm
When a window is moved or created:
1. **Position Analysis**: Calculate mouse position relative to existing windows
2. **Edge Detection**: Determine which edge of a window the mouse is closest to
3. **Split Decision**: Create horizontal or vertical splits based on edge proximity
4. **Stack Management**: Add to existing stack if mouse is in center area
5. **Tree Update**: Rebuild tree structure and apply new layout

#### Resize Algorithm
For dynamic window resizing:
1. **Parent Detection**: Find the appropriate split parent in the tree hierarchy
2. **Ratio Calculation**: Update split ratios based on window position changes
3. **Continuous Updates**: Apply changes in real-time during resize operations
4. **Boundary Enforcement**: Maintain valid split ratios between 0.0 and 1.0

#### Space Management Algorithm
For multi-space support:
1. **Space Detection**: Identify the current space using macOS APIs
2. **Tree Selection**: Switch to the appropriate tree for the current space
3. **Window Migration**: Handle windows moving between spaces
4. **Focus Preservation**: Maintain focus state across space transitions

## Configuration

### Window Filtering
The window manager automatically excludes:
- Non-standard windows (dialogs, floating windows)
- Minimized or full-screen windows
- System applications (Raycast, System Settings, Spotlight, Dock, Control Center)
- Windows with invalid states or IDs

### Performance Settings
- **Animation Duration**: Set to 0.0 for instant window movements
- **Event Throttling**: 1-second minimum between window move events
- **Refresh Control**: Prevents recursive refresh calls during operations

### Layout Persistence
- **Save Path**: `~/.hammerspoon/window-manager.layout.json`
- **Auto-Save Triggers**: Sleep events, stop events, window destruction
- **Auto-Load Triggers**: Wake events, startup, space changes

## Integration

### macOS Compatibility
- **Native Space Support**: Works with macOS Spaces and Mission Control
- **Multi-Monitor Support**: Handles multiple displays and their spaces
- **System Integration**: Respects macOS window management conventions
- **Accessibility**: Compatible with VoiceOver and other accessibility features

### Hammerspoon Integration
- **Spoon Architecture**: Follows Hammerspoon spoon conventions
- **Event System**: Uses Hammerspoon's window filter and space watcher APIs
- **Configuration**: Integrates with Hammerspoon's configuration system
- **Logging**: Uses Hammerspoon's logging system for debugging

## Performance Characteristics

### Memory Usage
- **Minimal Overhead**: Only stores essential window and tree data
- **Efficient Storage**: Uses UUIDs for node identification
- **Garbage Collection**: Automatic cleanup of orphaned references

### CPU Usage
- **Event-Driven**: Only processes events when windows change
- **Throttled Operations**: Prevents excessive processing during rapid changes
- **Lazy Evaluation**: Defers expensive operations until necessary

### Responsiveness
- **Instant Feedback**: Window operations provide immediate visual feedback
- **Smooth Animations**: Zero-duration animations for instant movement
- **Non-Blocking**: Operations don't block the main thread

## Technical Implementation

### Data Structures
- **Node Class**: Represents tree nodes with position, size, and window data
- **Tree Objects**: Contain root node, selected node, and focused window
- **Space Mapping**: Maps space IDs to tree objects for multi-space support

### Error Handling
- **Robust Window Operations**: Uses pcall for safe window manipulation
- **Graceful Degradation**: Continues operation even if individual windows fail
- **State Validation**: Validates window and tree states before operations

### Memory Management
- **Reference Tracking**: Maintains proper parent-child relationships
- **Cleanup Operations**: Removes orphaned nodes and invalid references
- **Garbage Collection**: Leverages Lua's garbage collector for cleanup

This window manager represents the fastest and most feature-complete solution for macOS window management, providing both automatic tiling and powerful manual control while maintaining full compatibility with native macOS features.