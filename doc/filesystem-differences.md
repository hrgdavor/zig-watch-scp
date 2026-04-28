# Filesystem Watcher Differences

This document captures the key differences between the major filesystem watcher backends and how they interact with editor save behavior.

## Linux / inotify

- Uses `inotify_init1()` and `inotify_add_watch()` to monitor file or directory paths.
- Reports fine-grained event masks such as `IN_MODIFY`, `IN_ATTRIB`, `IN_DELETE_SELF`, `IN_MOVE_SELF`, and more.
- Node-style watchers collapse these into coarse events like `change` and `rename`.
- A modification followed by a rename often becomes `change` / `change` / `rename`.
- Directory watches are usually safer than watching a file directly, because editors often delete and recreate files during atomic saves.
- If a file is deleted and recreated, the original inotify watch may remain attached to the old inode rather than the new file.
- Recursive directory watching on Linux typically requires one inotify watch per subdirectory and can exhaust `fs.inotify.max_user_watches`.
- Common failure mode: `ENOSPC` means the watch table is full, not disk space.

### Atomic write and safe-save behavior

- Many editors write to a temp file, flush it, and then rename it into place.
- This produces rename/create/delete sequences rather than a simple modification event.
- Linux inotify may report the old path or the new path depending on how the rename occurs.
- File watchers on the original inode can miss the replacement if the file is recreated.

## macOS / FSEvents

- FSEvents works at the directory level and reports changes to a directory subtree.
- It is optimized for low overhead and can coalesce multiple rapid changes into a small number of events.
- Event reporting is less precise than inotify: multiple modifications may appear as a single notification.
- Recursive watching is native and cheap.
- This means macOS is often better for large trees, but harder to reason about per-file counts.
- FSEvents may emit generic notifications with the changed path sometimes omitted or long-delayed.

## Windows / ReadDirectoryChangesW

- Watches directories, not individual files.
- Reports actions such as `FILE_ACTION_MODIFIED`, `FILE_ACTION_ADDED`, `FILE_ACTION_REMOVED`, `FILE_ACTION_RENAMED_OLD_NAME`, and `FILE_ACTION_RENAMED_NEW_NAME`.
- The API is asynchronous and buffer-based; if the buffer fills, events can be silently dropped.
- Rename events are split into old/new names, which is useful but also requires careful pairing.
- Windows can emit multiple events for a single logical write and often reports the new name on rename operations.

## File-level watch vs directory-level watch

- File-level watching can fail when the watched file is replaced or deleted and recreated.
- Directory-level watching is more robust for editor atomic saves, because the directory remains watched.
- Most production watcher systems watch the parent directory to handle deletes/recreates properly.

## Polling watchers

- Polling-based watchers (e.g. Node's `fs.watchFile()`) compare file metadata on an interval.
- Useful for network filesystems (NFS, CIFS, SMB) where event mechanisms may not work.
- More expensive: each watched file triggers a stat call on every interval.
- Polling is often the fallback for platforms or environments where native event delivery is unreliable.

## Implications for the statistics tool

- The statistics utility must be aware that event counts and types differ dramatically by platform.
- Event aggregation should not assume exact counts or ordering across Linux, macOS, and Windows.
- Directory-level capture is usually more reliable for editor-safe-save behavior.
- The tool should record raw events plus derived logical groups so platform behavior can be compared instead of conflated.
