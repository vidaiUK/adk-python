# Fork Guide — `vidaiUK/adk-python`

This is a maintained fork of [`google/adk-python`](https://github.com/google/adk-python).
It is **stock ADK plus one feature**: environment-variable configuration of the
LLM `base_url`, so endpoints can be redirected (e.g. through a local or
multi-provider proxy) without touching code.

## Why this fork exists

The feature was proposed upstream in
[google/adk-python#5383](https://github.com/google/adk-python/issues/5383) and
**declined**. The maintainers' reasoning: ADK already lets you pass `base_url`
to a model constructor, and they prefer to keep the framework unopinionated
rather than add an environment variable for every configuration option.

That is a reasonable position — for a framework whose primary audience runs
Google's own models. We don't dispute it. But it has a cost, and the cost lands
on the developer:

- **Without env-var support, endpoint configuration lives in code.** Every
  consumer, for every vendor, has to thread `base_url` into model construction
  by hand. There is no single switch.
- **It is per-vendor.** Redirecting Gemini, Anthropic and an OpenAI-compatible
  provider means three separate pieces of wiring, repeated in every project.

This fork takes the other tradeoff. **One variable — `ADK_LLM_BASE_URL` —
configures every provider at once.** Point an entire agent stack at a proxy,
a gateway, or a local endpoint by setting a single environment variable, with
no code changes and no per-vendor boilerplate. Each vendor still has its own
override for the cases that need it (see the table below) — but the *default*
is vendor-independent.

In short: upstream ADK optimizes for Google's models, which is understandable.
This fork optimizes for the multi-vendor developer who wants infrastructure
configuration to live in the environment, not the code. Different priorities,
both legitimate — which is exactly why this is a fork and not an argument.

**File fork-specific issues and PRs here; send general ADK changes upstream.**
See [CONTRIBUTING.md](CONTRIBUTING.md) for routing.

## Installation

Pin the **`stable`** branch. It only ever advances to a commit that has been
auto-synced with upstream **and** passed the test suite — so it auto-updates on
green syncs and is automatically held at the last working version when a sync
fails.

```bash
pip install "git+https://github.com/vidaiUK/adk-python.git@stable"
```

`pyproject.toml`:
```toml
dependencies = [
    "google-adk @ git+https://github.com/vidaiUK/adk-python.git@stable",
]
```

`requirements.txt`:
```
git+https://github.com/vidaiUK/adk-python.git@stable#egg=google-adk
```

The package still imports as `import google.adk` — only the install source
changes. For a frozen, never-moving pin, use a `fork-vX.Y.Z` tag instead of
`@stable`.

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

## How the fork is maintained

### Branches

| Branch            | Role |
|-------------------|------|
| `main`| Integration branch — the base_url patch with upstream **merged in**. |
| `stable`          | What consumers pin. Only ever advances to a green `main`. |

There is no `upstream` remote in the repo; the automation adds it on the fly.
The patch is carried by **merging upstream in** (not rebasing) so history is
never rewritten and `@stable` pins never shift unexpectedly.

### Automated daily sync

[`.github/workflows/auto-sync.yml`](.github/workflows/auto-sync.yml) runs daily
at 06:00 UTC (and on demand via *Actions → auto-sync-upstream → Run workflow*).
Daily keeps each merge small, so conflicts stay rare and trivial:

1. Merge `upstream/main` into `main`.
2. **Merge conflicts** → stop, open an `auto-sync` issue, leave `stable` as-is.
3. Clean merge → install and run the model test suite.
4. **Tests pass** → push `main` and fast-forward `stable` to it.
   This is the new baseline; `@stable` consumers pick it up automatically.
5. **Tests fail** → stop, open an `auto-sync` issue, leave `stable` as-is.

So a sync only ever becomes the consumer-facing baseline if it is green. A
failed sync holds every consumer at the last working version and surfaces an
issue (and a red badge in the README) describing what needs manual review.

### Recovering from a failed sync

When the `auto-sync` issue appears:

```bash
./scripts/update-fork.sh        # merges upstream, runs tests locally
# resolve the conflict / fix the failing test, then:
git push origin main
git push origin main:stable   # fast-forward stable once green
```

Optionally snapshot a release: `git tag -a fork-vX.Y.Z -m "..." && git push origin fork-vX.Y.Z`.

### CI

[`.github/workflows/fork-ci.yml`](.github/workflows/fork-ci.yml) additionally
runs the model tests on every **code** push to `main`, so manual pushes are
checked too. Doc-only changes (`*.md`, `LICENSE`, `docs/`, …) skip the suite —
they cannot affect tests.
