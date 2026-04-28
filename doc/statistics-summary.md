# Statistics Tool Summary

This summary document collects the main conclusions and next steps for the separate statistics utility.

## Purpose

- Build a separate Zig statistics tool that collects filesystem watch behavior and produces reusable reports.
- Use the statistics tool to improve the main project watcher, without adding complexity to the primary sync binary.
- Focus on observation and analysis, not on changing sync behavior at runtime.

## Core objectives

- Measure editor save behavior across platforms and editors.
- Capture rebuild and large-change patterns separately from simple saves.
- Detect merge/gitrebase churn and compare it against normal editing sequences.
- Persist raw and aggregated data for later comparison.
- Provide a reusable report format for cross-platform/editor analysis.

## What to collect

- Raw watcher event stream:
  - timestamp
  - path
  - event kind
  - backend metadata
  - watcher source (inotify, FSEvents, ReadDirectoryChangesW)
- Logical session groupings:
  - editor-save
  - rebuild
  - git-merge
  - manual change
- Aggregated metrics:
  - total events
  - files changed
  - events per file
  - duplicate/redundant events
  - burst duration
  - event density
- Context metadata:
  - editor name/version
  - platform/OS
  - filesystem type
  - watcher backend
  - tool version
  - strategy / use case label

## Run strategy and use-case labeling

The statistics tool should allow the user to specify the purpose of each run, so results are grouped by intent and can be compared cleanly across editors and systems. Example run strategy values:

- `editor-save` — editing and saving files one by one to measure save noise
- `merge` — watching source during a git merge or rebasing workflow
- `build` — watching a build tool such as Java, Maven, Bun, tsc, Eclipse, etc.
- `clean-build` — observing a clean build that deletes outputs before writing new files

This should be used to organize outputs into separate folders or datasets by strategy, making same-use-case comparisons easy to analyze.

## Report format

Use a structured format that includes:

- `metadata`
- `scenario`
- `raw_events`
- `aggregates`
- `anomalies`

Example summary fields:

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

## Why this matters

- Platform inconsistencies make raw event counts unreliable.
- Editor atomic writes produce event sequences that must be interpreted, not simply counted.
- Collecting data externally makes the watcher easier to tune without changing its runtime behavior.

## Next steps

- Implement a dedicated statistics tool under this repo in its own source path.
- Build the tool to capture raw events and generate JSON/CSV summary reports.
- Use the reports to identify platform-specific watcher behavior and optimize the main sync watcher.
- Keep the statistics tool separate so it can be used for analysis without adding watcher complexity to the sync executable.
