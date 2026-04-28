# Tool Handling Insights

This document captures how existing watcher tools and libraries handle editor saves, atomic writes, and build loop noise.

## Watchman

- Watchman watches directory roots recursively and maintains a stable view of filesystem state.
- It waits for a root to settle before triggering actions, which reduces noisy reactions to intermediate changes.
- It is conservative: when uncertainty exists, it treats files as freshly changed.
- Watchman exposes query-based state, allowing tools to ask "what changed since the last check" rather than reacting to every raw event.
- This design is useful for build systems and editors because it separates raw event delivery from actionable change detection.

## Chokidar

- Chokidar is a cross-platform watcher built on Node's `fs.watch`, `fs.watchFile`, and native backends.
- It includes an `awaitWriteFinish` option that delays `add` and `change` events until the file size stabilizes.
- For atomic editor writes, Chokidar can coalesce delete/recreate sequences if the file is re-added within a short timeframe.
- It intentionally filters editor artifacts produced by atomic saves and temporary files.
- This is a useful model for a statistics tool, because it separates raw filesystem noise from logical file writes.

## Node fs.watch semantics

- `fs.watch()` gives two event types: `change` and `rename`.
- On Linux, `change` typically maps to `IN_MODIFY` and `IN_ATTRIB`, while all other file operations map to `rename`.
- On macOS, `FSEvents` may coalesce multiple rapid modifications into a single event or omit some modifications entirely if they happen with a rename.
- On Windows, `ReadDirectoryChangesW` reports detailed actions, but the watcher can drop events if its buffer overflows.
- Important consequence: the same logical file operation may map to different low-level sequences on each platform.

## Build loop and debounce strategies

- Rebuilds and bulk file changes create event storms.
- Reliable watcher systems use aggregation windows or "ready" timeouts before triggering actions.
- Some systems debounce by waiting for a pause in events, while others batch changes for a fixed interval.
- A statistics tool should capture event burst patterns and note when a rebuild is likely rather than treating every event as a separate save.

## Editor save patterns

- Many editors use atomic save patterns:
  - write to a temp file
  - rename temp file into place
  - optionally keep or rename backups
- This creates multiple low-level events for one logical save.
- Editors vary in their behavior, so the tool should not hardcode a single save model.
- Instead, it should cluster events by time and path to infer logical save operations.

## Practical lessons for the new tool

- Record raw watcher events first, then derive logical sessions.
- Use conservative grouping heuristics, similar to Watchman and Chokidar.
- Capture metadata about the watcher backend and platform so comparisons are meaningful.
- Avoid embedding the statistics logic into the main sync tool; a separate statistics utility can run in measurement mode and remain independent.
