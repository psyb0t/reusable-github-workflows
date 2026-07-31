# Changelog

All notable changes per release. Versions follow [semver](https://semver.org)
pre-1.0 conventions: minor bumps may include breaking input/behavior changes
(called out explicitly), patch bumps are docs / build / fixes only.

## v0.32.1 — 2026-07-31

- **`python-package-workflow.yml`: upgrade `pip` and `setuptools` before
  auditing.** `pip-audit` audits the whole environment, not just the project's
  dependencies — including the `setuptools` the runner image shipped with, which
  lags far enough behind to carry its own advisories (observed: `setuptools`
  65.5.0 flagged with a fix in 83.0.0, on a repo that never declared it).
  Upgrading first keeps the report about the project's own dependency tree
  instead of the runner's ambient one, which nobody can fix from a caller repo
  and which would otherwise fail every Python repo at once for the same reason.

## v0.32.0 — 2026-07-31

Backoff retries on the network operations across every workflow, and a
correction to how `archive.yml` reports failure.

- **`git-mirror.yml`** had 28 network operations and no retry at all — the most
  exposed workflow in the set. The bare clone and the force push now retry with
  exponential backoff on all three targets, via new `max_attempts` (default 3)
  and `backoff_seconds` (default 10) inputs. Losing an entire mirror to one
  registry blip was pure waste.
- **`go-workflow.yml`** retries the `govulncheck` install. **`python-package-workflow.yml`**
  retries the `pip` installs and the `pip-audit` install. In both cases only the
  INSTALL retries — the scanners themselves exit non-zero when they *find*
  something, so retrying them would re-run a real finding three times and report
  the same failure more slowly.
- **`create-badges.yml`** retries the badge push, and **`mcp-registry-publish.yml`**
  retries the release lookup and the publisher download. The age-gate is
  deliberately *not* softened: a transient API failure retries, but an empty
  `published_at` still aborts, because skipping a supply-chain gate * because the
  API was unreachable* defeats the point of having one.
- **Every one of these still fails the job if it never succeeds.** Retrying is
  for absorbing a blip, not for turning a real failure green.

- **Correction: `archive.yml`'s `fail_on_error` now defaults to `true`.** It
  shipped defaulting to `false`, which was wrong — a green run that archived
  nothing is a lie, and that contradicted the convention `clawhub-publish.yml`
  already set for exactly the same situation. The job is deliberately
  independent, nothing `needs:` it, so going red reports the truth without
  blocking the release or any other job. That is the split worth keeping: fail
  honestly, but never fail something that had no business being blocked.

## v0.31.0 — 2026-07-31

- **`docker-image-workflow.yml`: `scan_fail_build` now defaults to `false`.** An
  image built on any real base accumulates upstream CVEs continuously, most with
  no fix available, so failing the build on them turns the pipeline permanently
  red and the signal stops meaning anything — six repos here were red for exactly
  this. Findings are still uploaded to the Security tab, which is where they are
  meant to be read: the SARIF upload runs `if: always()` and never depended on
  the scan step passing. Set `scan_fail_build: true` on an image where a
  vulnerability genuinely must block the release.

  Every caller in this org that had an opinion already passed `false`
  explicitly; this makes the default match the practice instead of contradicting
  it.

## v0.30.1 — 2026-07-31

**Fixes every single-target caller of `docker-image-workflow.yml` failing.**
Anyone who calls it *without* `build_targets` should take this.

- `build-multi-wave1` gated on `needs.plan-multi.outputs.wave1 != '[]'` but not
  on `needs.plan-multi.result`. When a caller sets no `build_targets`,
  `plan-multi` is **skipped**, and every output of a skipped job is the **empty
  string** — so `'' != '[]'` evaluates TRUE, the job gets scheduled, and its
  matrix then tries `fromJson('')`, which is not valid JSON and cannot produce a
  matrix.
- The result is a run that **fails with no failed job, no step logs, and no
  retry offered** — every job reads `success` or `skipped` while the run
  conclusion is `failure`. Diagnosing it from the UI is close to impossible;
  the tell is that `build-multi-wave1` is *absent* from the job list rather than
  skipped, because it never instantiated.
- `build-multi` already gated on `plan-multi.result == 'success'` for exactly
  this reason. `build-multi-wave1` now does too. Multi-target callers were
  unaffected throughout, which is why the split was cleanly one path green and
  the other red.

## v0.30.0 — 2026-07-31

**Fixes mirrors silently freezing after their first run.** Anyone using
`git-mirror.yml` with GitLab should take this.

- **GitLab protects the default branch of a new project automatically**, with
  `allow_force_push: false`. A mirror force-pushes, so every run after the first
  was rejected with `You are not allowed to force push code to a protected
  branch (pre-receive hook declined)`.
- **The first run succeeds**, because it *creates* the branch rather than
  force-pushing over one — which is what makes this so nasty. Setup looks
  perfect, the project is there with all its refs, and the mirror then sits
  frozen at that initial snapshot while every later run fails. Observed in the
  wild: 46 repos green on their first mirror and failing on every push since.
- The job now **removes every protected-branch rule** on the target after
  ensuring the project exists. All of them, not just the default branch, because
  a wildcard rule like `release/*` rejects a force push the same way. Branch
  protection is meaningless on a read-only mirror. Wildcard names are URI-encoded
  so the slash does not 404 the request.
- Failing to unprotect is a warning rather than an error, and it names the branch
  whose force push will be rejected, so the cause shows up in the log instead of
  as a confusing push failure further down.

## v0.29.1 — 2026-07-31

This repo now archives itself, which it did not.

- **Added `.github/workflows/archive-self.yml`.** It could not be called
  `archive.yml` — that name belongs to the reusable definition this repo
  publishes — and the collision is exactly why the gap would have survived:
  anything checking "does this repo have an `archive.yml`" finds one and moves
  on. What it finds is a `workflow_call` definition, which never fires on its
  own. The identical collision hid the mirror gap in `v0.27.1`.
- Its cron slot was picked to not collide with any of the per-repo staggered
  slots, so it does not land on a rate-limited service at the same minute as
  another repo.

## v0.29.0 — 2026-07-31

`archive.yml` can now capture outlinks — the pages your README links to — which
turns out to need an archive.org account.

- **New optional `wayback_access_key` / `wayback_secret_key` secrets.** With
  them the Wayback job switches to the authenticated Save Page Now v2 API and
  the new `capture_outlinks` (default `true`) and `capture_screenshot` (default
  `false`) inputs take effect. Without them nothing breaks: it keeps using the
  keyless save exactly as before.
- **Why the keys are unavoidable, and why this is worth stating loudly:** the
  keyless path does not refuse `capture_outlinks`, it **silently ignores** it.
  Tested against the live service — a save with the flag returned HTTP 200, the
  page itself was archived, and a CDX query confirmed that not one linked page
  was. Outlink capture exists only on the v2 API, and an unauthenticated
  `POST /save` answers `You need to be logged in to use Save Page Now` even for
  a plain save with no options. The keyless `GET /save/<url>` is an older path
  that accepts no options at all.
- **The job warns when `capture_outlinks` is on but no keys are set**, so the
  gap is visible in the log rather than being a feature everyone assumes works.
- Bad keys are handled as a permanent failure: a `401` is classified
  not-retryable, so it fails fast instead of spending the backoff on an answer
  that will not change, and the step still exits 0 because archiving is best
  effort.

## v0.28.0 — 2026-07-31

New `archive.yml`: push a repo into public archives so it outlives the platform
it lives on.

- **Two targets, two failure modes.** The Wayback Machine archives the rendered
  page (README as HTML, the project homepage) — good against link rot, useless
  if what you need back is the code. Software Heritage archives the git object
  graph, every commit and blob, which is the one that matters if a host
  disappears entirely.
- **No API keys and no third-party actions.** Both are plain `curl`, so there is
  no marketplace action to SHA-pin and no supply-chain surface. Both services are
  anonymous-friendly and rate-limited rather than gated, which is what shapes the
  rest of this design. Verified against the live APIs: Software Heritage returns
  `save_request_status=accepted`, `save_task_status=pending` for an anonymous
  POST, and an unauthenticated Wayback save returns HTTP 200.
- **Exponential backoff on every request**, because the expected failure is
  "too many requests right now", not "no". `max_attempts` (default 3) and
  `backoff_seconds` (default 10) give 10s then 20s between tries. Only `429`,
  `5xx` and timeouts are retried — any other `4xx` means the URL itself is
  unacceptable, so it gives up at once instead of burning the backoff on an
  answer that will not change.
- **Best effort by default.** A throttled archive must never fail the release
  that triggered it, so refusals are warnings and the job still passes.
  `fail_on_error: true` inverts that.
- **Wayback is slow — a single save measured ~110s**, hence
  `url_timeout_seconds` defaulting to 180 and a deliberately short URL list. A
  timeout is not treated as a refusal: Wayback often completes the save after the
  client gives up, so the retry is a second chance rather than a correction.

## v0.27.1 — 2026-07-31

This repo now mirrors itself, which it never did.

- **Added `.github/workflows/mirror.yml`.** It could not be called
  `git-mirror.yml` — that name belongs to the reusable definition this repo
  publishes — and the collision is exactly why the gap survived: anything
  checking "does this repo have a `git-mirror.yml`" found one and moved on. What
  it found was a `workflow_call` definition, which never fires on a push, so
  nothing was ever mirrored and GitLab returned 404 for the project.

## v0.27.0 — 2026-07-31

`git-mirror.yml`: the project URL survives to GitLab, and a refused topic only
costs you that topic.

- **New `readme_url_header` input (default `true`).** GitLab is the only target
  with no writable project-URL field, and its README is the project landing
  page — so when the GitHub repo has a homepage set, it is now prepended as a
  markdown link at the top of the README on the mirror's default branch. Without
  this the URL simply had nowhere to go and was silently dropped.

  This is the one place a GitLab mirror deliberately differs from its source:
  that branch carries one extra commit. Every other branch, every tag and every
  other file stay byte-identical. The commit is authored by
  `git-mirror <git-mirror@noreply.invalid>` and **dated from the source tip
  rather than "now"**, which makes its hash stable — an unchanged source
  re-mirrors to the identical SHA, so the force-push is a no-op instead of
  rewriting the branch on every run and forcing everyone tracking the mirror to
  re-pull. A repo with no homepage, or no README, is untouched. Set
  `readme_url_header: false` to keep the mirror an exact copy.
- **Topics are now added incrementally when the bulk update is refused.**
  `v0.26.1` reacted to GitLab's all-or-nothing `422` by dropping the topics
  entirely; it now sets the description on its own and then grows the topic list
  one entry at a time, keeping everything accepted and skipping only what is
  actually refused. On the repo that surfaced this, 10 of 11 topics now land
  where previously all 11 were lost. The offenders are named in a warning. The
  bulk call is still attempted first, so the normal case is a single request.

## v0.26.1 — 2026-07-31

`git-mirror.yml`: a topic the target refuses no longer fails the whole mirror.

- **GitLab metadata sync now retries without topics.** GitLab validates the
  topic array as a unit and rejects the entire `PUT` with an opaque
  `422 Project could not be updated!` if it dislikes any single entry — and a
  topic that is perfectly legal on GitHub can be refused there, with nothing in
  the response saying which one. Observed on a repo whose only offending topic
  was `fileupload`, while `fileuploader` on the same repo was accepted. The sync
  now falls back to sending the description alone and emits a warning, so the
  mirror finishes.
- **Codeberg topic failures are a warning too.** The normalizer already covers
  Gitea's documented rules (lowercase, `[a-z0-9-]`, ≤35 chars, ≤25 topics), but
  a rejection it does not model would previously have failed the job after the
  description had already synced.
- The reasoning in both cases: mirroring refs is what the job is for. Metadata
  is a nicety, and losing the topics is not worth losing the mirror.

## v0.26.0 — 2026-07-31

`go-workflow.yml`: the codegen-drift gate is now opt-in, and the `-` skip
convention actually works for the lint and test jobs.

- **Breaking (behavior).** The `generate-check` job no longer runs by default.
  It is gated on a new **`has_codegen`** boolean input (default `false`) instead
  of on `generate_command`. When it shipped in `v0.19.0` the job defaulted to on,
  which meant every caller with no `generate` make target failed with
  `No rule to make target 'generate'` — and because the release job depends on
  it, the GitHub Release was skipped on those tags too. Defaulting a check on for
  repos that have nothing to check was the wrong call; a repo that generates
  nothing has no drift. Repos that DO commit generated files must now pass
  `has_codegen: true` to keep the check.
- **`generate_command` has no `-` escape.** `has_codegen` is the only switch for
  that job, so there is exactly one way to turn it off rather than two that can
  contradict each other. Callers that added `generate_command: "-"` to work
  around the `v0.19.0` default can drop the line — it is inert now, not an error.
- **Fixed: `-` did not skip the lint or test job.** The documented convention is
  that a `*_command` input set to `-` opts out of that step, but only
  `dep_command` was checked for it; `code-checks` and `test` gated on
  `!= ''` alone. A caller passing `lint_command: "-"` got a job that ran `-` as a
  shell command and failed, rather than a skipped job. Both now check for `-`.

## v0.25.0 — 2026-07-31

- **Breaking.** Dropped Bitbucket support from `git-mirror.yml`. The
  `bitbucket_enabled` input and the `bitbucket_user` / `bitbucket_token` /
  `bitbucket_workspace` secrets are gone, along with the job. A caller passing
  any of them now fails on an unknown input, so remove them from the `with:` and
  `secrets:` blocks. Callers that never enabled it are unaffected — nothing in
  this org did, so nothing breaks in practice.
- Mirroring targets Codeberg, GitLab and Gitee. It was the only target whose
  API shape was never verified against a live instance, and the only one whose
  account could not be logged into to get a token, so it shipped as untested
  code that would have gone stale unnoticed.

## v0.24.0 — 2026-07-31

- **Mirrored copies now announce themselves.** The synced description is
  prefixed with `[mirror] ` (`description_prefix`, set it to an empty string to
  disable) so someone landing on a copy can tell it from the original.
- **The description is capped so a long one cannot fail the sync.** Over
  `description_max_length` (default 2000) the text is cut and ends in `...`.
  GitLab and Gitee both reject anything past 2000 — Gitee answers `422` with
  `过长（最长为 2000 个字符）`, "too long (maximum 2000 characters)" — so an
  untruncated description silently failed the whole metadata sync.
- **The cap counts characters, not bytes.** Both platforms state their limit in
  characters, so the truncation runs through `jq`, which counts codepoints.
  Bash's `${#var}` counts bytes and would cut any description containing a
  multi-byte character (an em dash, an accent, CJK) well short of the real
  limit — or, worse, mid-sequence.

## v0.23.1 — 2026-07-31

Documentation only, no behavior change.

- The README's `git-mirror.yml` section was missing the concurrency behaviour
  added in v0.22.1: runs serialize per caller repository without cancelling,
  and repo creation tolerates losing a race. The shared-conventions list now
  names mirroring alongside the other workflows that serialize writers.
- Documented that a failed API call puts the response body in the error
  annotation, and why `-o /dev/null` was wrong: the first live failure reported
  only `curl: (22) ... error: 422`, with the message explaining it discarded.

## v0.23.0 — 2026-07-31

- **`git-mirror.yml` now syncs the GitHub homepage URL** to every target that
  has somewhere to put it. What each platform supports differs, and the
  workflow header documents the full matrix:

  | platform | description | topics | project URL |
  |---|---|---|---|
  | Codeberg | yes | yes | yes (`website`) |
  | GitLab | yes | yes | no |
  | Gitee | yes | no | yes (`homepage`) |
  | Bitbucket | yes | no | yes (`website`) |

  GitLab's project object exposes only derived URLs (`web_url`, `readme_url`,
  and friends), none of them writable, so the homepage has nowhere to go there.
