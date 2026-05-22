# Fork Guide — `vidaiUK/adk-python`

This is a maintained fork of [`google/adk-python`](https://github.com/google/adk-python).
It is **stock ADK plus one feature**: environment-variable configuration of the
LLM `base_url`, so endpoints can be redirected (e.g. through a local or
multi-provider proxy) without touching code.

## Why a fork?

The feature was proposed upstream in
[google/adk-python#5383](https://github.com/google/adk-python/issues/5383) and
**declined** — the maintainers prefer to keep the framework minimal and consider
passing `base_url` to the model constructor sufficient. This fork is therefore
the permanent home for the change. **File issues and PRs against this repo, not
upstream.**

## Installation

Pin a **tag**, never the branch — the `feature/base-url` branch is rebased onto
upstream and its history is rewritten on every sync.

```bash
pip install "git+https://github.com/vidaiUK/adk-python.git@fork-v2.0.0"
```

`pyproject.toml`:
```toml
dependencies = [
    "google-adk @ git+https://github.com/vidaiUK/adk-python.git@fork-v2.0.0",
]
```

`requirements.txt`:
```
git+https://github.com/vidaiUK/adk-python.git@fork-v2.0.0#egg=google-adk
```

The package still imports as `import google.adk` — only the install source changes.

## What the feature does

Each model class resolves `base_url` from environment variables when no explicit
`base_url` is passed to the constructor. **An explicit constructor argument always
wins over environment variables.**

| Model class            | Environment variables, in resolution order |
|------------------------|--------------------------------------------|
| `BaseLlm` (all models) | `ADK_LLM_BASE_URL` |
| `Gemini`               | `ADK_GEMINI_BASE_URL` → `ADK_VERTEX_BASE_URL` → `ADK_LLM_BASE_URL` |
| `Anthropic` / `Claude` | `ANTHROPIC_BASE_URL` → `ADK_LLM_BASE_URL` |
| `LiteLlm`              | `LITELLM_API_BASE` → `OPENAI_API_BASE` → `OPENAI_BASE_URL` → `ADK_LLM_BASE_URL` |

Notes:
- `ADK_LLM_BASE_URL` is the framework-wide default — set it once to route every
  provider through a single multi-provider proxy.
- Provider-native vars (`ANTHROPIC_BASE_URL`, `OPENAI_API_BASE`, …) are honored
  verbatim, because those SDKs read them natively and users setting them are
  assumed to include any required path.
- For `LiteLlm`, a value inherited from `ADK_LLM_BASE_URL` gets `/v1` appended
  automatically if it lacks a version path (LiteLLM's OpenAI-compatible transport
  requires it). Gemini and Anthropic use the root unchanged.

### Example

```bash
export ADK_LLM_BASE_URL="https://my-proxy.internal"
```
```python
from google.adk.models.google_llm import Gemini
from google.adk.agents import Agent

# base_url is picked up from ADK_LLM_BASE_URL automatically
agent = Agent(model=Gemini(model="gemini-2.5-flash"))
```

## Maintaining the fork

| Remote     | Points at                          | Role                     |
|------------|-------------------------------------|--------------------------|
| `upstream` | `google/adk-python`                 | Read-only. Never commit. |
| `origin`   | `vidaiUK/adk-python`                | The fork.                |

- `main` — pristine fast-forward-only mirror of `upstream/main`.
- `feature/base-url` — the single feature commit, rebased onto `upstream/main`.

### Sync routine

Run periodically (weekly, or when a wanted ADK release lands):

```bash
./scripts/update-fork.sh   # ff main, rebase feature/base-url, run model tests
git push --force-with-lease origin feature/base-url
git tag -a fork-vX.Y.Z -m "ADK vX.Y.Z + base_url env vars"
git push origin fork-vX.Y.Z
```

Tag names mirror the upstream version the fork is based on.

### CI

[`.github/workflows/fork-ci.yml`](.github/workflows/fork-ci.yml) runs the model
test suite on every push to `feature/base-url` and weekly via cron. **A red
weekly build means upstream drifted — time to rebase.** Rebasing is intentionally
manual: a rebase can raise merge conflicts that need a human decision, and
passing tests do not by themselves prove a rebase preserved the feature.
