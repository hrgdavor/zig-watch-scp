

# 1. change tracking optimizations

## 1.1 Insights from similar projects:

Here are some general insights

- watchman/chokidar/notify: normalize noisy watcher events, debounce and coalesce them, and translate OS-level events into logical file operations
- VS Code: special handling for atomic save patterns and editor-write sequences, because one logical save often becomes multiple filesystem events
- webpack/watchpack: group rapid event bursts and use a ready/aggregate timeout to avoid reacting to intermediate file churn
- Rust `notify`-based tools: separate per-platform event capture and clustering because Linux inotify, macOS FSEvents, and Windows changes behave very differently

create doc folder

search the internet and gather insights for each tool in separate md documents, that will then be used to improve next steps

## 1.2 statistical mode

Create a separate statistics utility in this repo that collects watcher behavior data and turns file events into analysis-ready reports. The purpose is to improve the watcher through external measurement, not to clutter the main sync tool with extra runtime logic.

Goals:

- Build a dedicated Zig statistics tool separate from the main sync watcher
- Measure actual editor save behavior and event noise per file
- Capture rebuild and large-change burst patterns separately from ordinary saves
- Record merge/rebase/change-set churn to compare against normal editing workloads
- Persist results for later analysis and cross-platform/editor comparison
- Keep the main sync tool clean and focused by implementing statistics externally

What to capture:

- raw watcher event stream with timestamp, path, event kind, and backend metadata
- logical session grouping for editor saves, rebuild bursts, and merge refresh periods
- event counts per file and per logical session
- duplicate/redundant event detection
- event density and burst duration
- editor/platform/FS metadata, watcher backend, and scenario label

Suggested behavior:

- support a CLI flag such as `--stats` or `watch_mode=statistical`
- log raw events to JSONL for auditability
- generate aggregated summaries in JSON/CSV for easy comparison
- use time-based clustering to group related events into one logical save or rebuild session
- preserve a permanent report directory with timestamped filenames

Report format proposal:

- `metadata`
  - editor, editor version, platform, filesystem, watcher backend, tool version
- `scenario`
  - values such as `editor-save`, `rebuild`, `git-merge`, `manual`
- `raw_events`
  - list of timestamped low-level events with path, kind, and group/session id
- `aggregates`
  - files changed, total events, events per file, duplicate event count, burst duration, session duration
- `anomalies`
  - editor-specific noise, merge conflict churn, rebuild spikes, unexpected deletions

Example reusable summary fields:

- `run_id`
- `editor`
- `platform`
- `scenario`
- `files_changed`
- `events_total`
- `avg_events_per_file`
- `burst_duration_ms`
- `duplicate_event_count`
- `session_start`
- `session_end`

Comparison-ready output:

- compare same editor across platforms
- compare different editors on one OS
- compare save-mode vs rebuild vs merge behavior
- compare watcher backend differences for the same project

## 1.3 [future]

- evaluate whether interactive editor save patterns should use editor-specific heuristics or a generic time-clustering model

# 2 robustness

## 2.1

- recognize there are merge conflicts and pause
- recognize when all merge conflicts are resolved and continue