- **Warn when Gitee creates the repository private.** Gitee requires a mobile
  number bound to the account before any repository can be public, and rather
  than refusing a `private: false` create it accepts the call and creates a
  PRIVATE repo — so the mirror runs green while the result is invisible to
  everyone. The Gitee job now re-reads visibility after creating and emits a
  warning naming the cause and the fix. Trying to flip such a repo afterwards
  returns `422` with `仓库转公开需绑定手机号码` ("making a repository public
  requires binding a phone number"), which is an account setting, not something
  a workflow can resolve.

## v0.22.1 — 2026-07-31

Fixes two defects in `git-mirror.yml` that the first live run surfaced.

- **A commit and its tag pushed together raced each other.** Both runs start
  about a second apart, both look the target up, both see 404, and both try to
  create it — one wins and the other dies on the duplicate. The workflow now
  serializes per caller repository (`concurrency`, without `cancel-in-progress`,
  since each run mirrors a real ref and the later one still has to push its
  own). Repo creation also tolerates losing the race directly: on a failed
  create it re-checks existence and continues if the repo is there, so a caller
  that starts two runs by other means still succeeds.
- **A failed API call hid the reason.** `--fail-with-body` correctly failed the
  step, but `-o /dev/null` discarded the very body that explains why — the first
  failure reported only `curl: (22) ... error: 422`, with the actual message
  (`已存在同地址仓库`, "a repo with the same address already exists") thrown away.
  Every create and metadata call now captures the response and puts it in the
  `::error::` annotation, naming the platform and the operation that failed.

## v0.22.0 — 2026-07-31

- **New `git-mirror.yml`.** Push-mirrors the caller repo to Codeberg, GitLab,
  Gitee and/or Bitbucket, creating the destination repo when it does not exist
  and syncing the GitHub description (plus topics, on the two platforms that
  have them). Each target is opt-in via `codeberg_enabled` / `gitlab_enabled` /
  `gitee_enabled` / `bitbucket_enabled` and runs as its own job with no `needs`
  between them, so a bad token on one platform cannot hold up the others.
- The mirror is one-way and authoritative: the push is forced, and with
  `prune: true` (default) refs deleted on GitHub are deleted on the target, so
  the copies stay identical. Set `prune: false` to leave stale branches alone.
- Two implementation choices that look unusual and are deliberate, both
  documented in the workflow header:
  - It bare-clones the source rather than using `actions/checkout` plus
    `git push --all`. A checkout creates exactly one local branch — every other
    branch stays a remote-tracking ref — so `--all` mirrors a single branch and
    silently drops the rest. The push uses explicit `+refs/heads/*` and
    `+refs/tags/*` refspecs off a bare clone instead.
  - Every API call passes `curl --fail-with-body`. Plain `curl -s` exits 0 on
    401/404/500, so `set -euo pipefail` does not catch a revoked token or a
    missing scope, and the step would go green having synced nothing.
- Platform differences worth knowing before enabling one: Gitea rejects the
  entire topics array if a single entry is invalid, so topics are lowercased,
  reduced to `[a-z0-9-]`, de-duplicated and capped at 25; GitLab project
  creation needs a token with `api` scope, not just `write_repository`; Gitee
  requires `name` on its repo-edit call and has no topics field; Bitbucket
  namespaces repos under a workspace and has no topics concept at all.

## v0.21.0 — 2026-07-31

- **`fail_on_upstream_error` now defaults to `true`.** v0.20.0 shipped it `false`,
  so a ClawHub outage produced a green run that had not published anything. That
  is the wrong trade: green reads as "shipped", and the silence is exactly how a
  package drifts versions behind the repo that owns it — `@psyb0t/mt5-httpapi`
  sat at `4.11.0` while the repo tagged `4.11.3`, and nothing said so. The
  retries still happen first (`publish_attempts`, default 4, quadratic backoff);
  what changed is that giving up is now loud. Set `fail_on_upstream_error: false`
  per caller to get the previous warning-and-defer behaviour back.
- A rejection of your own content is unaffected — it has always failed on the
  first attempt with no retries, whatever this input is set to.

## v0.20.0 — 2026-07-31

Two release-blocking bugs: Docker repos silently stopped cutting GitHub
Releases, and a ClawHub outage failed the whole pipeline.

### `docker-image-workflow.yml` — releases were silently never created

- **`release-multi`, `update-dockerhub-description` and `build-multi-wave1` now
  begin their conditions with `always()`.** Each already tried to tolerate an
  optional dependency being skipped (`|| needs.build-multi-wave1.result ==
  'skipped'`), but GitHub skips a job as soon as anything in its `needs` is
  skipped — *before* the `if` is evaluated — so that tolerance was dead code.
  A repo whose targets produce no wave-1 build therefore pushed its images and
  passed its scans while `release-multi` was quietly skipped: one consumer had
  tags through `v0.13.0` with GitHub Releases stopping at `v0.10.0`, and every
  one of those runs was green. `scan-multi` has carried this guard since it was
  written; these three were missing it.
- `build-multi-wave1` had the same defect one level up: a repo whose targets are
  all wave-1 skips `build-multi`, which skipped wave 1 with it, so nothing built.

### `clawhub-publish.yml` — an outage no longer fails a release

- **`clawhub-publish.yml` retries a publish that fails for ClawHub-side
  reasons**, `publish_attempts` times (default 4) with quadratic backoff. A real
  incident motivated this: `publish-plugins` failed two consecutive releases
  with `plugin-inspector-error: Plugin Inspector could not inspect
  @owner/pkg@x.y.z: ENOENT: no such file or directory, mkdir '/home/sbx_user…'`
  — a stack trace from ClawHub's own backend failing to create a sandbox home
  directory. Every test, lint and skill publish in those runs passed; the
  release went red for an outage the repo could not affect.
- **A ClawHub-side fault that never clears is now reported as deferred, not
  failed.** The item gets a `::warning::` and a `⏳` line in the summary, and the
  job succeeds. The tag is already cut and the artifact is unchanged, so
  re-running the job once their service recovers publishes it. Set the new
  `fail_on_upstream_error: true` to keep the old red-on-outage behavior.
- **A rejection of your own content still fails on the first attempt, with no
  retries.** The two cases are told apart by whether ClawHub's validator *ran*:
  findings reported against your skill or plugin ("blocked publish: N
  breakages", "validation failed") are yours and fail immediately; an inspector
  that could not start at all (`could not inspect`, `ENOENT` under
  `/home/sbx_user*`, Convex stack frames, HTTP 429/5xx, `ECONNRESET`,
  `socket hang up`, `fetch failed`) is theirs and is retried.
- Both halves of the workflow — skills and plugins — get the same handling.

## v0.19.1 — 2026-07-29

`create-badges.yml` now serializes updates to each caller's generated badge branch.

- **Fix — shared badge-branch writer lock.** Default-branch and tag invocations now use the same concurrency group for a caller repository and its selected `badges_branch`, with cancellation disabled. Concurrent invocations wait rather than racing a stale push to the mutable badge branch.

## v0.19.0 — 2026-07-28

`go-workflow.yml` gains a codegen-drift gate, and every `*_command` input can be switched off with `-`.

- **`go-workflow.yml`: new `generate-check` job.** Runs `generate_command` (default `make generate`), then fails if the working tree moved. This catches the two silent forms of codegen drift: a source change whose generator was never re-run, so stale generated output ships; and a hand-edit to a generated file, which the next regeneration wipes. Neither breaks the build, so only a diff finds them. The check uses `git status --porcelain` rather than `git diff --exit-code`, so a generator emitting a brand-new uncommitted file is caught too — `git diff` only sees tracked files. `.gitignore` is still respected. The job also gates the release job, so a drifted tree cannot cut a tag.
  - The gate assumes the generator is idempotent. One that stamps a timestamp or hostname, or iterates a map in random order, fails on every run — pin the generator version (for Go, the `go.mod` `tool` block) instead of disabling the job.
  - **Behavior change for existing callers:** because `generate_command` defaults to `make generate`, a caller that re-pins to this version and has no such target will see the new job fail. Set `generate_command: "-"` in repos that generate nothing.
- **`go-workflow.yml`: `-` disables any `*_command` input.** `dep_command`, `generate_command`, `lint_command` and `test_command` all treat `-` as "skip this step entirely". `""` keeps working for backwards compatibility, but `-` is the documented form — an empty string in a caller's YAML is indistinguishable from a templating accident, while `-` reads as a deliberate opt-out. `dep_command: "-"` skips dependency setup in every job, alongside the existing `is_vendored: true`.

## v0.18.0 — 2026-07-27

`create-badges.yml` coverage badge is now a dumb value-reader; `go-workflow.yml` can upload the coverage percentage.

- **`create-badges.yml`: the coverage badge no longer computes coverage.** It reads a percentage from a file (default `coverage-percent.txt`, downloaded from the `coverage` artifact) and bakes it into the SVG — no Go setup, no `go test`, no package selection. Producing the number is entirely the caller's pipeline job. If the coverage badge is enabled and the file is missing, the job fails. **Breaking:** the `go_version`, `is_vendored`, `dep_command`, `coverage_packages` inputs are removed; new inputs are `coverage_artifact` (default `coverage`) and `coverage_file` (default `coverage-percent.txt`), and `coverage` now defaults to `false`.
- **`go-workflow.yml`: new `coverage_file` + `coverage_artifact` inputs.** When `coverage_file` is set, the test job uploads that file (produced by `test_command`) as an artifact so a downstream `create-badges.yml` job can read the percentage. Off by default.

## v0.17.0 — 2026-07-27

New `create-badges.yml`: self-rendered SVG status badges with no third-party render service.

- **New reusable workflow `create-badges.yml`.** Renders coverage / license / version badges as flat SVGs directly in the job (no shields.io, no codecov, nothing external) and commits them to an orphan `badges` branch in the caller repo, so a README badge served from `raw.githubusercontent.com/<owner>/<repo>/badges/<name>.svg` renders for as long as the repo exists. Coverage is computed with `go test` + `go tool cover -func` and colored by threshold; license is the repo's SPDX id from the GitHub API; version is the latest SemVer tag. The publish commit is marked `[skip ci]` so badges never re-trigger a pipeline. Opt-in per badge via the `coverage` / `license` / `version` inputs; wire it on pushes to the default branch. Adding a new badge kind is a block in the workflow's "Render badges" step.

## v0.16.3 — 2026-07-27

`collaborators-only-workflow.yml`: allow-list trusted bot authors (Dependabot).

- **New `allow_authors` input** (default `dependabot[bot],dependabot-preview[bot]`). A PR whose author login is on this comma-separated list bypasses the collaborator check and is left **open** instead of being closed + locked. Dependabot's version/security-update PRs are meant to be reviewed and merged — and auto-closing them notified nobody anyway (a bot-opened, bot-closed PR generates no notification), so they vanished silently into the Closed tab. Human non-collaborator PRs are still closed as before. Callers that don't set the input get the Dependabot exemption by default.

## v0.16.2 — 2026-07-26

`go-workflow.yml`: removed the Codecov integration.

- **Removed the `codecov_enabled` and `coverage_file` inputs, the `codecov_token` secret, and the Codecov upload step** added in v0.16.0–v0.16.1. `go-workflow.yml` is back to its pre-v0.16.0 shape. Callers that referenced these inputs have had the wiring removed in the same change.

## v0.16.1 — 2026-07-26

`go-workflow.yml`: Codecov upload is now non-blocking.

- **`fail_ci_if_error` is now `false`** (was `true`). A Codecov-side problem — repository not activated, service outage, or a missing coverage file — is reported as a warning and no longer fails the `test` job, so it can never block the `release` (or a caller's publish) jobs that depend on the test job succeeding. This matches Codecov's recommended default.

## v0.16.0 — 2026-07-26

`go-workflow.yml`: optional Codecov coverage upload.

- **New `codecov_enabled` input (default `false`).** When set, the `test` job uploads the coverage profile that `test_command` leaves behind to Codecov after the tests run — no second test run. Requires the new `codecov_token` secret. Additive and opt-in: existing callers that don't set it are unchanged.
- **New `coverage_file` input (default `coverage.txt`).** Path to the coverage profile `test_command` writes, so a repo emitting a differently-named file (e.g. a mocks-filtered profile) can point at it.
- **New optional `codecov_token` secret (`required: false`).** Passed to `codecov/codecov-action` (SHA-pinned `v5.5.5`) as the upload token; the step runs under the `test` job's existing `contents: read` permission. If `codecov_enabled` is set but `test_command` produces no coverage file, the upload fails loudly (`fail_ci_if_error: true`) rather than passing silently.

## v0.15.1 — 2026-07-26

- README: documented `mcp-registry-publish.yml` — added it to the Contents list and the Workflows table, and gave it its own section with inputs + a usage example. Docs only; the v0.15.0 workflow shipped without the README entry.

## v0.15.0 — 2026-07-26

Added `mcp-registry-publish.yml` — publish a server to the official MCP Registry.

- **New reusable `mcp-registry-publish.yml`.** Publishes a `server.json` (default: caller repo root) to the official Model Context Protocol Registry (`registry.modelcontextprotocol.io`) on tag pushes. Secretless: authenticates via GitHub Actions OIDC to the `io.github.<owner>/*` namespace — no registry token. Before publishing it stamps the server `version` and each `oci` package's image tag from the git tag, so the entry references the exact image the same release built (the registry verifies the `io.modelcontextprotocol.server.name` LABEL on that image). `mcp-publisher` is exact-pinned (`publisher_version`, default `v1.8.0`) behind an age-gate; every Action is SHA-pinned; the calling job must grant `id-token: write`. Additive — no existing workflow changed.

## v0.14.0 — 2026-07-25

Removed the deprecated `clawhub-skills-publish-workflow.yml` compat shim.

- **Removed `clawhub-skills-publish-workflow.yml`.** The pass-through shim (added in v0.12.0 to preserve the pre-rename workflow name) is deleted — call `clawhub-publish.yml` directly. Its nested reusable-workflow call was also a startup-failure risk for callers. **Breaking** for any caller still referencing `clawhub-skills-publish-workflow.yml@…`: switch the `uses:` to `clawhub-publish.yml` — with the defaults it publishes both skills and plugins, and a repo missing one dir skips that half cleanly, so no `with:` block is needed for a skills-only repo.

## v0.13.0 — 2026-07-25

`clawhub-publish.yml`: both halves default ON, missing dirs skip cleanly, and a validate stage now gates every publish.

- **`publish_plugins` now defaults `true`** (was `false`). Skills and plugins both publish by default, so a caller that ships both no longer passes a `with:` block at all. `skills_dir` / `plugins_dir` keep their `.agents/skills` / `.agents/plugins` defaults.
- **Missing/empty dir = clean skip, not failure.** When `skills_dir` or `plugins_dir` is absent (or contains no `SKILL.md` / `openclaw.plugin.json`), that half logs and exits 0 instead of erroring — so a skills-only or plugin-only repo can safely leave both halves on.
- **New validate stage.** Each half runs `validate-*` → `publish-*`: `validate-skills` runs `clawhub skill publish --dry-run` per skill; `validate-plugins` runs the static `clawhub package validate` (Plugin Inspector — no `--runtime`, no token, no plugin code executed) per plugin. Each `publish-*` job `needs:` its matching validate job, so a malformed skill/plugin fails validation before anything is published.
- **Publish jobs are internally tag-gated.** `publish-skills` / `publish-plugins` now also require `startsWith(github.ref, 'refs/tags/')`. Validation runs whenever the workflow is *called*; publishing only fires on a tag ref. A caller can drop its own `if: tags` gate to get validation on every push while publishing stays tag-only. **Behavior note for existing callers:** publishing now requires a tag ref even if the caller doesn't gate — an intentional guardrail against publishing off a branch.

## v0.12.0 — 2026-07-25

New `clawhub-publish.yml` — one flow that publishes both **skills and plugins**. The old `clawhub-skills-publish-workflow.yml` name is retained as a thin pass-through shim.

- **New `clawhub-publish.yml`** is the canonical flow, with two independent jobs: `publish-skills` (unchanged behaviour; `publish_skills` input default `true`) and `publish-plugins` (new; `publish_plugins` default `false`).
- **Plugin path** — publishes every `<plugins_dir>/<name>/openclaw.plugin.json` (default `plugins_dir: .agents/plugins`) as a ClawHub plugin: `clawhub package validate` (STATIC only — no `--runtime`/`--allow-execute`, so no plugin code runs in CI) then `clawhub package publish`. On a tag push, the git tag is mirrored into each plugin's `package.json#version` (ClawHub takes the package version as the release version). The plugin path never installs a plugin's own dependencies in CI — `package publish` packs the source only.
- **New inputs:** `publish_skills`, `publish_plugins`, `plugins_dir`. Same supply-chain hardening as the skills path (exact-pinned, age-gated CLI; `npm install --ignore-scripts`; SHA-pinned actions; `contents: read`).
- **Backward compatible:** `clawhub-skills-publish-workflow.yml` now forwards to `clawhub-publish.yml` with plugins off, so existing `@master` callers keep working unchanged. Migrate to `clawhub-publish.yml` when convenient.

## v0.11.1 — 2026-07-25

`clawhub-skills-publish-workflow.yml`: fix the version-mirroring query so publishing a brand-new skill no longer fails.

- **Fix — first-time publish of a new skill.** The per-skill version check (`GET /api/v1/skills/<slug>`) ran under `curl -fsS`; for a skill that doesn't exist on ClawHub yet that request 404s, and with `-f` under `set -o pipefail` the step exited non-zero and aborted the whole publish. The query now tolerates the 404 (and any transient error) — the result is treated as an empty current version, so the new-skill / mirror-repo-tag branch runs as intended and the skill is created at the repo tag version. Publishing an existing skill is unchanged.

## v0.11.0 — 2026-07-24

`clawhub-skills-publish-workflow.yml`: the ClawHub version now follows the repo's git tag when it's ahead, instead of always blind patch-bumping.

- **Change — version mirrors the git tag.** On a tag push, each skill publishes at the git tag version (leading `v` stripped) — but only when that version is strictly higher than the skill's current ClawHub version. If ClawHub is already ahead (its version line drifted out in front of the repo, e.g. from earlier auto-patch publishes), it falls back to the CLI's automatic patch-bump until a repo tag finally exceeds it, then mirroring takes over. Off a tag or with a non-semver tag it auto patch-bumps as before. The per-skill decision queries `GET /api/v1/skills/<slug>` for the current version and compares with `sort -V`.
- **New `version` input** (default empty) to force an explicit ClawHub version, overriding the tag/auto logic.
- **A version that already exists is now treated as "already published"**, not a hard failure — so re-running a tag's pipeline no longer red-fails the publish job.

## v0.10.0 — 2026-07-24

`docker-image-workflow.yml`: Grype scan now uploads SARIF to the Security tab, plus a `scan_fail_build` toggle so a scan finding no longer has to fail the run.

- New `scan_fail_build` input (default `true`, backwards compatible). When `false`, Grype still scans + reports but a finding at/above `scan_severity` no longer fails the workflow — the right posture for images with known-unfixable upstream vulns, and what lets a downstream job `needs:` this workflow (a perpetually-red scan would otherwise block it forever).
- Both the single-image `scan` job and the multi-target `scan-multi` job now run Grype with `output-format: sarif` and upload the result to **Security → Code scanning** via `github/codeql-action/upload-sarif` (SHA-pinned `v4.37.1`). `scan-multi` uses a per-image `category` so matrix targets are tracked separately instead of overwriting each other. The SARIF upload is `continue-on-error` so a missing permission never fails an otherwise-green run.
- **Caller action needed for the Security tab:** the calling job must grant `permissions: security-events: write` (and `contents: write` if it also cuts a Release). Without it, scanning still runs but the Security tab isn't populated. README documents the pattern.
- Behavior change for existing callers: scan output moved from a log table to the Security tab (SARIF). Pass/fail behavior is unchanged by default (`scan_fail_build` defaults to `true`).

## v0.9.0 — 2026-07-24

New `clawhub-skills-publish-workflow.yml` — publishes skills to ClawHub via the official `clawhub` CLI.

- New reusable workflow that discovers every `<skills_dir>/<name>/SKILL.md` (default `skills_dir: .agents/skills`) and publishes each as its own ClawHub skill by driving the official `clawhub` CLI (`skill publish --json`). The CLI derives slug, display name, next version (auto patch-bump off the published version, `1.0.0` for new skills), summary, and file set. Records GitHub provenance via `--source-repo` / `--source-commit` / `--source-path` / `--source-ref`.
- **Read-only repo access** — the job runs with `contents: read` only; publishing authenticates with the `clawhub_token` secret written to a temp CLI config, not a repo-write scope.
- **Supply-chain hardened** — `cli_version` is exact-pinned (default `0.23.1`); an age-gate step queries the npm registry and refuses any CLI version published within `min_release_age_days` (default 7) days; install uses `npm install -g clawhub@<ver> --ignore-scripts`; `actions/checkout` and `actions/setup-node` are SHA-pinned.
- Inputs: `skills_dir`, `registry`, `site`, `tags`, `owner`, `cli_version`, `node_version`, `min_release_age_days`, `dry_run`, `runs_on`. Secret: `clawhub_token` (required). `dry_run: true` resolves + validates without publishing.
- Note: ClawHub licenses every published skill as `MIT-0` on its side (no per-skill override); the CLI sends the acceptance. The caller repo's own LICENSE is unaffected.

## v0.8.1 — 2026-07-22

GitHub Actions cache export is now best-effort for every Docker image build
path. A cache-service failure no longer cancels a successfully built and pushed
image.

## v0.8.0 — 2026-07-04

Ordered multi-target builds via optional per-target `stage`, so a variant that `FROM`s another target's tag builds after the base is pushed.

- New optional `stage` field on `build_targets` matrix entries (default `0`) in `docker-image-workflow.yml`. All stage-0 targets build+push before any stage-1 target starts. Use it for an image whose Dockerfile does `FROM <repo>:latest` — without ordering it would build in parallel with the base and inherit the *previously published* base instead of the one built in the same run.
- Multi-target path restructured into waves: a new `plan-multi` job splits `build_targets` into `wave0`/`wave1` with `jq`; `build-multi` builds wave 0, and a new `build-multi-wave1` job builds wave 1 gated on `needs: build-multi`. `release-multi`, `scan-multi`, and `update-dockerhub-description` now depend on both build jobs and tolerate `build-multi-wave1` being skipped.
- **Backwards compatible.** Targets without `stage` all land in wave 0 and build in parallel exactly as before; `build-multi-wave1` is skipped when no target sets `stage: 1`. Existing callers need no changes.
- README documents the `stage` field, adds an "Ordered builds" example, and notes stages run in ascending order while same-stage targets stay parallel.

## v0.7.0 — 2026-06-09

`free_disk_space` flipped to default-on, hand-written README, removed `update-readme.yml` auto-generator, dropped `actions/github-script` dependency, bumped pinned actions.

- **Breaking for self-hosted runner callers.** `free_disk_space` default flipped from `false` (as shipped in v0.6.0) to `true`. Any caller that targets a self-hosted runner MUST set `free_disk_space: false` — the cleanup wipes shared host directories (`/opt/ghc`, `/usr/local/lib/android`, `/usr/share/dotnet`, etc.) and will damage the host. GitHub-hosted runners get the ~25-30 GB freed by default.
- Removed `.github/workflows/update-readme.yml` + `update_readme.py`. README is now hand-written and documents every workflow's inputs, secrets, and example usage.
- `collaborators-only-workflow.yml`: replaced `actions/github-script@v7.0.1` with an inline shell script using the preinstalled `gh` CLI. Removes a third-party action dependency (and the associated SHA-pin maintenance) for the only workflow that used it. Behavior unchanged: 204 from `repos/.../collaborators/<user>` allows, 404 closes (with comment + optional lock), anything else fails.
- Bumped pinned actions to the latest releases ≥7 days old (OSV/GHSA scan clean on every prior pin): `actions/checkout` v6.0.2 → v6.0.3, `actions/setup-go` v6.3.0 → v6.4.0, `actions/setup-python` v6.1.0 → v6.2.0, `docker/build-push-action` v7.0.0 → v7.2.0, `docker/login-action` v4.0.0 → v4.2.0, `docker/setup-buildx-action` v4.0.0 → v4.1.0, `docker/setup-qemu-action` v4.0.0 → v4.1.0, `softprops/action-gh-release` v2.6.1 → v2.6.2, `pypa/gh-action-pypi-publish` `release/v1.12` branch SHA → `v1.14.0` (pin to a specific tag instead of a release branch).

## v0.6.0 — 2026-06-08

Opt-in runner disk cleanup for the docker image workflow.

- New input `free_disk_space` (default `false`) on `docker-image-workflow.yml`. Runs `jlumbroso/free-disk-space@v1.3.1` after checkout to free ~25-30 GB on GitHub-hosted runners (removes Android SDK, .NET, Haskell, large apt packages, preloaded docker images). Tool cache + swap left untouched.
- Applies to both single-image (`build`) and multi-target (`build-multi`) paths.
- Do NOT enable on self-hosted runners — wipes shared host directories.

## v0.5.0 — 2026-05-21

Multi-Dockerfile + per-target platform support for multi-target builds.

- `build_targets` matrix entries now accept optional `dockerfile` + `platforms` keys, so individual targets can use a different `Dockerfile` and/or override `target_platforms`.
- README documents the extended matrix entry shape.
- Tightened collaborators-only workflow: switched author identity check from `sender.login` to `pull_request.user.login`, moved templated inputs into `env:` for the github-script step (script injection trust boundary).

## v0.4.0 — 2026-04-22

Self-hosted runner support + cache mode control.

- New input `runs_on` (default `ubuntu-latest`) on `go-workflow.yml`, `python-package-workflow.yml`, `docker-image-workflow.yml`. Caller can pin jobs to a self-hosted runner label.
- New input `cache_mode` (default `max`) on `docker-image-workflow.yml`. Switch to `min` for very large images that fail to push the cache manifest.

## v0.3.2 — 2026-04-16

`update-readme.yml` watcher fix.

## v0.3.1 — 2026-04-16

Reordered docker pipeline so scan runs last.

- Push + GitHub Release now happen before the Grype scan; scan failure still surfaces in CI but no longer blocks the release artifact from being published. Caller sees the failure on the workflow summary.

## v0.3.0 — 2026-04-15

Security hardening pass.

- Added `collaborators-only-workflow.yml` — reusable PR gate that closes (and optionally locks) PRs from non-collaborators. Requires caller to trigger via `pull_request_target` so the token can comment/close fork PRs.
- Pinned every third-party action by full commit SHA (no floating tags).
- Added `govulncheck` job to the Go workflow + `pip-audit` job to the Python workflow.
- Added Grype image scan to the docker workflow with configurable severity threshold (`scan_severity`, default `medium`).
- Tightened workflow permissions away from blanket `write-all`.

## v0.2.1 — 2026-03-28

`build_targets` matrix fix.

## v0.2.0 — 2026-03-28

Multi-target docker builds.

- New input `build_targets` on `docker-image-workflow.yml`: JSON array of `{target, tag_suffix}` entries to build multiple Dockerfile stages from one repo into multiple tags in a single pipeline run.
- Empty `build_targets` keeps the original single-image behavior (backwards compatible).

## v0.1.0 — 2026-01-15

First tagged release.

- `go-workflow.yml` — Go test/lint/release reusable workflow with optional `is_vendored` input to skip the dep download step for vendored projects.
- `python-package-workflow.yml` — Python lint/test/build/publish reusable workflow with code-check matrix (bandit/pylint/flake8) and PyPI publish on tags.
- `docker-image-workflow.yml` — single-image Docker buildx pipeline with QEMU multi-arch, Docker Hub push, GitHub Release on tags.
- `update-readme.yml` — self-watcher that regenerates `README.md` from the workflow files in this repo.
