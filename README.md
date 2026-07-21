# monit.rs OpenAPI diff — GitHub Action

Detect **breaking changes in your OpenAPI spec** on every pull request. Posts a summary comment with the diff, powered by the same schema-aware diff engine that runs at [monit.rs](https://monit.rs).

- ⚡ **Fast** — composite action, no `node_modules`, no docker pull
- 🎯 **Focused** — classifies every change as `breaking`, `non-breaking`, or `info`
- 💬 **Automatic PR comment** — reviewers see the impact without leaving GitHub
- 🚫 **Fails the check on breaking changes** by default (configurable)

---

## Quick start

Add `.github/workflows/openapi-diff.yml` to any repo that ships an OpenAPI spec:

```yaml
name: OpenAPI diff
on:
  pull_request:
    paths:
      - 'openapi.yaml'    # or wherever your spec lives
      - 'openapi.json'

jobs:
  diff:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write   # required to post the comment
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0     # so we can `git show origin/<base>:...`
      - uses: Monitrs/openapi-diff-action@v1
        with:
          spec: openapi.yaml
```

That's the whole thing. The next PR touching `openapi.yaml` will get an inline diff summary comment, and the check will fail if any breaking change is detected.

---

## Inputs

| Name | Required | Default | Description |
| --- | :-: | --- | --- |
| `spec` | ✅ | — | Path to the OpenAPI spec (JSON or YAML) in the PR head. |
| `base-spec` |  | same as `spec` | Path to the spec on the base branch (for when the spec moved between branches). |
| `fail-on-breaking` |  | `true` | Fail the check when any breaking change is detected. Set to `false` to only report. |
| `comment` |  | `true` | Post the diff summary as a PR comment. |
| `api-url` |  | `https://monit.rs` | Override the diff API. Only needed for self-hosted or staging. |

## Outputs

| Name | Description |
| --- | --- |
| `breaking` | Number of breaking changes detected |
| `non-breaking` | Number of non-breaking changes detected |
| `info` | Number of info-level changes detected |

Wire outputs into follow-up steps:

```yaml
      - id: diff
        uses: Monitrs/openapi-diff-action@v1
        with:
          spec: openapi.yaml
          fail-on-breaking: false
      - if: steps.diff.outputs.breaking > 0
        run: echo "PR contains ${{ steps.diff.outputs.breaking }} breaking change(s)"
```

## What counts as a breaking change?

The diff engine walks both specs and flags:

- Endpoint removed
- Required parameter added
- Response status code removed
- Response field removed
- Response field type changed (string → integer, etc.)
- Response field required-list expanded
- Request body schema tightened (added `required`, changed type)

Non-breaking includes: new endpoint, new optional parameter, new response field, added tags/descriptions. Info includes: OpenAPI version bump, `info` block changes, description-only edits.

See the [full source](https://github.com/Monitrs/openapi-diff-action) — small enough to read end-to-end.

---

## Why this Action exists

The engineering team ships a spec change. It looks harmless in code review — one property added, one renamed. Turns out the rename broke every mobile-app version below 4.2 and a PagerDuty alert fires at 3am.

This action catches those in the PR window instead of at 3am.

That's also what [monit.rs](https://monit.rs) does for your **live** APIs, every 30 seconds — against real traffic, not just the spec. The diff engine is shared: what runs here in your CI runs against production baselines there. [Free tier includes 3 monitored endpoints, no card required.](https://monit.rs/login?utm_source=github_action_readme&utm_medium=readme&utm_campaign=cta)

## License

MIT. See [../../LICENSE](../../LICENSE) in the parent repo. Not affiliated with any listed API vendor.
