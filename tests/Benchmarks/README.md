# Benchmarks

This folder now holds the real-site comparative benchmark for Silmaril versus Playwright.

The old narrow benchmark only measured timing and pass or fail on a tiny site set. The current program is wider and explicitly product-facing:

- public, unauthenticated sites only
- repeated on the same tasks for both tools
- scored on completion and operator UX proxies
- grouped by site pattern, not by low-level command
- structured to surface Silmaril backlog items from observed friction

## Scope

Current site groups:

- `search_navigation`
- `content_heavy`
- `form_flows`
- `spa_public_apps`
- `feed_surfaces`
- `modal_menu_heavy`
- `custom_rendered`
- `multi_tab_reference`

The task matrix intentionally uses real sites that were reachable and automatable in the current environment:

- Wikipedia
- Python.org
- Python docs
- GitHub search
- MDN
- React docs
- Vite docs
- Astro docs
- Next.js docs
- Behance
- Dribbble
- Flickr
- Lichess
- OpenStreetMap
- Desmos

## What Gets Scored

Every run records:

- completion status: `clean_success`, `success_with_escalation`, `partial`, or `fail`
- wall-clock time
- command count
- context refresh count
- maximum escalation depth
- raw command transcript
- per-step timing and failure details
- automatic friction signals
- manual scoring placeholders for tool clarity, recovery quality, and operator notes

The benchmark does not attempt to estimate token usage.

## Escalation Ladder

The harness uses a fixed escalation ladder declared in `tasks.json`:

1. `documented`
2. `snapshot_ref`
3. `selector_debug`
4. `dom_inspection`
5. `raw_js`
6. `visual_fallback`

This matters for two reasons:

- run status distinguishes clean success from success that required escalation
- the final summary can rank Silmaril friction buckets by how often tasks needed deeper surfaces

## Key Design Choice

The suite supports tool-specific task plans.

That is intentional. A fair benchmark should let:

- Silmaril use snapshot and ref workflows where that is the natural path
- Playwright use visible-aware locator workflows where that is the natural path

Forcing both tools through a single selector-only script would bias the suite toward Playwright-style operation and would under-test Silmaril's snapshot and target-selection UX.

## Task Schema

Task definitions live in `tasks.json`.

Each task declares:

- `id`
- `group`
- `site`
- `startingUrl`
- `successCondition`
- `expectedPrimaryInteractionPattern`
- `allowedToolSurface`
- `fallbackEscalationBoundary`
- `stopCondition`
- `commandBudget`
- `timeBudgetMs`
- `silmarilImprovementBuckets`
- optional `docsVsRealityNote`
- optional `silmarilStrengthHypothesis`
- either shared `steps` or per-tool `profiles`

Supported benchmark step types:

- `navigate`
- `switchTarget`
- `waitFor`
- `waitForAny`
- `waitForGone`
- `waitForCount`
- `waitForVisibleCount`
- `waitUntilJs`
- `query`
- `getText`
- `type`
- `click`
- `scroll`
- `assertUrlIncludes`
- `snapshot` for Silmaril-only plans
- `snapshotFindRef` for Silmaril-only plans

For `query` steps, the benchmark schema also supports:

- `visibleOnly` to score visible-content extraction instead of raw DOM count
- `minCount` to require enough rows before continuing
- `root` to scope extraction to a content container when global shell links would otherwise pollute the result

## Result Schema

Each run row in `raw-results.json` includes:

- task metadata copied from the manifest
- tool and mode
- success status and timings
- `commandCount`
- `contextRefreshCount`
- `maxEscalationDepth`
- `distinctSurfaces`
- `escalationTrace`
- `steps`
- `transcript`
- `variables`
- `analysis.why`
- manual annotation placeholders under `analysis`

That gives another engineer enough information to:

- rerun the exact task
- score the same task with the same success criteria
- see the first point where the workflow stopped being clean

## Running The Suite

Run the full benchmark:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Benchmarks\Run-Benchmarks.ps1
```

Run a single group:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Benchmarks\Run-Benchmarks.ps1 `
  -Group spa_public_apps `
  -ColdRuns 1 `
  -WarmRuns 1
```

Run a focused smoke subset:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Benchmarks\Run-Benchmarks.ps1 `
  -TaskId form_wikipedia_main_search,spa_react_use_state_to_use_effect,menu_next_directory_select `
  -ColdRuns 1 `
  -WarmRuns 0
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

`summary.md` is the human-facing comparison report.

`summary.json` is the structured comparison output for downstream analysis.

`raw-results.json` is the source of truth and includes the raw per-run transcripts plus annotation placeholders.

## Report Intent

The summary is built to answer product questions, not just benchmark questions.

It highlights:

- tasks where both tools succeed but Silmaril feels worse
- tasks where Silmaril succeeds only after deeper escalation
- tasks where Silmaril's target or runtime model is an advantage
- docs-versus-real mismatches where the practical workflow differs from the obvious documented path
- a ranked Silmaril backlog from observed friction buckets

## Notes

- Playwright is resolved from the user-level Node installation in the current environment.
- Both tools use the same local Chrome or Edge executable.
- Headless remains the default to reduce UI noise.
- The current "warm" mode still means startup-separated task timing, not persistent-session reuse across tasks.
