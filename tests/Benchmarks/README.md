# Benchmarks

This folder contains a reusable benchmark harness for comparing Silmaril with Playwright on public sites.

## What It Measures

- cold runs: browser startup plus task execution
- warm runs: task execution after the browser is already available
- success rate
- median and p95 wall-clock duration
- per-step timing and failure details

The harness does not measure token usage.

## Task Set

- micro tasks
  - open Wikipedia home
  - query the Wikipedia search form
  - type into the Wikipedia search form
  - click through to English Wikipedia
  - wait for async content on `the-internet`
- flow tasks
  - the-internet login
  - dynamic controls
  - dynamic loading
  - Wikipedia search

Shared task definitions live in `tasks.json`.

## Run

Run the full benchmark:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Benchmarks\Run-Benchmarks.ps1
```

Run a focused smoke benchmark:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Benchmarks\Run-Benchmarks.ps1 `
  -TaskId micro_open_wikipedia_home,flow_wikipedia_search `
  -ColdRuns 1 `
  -WarmMicroRuns 1 `
  -WarmFlowRuns 1
```

Limit to one tool:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Benchmarks\Run-Benchmarks.ps1 -Tool silmaril
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Benchmarks\Run-Benchmarks.ps1 -Tool playwright
```

## Output

Each run writes a result directory under `tests/Benchmarks/results/` containing:

- `raw-results.json`
- `summary.json`
- `summary.md`

`summary.md` is the easiest human-readable report. `raw-results.json` is the source of truth for deeper analysis.

## Notes

- Playwright is resolved from the user-level Node installation in the current environment.
- The benchmark uses the same local Chrome/Edge executable for both tools.
- The default benchmark runs headless for lower noise and easier cleanup.
