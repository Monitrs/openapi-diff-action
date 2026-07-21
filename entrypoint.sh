#!/usr/bin/env bash
#
# monit.rs OpenAPI diff — composite action entrypoint.
#
# Diffs the OpenAPI spec at INPUT_SPEC (PR head) against the same path on
# the base branch, using the public monit.rs diff engine. Emits GitHub
# Actions outputs, optionally posts a PR comment, optionally fails the
# check on any breaking change.
#
# Called by action.yml. Not intended to be run standalone.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Inputs (all populated via env by action.yml)
# ---------------------------------------------------------------------------
SPEC_PATH="${INPUT_SPEC:?INPUT_SPEC is required}"
BASE_SPEC_PATH="${INPUT_BASE_SPEC:-$SPEC_PATH}"
FAIL_ON_BREAKING="${INPUT_FAIL_ON_BREAKING:-true}"
POST_COMMENT="${INPUT_COMMENT:-true}"
API_URL="${INPUT_API_URL:-https://monit.rs}"

# GitHub-provided context — populated by the composite action runner.
GH_EVENT_PATH="${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH is required (this action must run on pull_request events)}"
GH_REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

# ---------------------------------------------------------------------------
# Extract the PR / base-ref from the event payload
# ---------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
    echo "::error::jq is required but missing on this runner. Add 'sudo apt-get install -y jq' to your job's steps before this action." >&2
    exit 1
fi

BASE_REF="$(jq -r '.pull_request.base.ref // empty' "$GH_EVENT_PATH")"
PR_NUMBER="$(jq -r '.pull_request.number // empty' "$GH_EVENT_PATH")"
if [ -z "$BASE_REF" ]; then
    echo "::error::This action must run on a pull_request event (base.ref not found in event payload)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Read both spec versions from git
# ---------------------------------------------------------------------------
if [ ! -f "$SPEC_PATH" ]; then
    echo "::error file=${SPEC_PATH}::Spec not found in the PR head. Check the 'spec' input." >&2
    exit 1
fi

# The base spec might not exist yet if this PR adds the spec for the first
# time. Fall back to an empty spec so the diff shows every path as new.
BASE_SPEC_CONTENT="$(git show "origin/${BASE_REF}:${BASE_SPEC_PATH}" 2>/dev/null || echo '')"
if [ -z "$BASE_SPEC_CONTENT" ]; then
    echo "::warning::Base spec at ${BASE_SPEC_PATH} on ${BASE_REF} is empty or missing — treating as a fresh addition." >&2
    BASE_SPEC_CONTENT='{"openapi":"3.0.0","info":{"title":"empty","version":"0"},"paths":{}}'
fi

NEW_SPEC_CONTENT="$(cat "$SPEC_PATH")"

# ---------------------------------------------------------------------------
# Call the monit.rs diff engine
# ---------------------------------------------------------------------------
REQUEST_JSON="$(jq -n \
    --arg old "$BASE_SPEC_CONTENT" \
    --arg new "$NEW_SPEC_CONTENT" \
    '{old_spec: $old, new_spec: $new}')"

HTTP_TMP="$(mktemp)"
HTTP_STATUS="$(curl -sS -o "$HTTP_TMP" -w '%{http_code}' \
    -X POST "${API_URL}/api/v1/tools/openapi-diff" \
    -H 'Content-Type: application/json' \
    -H "User-Agent: monit.rs-openapi-diff-action/1.0 (+https://monit.rs)" \
    -d "$REQUEST_JSON")"

if [ "$HTTP_STATUS" != "200" ]; then
    echo "::error::monit.rs diff API returned HTTP ${HTTP_STATUS}" >&2
    cat "$HTTP_TMP" >&2
    rm -f "$HTTP_TMP"
    exit 1
fi

RESPONSE="$(cat "$HTTP_TMP")"
rm -f "$HTTP_TMP"

BREAKING="$(echo "$RESPONSE" | jq -r '.summary.breaking // 0')"
NON_BREAKING="$(echo "$RESPONSE" | jq -r '.summary.non_breaking // 0')"
INFO="$(echo "$RESPONSE" | jq -r '.summary.info // 0')"

