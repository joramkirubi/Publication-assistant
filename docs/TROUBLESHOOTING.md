# Troubleshooting & FAQ

## First step for any issue

```powershell
python main.py --health-check
```

This distinguishes "my config is wrong" from "something is actually
broken" in a few seconds, without spending LLM tokens.

## Common issues

### `EnvironmentError: GROQ_API_KEY is not set.`

`.env` is missing or wasn't loaded. Confirm `.env` exists (copied from
`.env.example`) in the same directory you're running `python main.py`
from, and that `GROQ_API_KEY=...` has an actual value, not a blank line.

### `GuardrailViolation: Repo URL must look like https://github.com/<owner>/<repo>`

The tool only accepts plain public GitHub repo URLs -- no GitLab, no
private-repo URLs with embedded tokens, no extra path segments (e.g.
`/tree/main`), no `http://` (must be `https://`). Strip the URL down to
`https://github.com/owner/repo` and retry.

### `RepoAnalyzer: failed to fetch repo -- ...` (in the report's warnings)

Usually one of:
- **404 from GitHub** -- the repo is private, misspelled, or deleted.
- **403 / rate limited** -- you've hit the unauthenticated 60 req/hr
  GitHub API limit. Set `GITHUB_TOKEN` in `.env` to raise it to 5000/hr.
- **Connection error** -- transient network issue. The tool already
  retries transient failures automatically (see
  [ARCHITECTURE.md](ARCHITECTURE.md#design-decisions)); if it still fails
  after retries, check your network connection or run `--health-check`.

### `ContentImprover: skipped, no README text available.` / similar "skipped" messages

Content Improver and Metadata Recommender both require README text to
work with. If Repo Analyzer failed (see above), everything downstream
degrades gracefully with an explanatory error in `state["errors"]` and
in the final report's warnings, rather than crashing.

### The pipeline seems to hang

Every outbound call (GitHub API, Tavily, Groq LLM calls) has a hard
timeout (`src/resilience.py`'s `with_timeout`), so no single call should
hang forever. If the whole CLI process appears stuck, it's most likely
waiting on your input at the human review checkpoint (`Approve as-is?
[Y/n/e=edit]:`) -- check for that prompt, or pass `--auto-approve` for
non-interactive use.

### `InvalidUpdateError: Ambiguous update, specify as_node`

This was a real bug hit during development (documented in the main
[README](../README.md#human-in-the-loop-review)) and is already fixed in
`src/graph.py` (`resume_pipeline` passes `as_node="content_improver"`
explicitly). If you see this again after modifying `src/graph.py`, you
likely removed that argument -- restore it.

### `GitHub API: unreachable (... getaddrinfo failed ...)` in `--health-check`

This is a DNS resolution failure on your machine, not an application bug
-- Python couldn't resolve `api.github.com` to an IP address. Common
causes and fixes:

- **VPN or corporate/school network** blocking or rerouting DNS. Try
  disconnecting the VPN, or check with your network admin.
- **A misconfigured or unreachable DNS server.** Test with:
  ```powershell
  Resolve-DnsName api.github.com
  ```
  If that also fails, try switching your DNS (e.g. to `8.8.8.8` in your
  network adapter settings) or check whether other sites resolve at all.
- **A flaky Wi-Fi/network connection** -- retry the health check; the
  underlying GitHub calls the pipeline makes already retry transient
  failures automatically (see [ARCHITECTURE.md](ARCHITECTURE.md)), but
  a `--health-check` DNS failure itself isn't retried since it's meant to
  fail fast and tell you immediately.
- **Antivirus/firewall software** intercepting HTTPS connections. Check
  if temporarily disabling it changes the result (then re-enable it).

If `GROQ_API_KEY` shows `[OK]` but GitHub shows `[FAIL]` for this reason,
the pipeline itself will likely still fail on `RepoAnalyzer` for the same
DNS reason -- fix connectivity first before running a real analysis.

### Console or web UI shows garbled/mangled characters instead of normal text or symbols

This is a text encoding mismatch, and it has two possible sources:

1. **PowerShell's console code page.** If you see stray multi-character
   sequences where a single symbol should be, your console's active code
   page doesn't match UTF-8. Every piece of CLI-facing output in this
   project (`main.py`, `src/health.py`) is plain ASCII specifically to
   avoid this, so seeing it there means you're on an outdated copy --
   re-apply the latest setup/patch script. You can also force UTF-8 for
   the current session with:
   ```powershell
   [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
   ```

2. **A setup/patch `.ps1` script read in the wrong encoding.** Windows
   PowerShell 5.1 reads a `.ps1` file without a UTF-8 byte-order-mark
   using your system's legacy code page (often Windows-1252), not UTF-8.
   If a script embeds a non-ASCII character (an em dash, a curly quote,
   an emoji) inside a here-string, PowerShell can misread those bytes
   *while parsing the script itself* -- so the corrupted text gets baked
   into the `.py`/`.md` file it writes, and shows up everywhere that file
   is read afterward (console, browser, editor -- all of them, since the
   file's actual bytes are now wrong, not just how one tool displays
   them). This is why every source file in this project deliberately
   avoids em dashes, curly quotes, and emoji in favor of plain ASCII
   (`--`, straight quotes, `[OK]`/`[WARNING]` instead of symbols) -- it
   removes the failure mode entirely rather than relying on remembering
   to set an encoding flag.

   If you re-apply a patch script and still see corruption afterward,
   confirm the `.ps1` file itself was saved as UTF-8 (with or without
   BOM) before running it, or run it via PowerShell 7+ (`pwsh`), which
   defaults to UTF-8 and doesn't have this legacy behavior.


The error detail shown in the UI is the same exception message the CLI
would print. Cross-check against `--health-check` and the issues above;
the underlying pipeline is identical between the CLI and the UI.

### Tests fail with `ModuleNotFoundError`

Run `pip install -r requirements.txt` inside the same virtual environment
you're running `pytest` from -- a common mismatch is having a global
`python` on `PATH` different from the one in `.venv`.

## FAQ

**Q: Does this work with private repos?**
A: Only if you set `GITHUB_TOKEN` to a personal access token with access
to that repo. Support is best-effort; the tool is designed and tested
against public repos.

**Q: What happens if I don't set `TAVILY_API_KEY`?**
A: Content Improver still runs, drafting the title/summary from the
README alone, without external positioning context. This is a graceful
degradation, not a failure.

**Q: Can I use a different LLM provider?**
A: Not without code changes -- `src/llm.py` is Groq-specific
(`ChatGroq`). It's the single place to change if you want to swap
providers; every agent already goes through `get_llm()` / `invoke_llm()`.

**Q: Why does the final report sometimes redact things that look like
API keys?**
A: `src/guardrails.py`'s `filter_output` runs a last-resort regex
redaction pass on every final report, in case a README or web search
result the LLM was shown happened to contain something that looks like a
credential. This is a safety net, not a sign your own keys leaked.

**Q: How do I know test coverage is adequate?**
A: `pytest tests/ --cov=src --cov-report=term-missing` -- the project
targets and currently exceeds 70% statement coverage on `src/`.