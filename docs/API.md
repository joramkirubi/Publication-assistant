# Interface Specification

This project has no REST API -- its "interface" is (1) the shared state
schema that flows through the graph, and (2) the two front ends (CLI and
Streamlit UI) built on top of it. Both front ends call the exact same
`src/graph.py` functions, so this doc is the single source of truth for
either.

## Programmatic interface: `src/graph.py`

```python
from src.graph import start_pipeline, resume_pipeline, run_pipeline
```

### `start_pipeline(repo_url: str, user_description: str | None = None) -> (app, config, paused_state)`

Validates and sanitizes input (via `src/guardrails.py`), then runs the
pipeline up to the human-in-the-loop checkpoint (paused right before
`Reviewer/Critic`).

- **Raises:** `GuardrailViolation` (a `ValueError` subclass) if `repo_url`
  isn't a valid `https://github.com/<owner>/<repo>` URL.
- **Returns:**
  - `app`: the compiled LangGraph app (needed to resume).
  - `config`: dict carrying the `thread_id` the checkpointer uses; pass
    back unchanged to `resume_pipeline`.
  - `paused_state`: a dict view of `PublicationAssistantState` (see
    schema below) as of the pause point.

### `resume_pipeline(app, config, edits: dict | None = None) -> PublicationAssistantState`

Applies any human edits to state, then runs `Reviewer/Critic` to
completion.

- `edits` may set any of: `suggested_title`, `suggested_summary`,
  `suggested_tags`, `human_feedback`, `human_approved`.
- **Returns:** the final state dict, including `final_report` (markdown
  string, already passed through `filter_output` for secret redaction).

### `run_pipeline(repo_url, user_description=None) -> PublicationAssistantState`

Convenience wrapper: runs the full pipeline with `human_approved=True`
and no edits (auto-approve). Used by tests and non-interactive callers.

## State schema (`src/state.py`)

`PublicationAssistantState` is a `TypedDict(total=False)`:

| Field | Type | Populated by | Notes |
|---|---|---|---|
| `repo_url` | `str` | input | Validated/normalized by `guardrails.validate_repo_url`. |
| `user_description` | `str` | input | Sanitized by `guardrails.sanitize_user_description`. |
| `owner`, `repo` | `str` | Repo Analyzer | Parsed from the URL. |
| `readme_text` | `str` | Repo Analyzer | Truncated to `settings.max_readme_chars` (12,000). |
| `file_structure` | `list[str]` | Repo Analyzer | Top-level entries, dirs suffixed `/`. |
| `repo_metadata` | `dict` | Repo Analyzer | `description`, `stars`, `language`, `topics`, `license`, `open_issues`. |
| `suggested_keywords` | `list[str]` | Metadata Recommender | Raw ranked candidates before LLM refinement. |
| `suggested_tags` | `list[str]` | Metadata Recommender | Final 5-8 tags. |
| `suggested_title`, `suggested_summary`, `positioning_notes` | `str` | Content Improver | |
| `structure_report` | `dict` | Reviewer/Critic | `essential`/`professional` section presence + `missing_*` lists. |
| `review_notes` | `list[str]` | Reviewer/Critic | Human-readable bullet notes. |
| `final_report` | `str` | Reviewer/Critic | The markdown deliverable. |
| `human_approved` | `bool` | human review checkpoint | |
| `human_feedback` | `str` | human review checkpoint | |
| `errors` | `list[str]` (`operator.add` reducer) | any agent | Concatenated, not overwritten, across concurrent writers. |

## CLI interface (`main.py`)

```
python main.py --repo <url> [--description TEXT] [--output PATH]
               [--no-save] [--auto-approve] [--health-check]
```

| Flag | Required | Effect |
|---|---|---|
| `--repo` | yes, unless `--health-check` | GitHub repo URL. |
| `--description` | no | Optional context passed to the agents. |
| `--output` | no | Custom report path (default: auto-generated under `reports/`). |
| `--no-save` | no | Print only, skip writing to disk. |
| `--auto-approve` | no | Skip the interactive review prompt. |
| `--health-check` | no | Run config/connectivity checks and exit (no pipeline run). |

Exit codes: `0` success, `1` invalid input or unexpected pipeline
failure.

## UI interface (`app.py`)

`streamlit run app.py` exposes the same three stages as three screens:
input form -> human review form -> final report + download button. See
[DEPLOYMENT.md](DEPLOYMENT.md) for how to run it.