# Emit Actions outputs (each shell step gets its own $GITHUB_OUTPUT file).
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "breaking=${BREAKING}"
        echo "non_breaking=${NON_BREAKING}"
        echo "info=${INFO}"
    } >> "$GITHUB_OUTPUT"
fi

# ---------------------------------------------------------------------------
# Compose the PR comment / Actions summary body
# ---------------------------------------------------------------------------
render_comment() {
    local body_file
    body_file="$(mktemp)"

    # Header + high-level counts.
    {
        echo "### 🔍 OpenAPI diff — \`${SPEC_PATH}\`"
        echo
        if [ "$BREAKING" -eq 0 ] && [ "$NON_BREAKING" -eq 0 ] && [ "$INFO" -eq 0 ]; then
            echo "**No differences detected** against \`${BASE_REF}\`."
        else
            echo "| Severity | Count |"
            echo "| --- | ---: |"
            echo "| 🔴 Breaking | ${BREAKING} |"
            echo "| 🟡 Non-breaking | ${NON_BREAKING} |"
            echo "| 🔵 Info | ${INFO} |"
        fi
        echo

        # First 20 changes, ordered by severity: breaking → non_breaking → info.
        # 20 is a readable ceiling for PR comments; more than that and the
        # reader clicks through to the full report.
        local count
        count="$(echo "$RESPONSE" | jq '.changes | length')"
        if [ "$count" -gt 0 ]; then
            echo "<details><summary>Full change list ($count changes)</summary>"
            echo
            echo "| Severity | Path | Change |"
            echo "| --- | --- | --- |"
            echo "$RESPONSE" | jq -r '
                .changes
                | sort_by(if .severity=="breaking" then 0 elif .severity=="non_breaking" then 1 else 2 end)
                | .[:20]
                | .[] | "| " + (
                    if .severity=="breaking" then "🔴 Breaking"
                    elif .severity=="non_breaking" then "🟡 Non-breaking"
                    else "🔵 Info" end
                ) + " | `" + (.path // "") + "` | " + (.message // "") + " |"
            '
            if [ "$count" -gt 20 ]; then
                echo
                echo "_…and $((count - 20)) more._"
            fi
            echo
            echo "</details>"
        fi

        echo
        echo "---"
        echo "Powered by [monit.rs](https://monit.rs) · [Get alerted when your live API drifts →](https://monit.rs/login?utm_source=github_action&utm_medium=pr_comment&utm_campaign=diff)"
    } > "$body_file"

    echo "$body_file"
}

COMMENT_BODY_FILE="$(render_comment)"

# Attach the same rendering to the run summary (visible on the Action run
# page) even if commenting is off.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat "$COMMENT_BODY_FILE" >> "$GITHUB_STEP_SUMMARY"
fi

# ---------------------------------------------------------------------------
# Post the PR comment via gh
# ---------------------------------------------------------------------------
if [ "$POST_COMMENT" = "true" ] && [ -n "$PR_NUMBER" ]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "::warning::gh CLI not found on runner — skipping PR comment. (ubuntu-latest / macos-latest include gh by default; if you're on a custom image, install it.)" >&2
    else
        gh pr comment "$PR_NUMBER" --repo "$GH_REPO" --body-file "$COMMENT_BODY_FILE" \
            || echo "::warning::Failed to post PR comment (permissions? Check the workflow's permissions: pull-requests: write)"
    fi
fi

rm -f "$COMMENT_BODY_FILE"

# ---------------------------------------------------------------------------
# Fail the check on breaking changes (default behavior)
# ---------------------------------------------------------------------------
if [ "$FAIL_ON_BREAKING" = "true" ] && [ "$BREAKING" -gt 0 ]; then
    echo "::error::${BREAKING} breaking change(s) detected. Set 'fail-on-breaking: false' to only report." >&2
    exit 1
fi

echo "OpenAPI diff complete: ${BREAKING} breaking, ${NON_BREAKING} non-breaking, ${INFO} info."
