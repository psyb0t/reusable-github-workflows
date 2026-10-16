#!/usr/bin/env bash
# Fix loop helper of regen-and-update-repo.yml.
#
#   regen-fix.sh prepare   builds the read-only context and the prompt for fix
#                          attempt ATTEMPT, and records the tree before Claude
#                          edits the checkout
#   regen-fix.sh guard     compares the tree after the attempt with the one
#                          recorded by prepare, rejects edits to protected
#                          paths and added check-suppression markers, and keeps
#                          Claude's notes and diff for the review step
#
# Layout under FIX_DIR:
#   check-N.log                 output of check run N (from regen-check.sh)
#   attempt-N/context/          mounted read-only at /context for attempt N
#   attempt-N/prompt.md         the task for attempt N
#   attempt-N/pre-tree          tree id before attempt N
#   notes-N.md, fix-N.patch     Claude's summary and diff for attempt N
#
# Everything under the context directory is untrusted data for the model. The
# prompt is built only from values this workflow controls.
set -euo pipefail

readonly LOG_FILE="${LOG_FILE:-${RUNNER_TEMP:-/tmp}/regen-fix.log}"
readonly MAX_LOG_BYTES=150000
readonly MAX_NOTES_BYTES=4000
# Added lines that switch a check off instead of fixing what it reports.
# Added lines that credit an AI tool. Commits carry no such attribution.
readonly ATTRIBUTION_RE='co-authored-by|claude[ -]code|claude\.ai|anthropic\.com|(generated|written|created|authored) (with|by) (claude|an? ai|ai)|claude-session'
readonly SUPPRESSION_RE='t\.Skip(Now|f)?\(|//[[:space:]]*nolint|nosemgrep|gitleaks:allow|#nosec|pytest\.mark\.skip|#[[:space:]]*noqa|eslint-disable|@ts-ignore|@ts-nocheck|shellcheck[[:space:]]+disable'

log() {
	local level=$1
	shift

	jq -cn \
		--arg time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
		--arg level "${level}" \
		--arg file "${BASH_SOURCE[1]##*/}" \
		--argjson line "${BASH_LINENO[0]}" \
		--arg func "${FUNCNAME[1]:-main}" \
		--arg msg "$*" \
		'{time: $time, level: $level, file: $file, line: $line, func: $func, msg: $msg}' | tee -a "${LOG_FILE}" >&2
}

require_env() {
	local name=$1
	if [[ -z "${!name:-}" ]]; then
		log ERROR "required environment variable is empty name=${name}"
		exit 1
	fi
}

# Every glob a fix attempt must not touch, one per line: the floor the
# workflow always enforces (.github/, the changelog and the version files it
# writes itself) plus the caller's PROTECTED_PATHS. A glob matches with bash
# [[ == ]], where * also crosses directories.
protected_globs() {
	local file
	{
		printf '.github/*\n'
		[[ -n "${CHANGELOG_PATH:-}" ]] && printf '%s\n' "${CHANGELOG_PATH}"
		for file in ${VERSION_FILES:-}; do
			printf '%s\n' "${file}"
		done
		printf '%s\n' "${PROTECTED_PATHS:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
	} | awk 'NF && !seen[$0]++'
}

tree_state() {
	local index
	index="$(mktemp)"
	rm -f -- "${index}"
	GIT_INDEX_FILE="${index}" git add --all
	GIT_INDEX_FILE="${index}" git write-tree
	rm -f -- "${index}"
}

# Last MAX bytes of a file, with a note when it was cut.
tail_capped() {
	local src=$1 dst=$2 max=$3 size
	size="$(wc -c <"${src}")"
	if ((size > max)); then
		{
			printf '[log truncated: showing the last %d of %d bytes]\n\n' "${max}" "${size}"
			tail -c "${max}" "${src}"
		} >"${dst}"
	else
		cp -- "${src}" "${dst}"
	fi
}

prepare() {
	local dir ctx prev size n
	require_env ATTEMPT
	require_env MAX_DIFF_BYTES
	require_env WRITING_RULES

	dir="${FIX_DIR}/attempt-${ATTEMPT}"
	ctx="${dir}/context"
	mkdir -p "${ctx}"
	prev=$((ATTEMPT - 1))

	tail_capped "${FIX_DIR}/check-${prev}.log" "${ctx}/check-output.log" "${MAX_LOG_BYTES}"
	cp -- "${WRITING_RULES}" "${ctx}/writing-rules.md"

	# The regeneration diff as it stands now, earlier fixes included.
	git add --intent-to-add --all
	git diff --stat HEAD >"${ctx}/diff-stat.txt"
	git diff HEAD >"${ctx}/diff.full"
	size="$(wc -c <"${ctx}/diff.full")"
	if ((size > MAX_DIFF_BYTES)); then
		head -c "${MAX_DIFF_BYTES}" "${ctx}/diff.full" >"${ctx}/diff.patch"
		printf '\n\n[diff truncated: showing %d of %d bytes; diff-stat.txt lists every file]\n' \
			"${MAX_DIFF_BYTES}" "${size}" >>"${ctx}/diff.patch"
	else
		mv -- "${ctx}/diff.full" "${ctx}/diff.patch"
	fi
	rm -f -- "${ctx}/diff.full"

	# The whole history, so this attempt sees every earlier failure and what
	# was already tried.
	mkdir -p "${ctx}/history"
	tail_capped "${FIX_DIR}/check-0.log" "${ctx}/history/check-0.log" "${MAX_LOG_BYTES}"
	for ((n = 1; n < ATTEMPT; n++)); do
		if [[ -f "${FIX_DIR}/notes-${n}.md" ]]; then
			cp -- "${FIX_DIR}/notes-${n}.md" "${ctx}/history/attempt-${n}-notes.md"
		fi
		if [[ -f "${FIX_DIR}/fix-${n}.patch" ]]; then
			tail_capped "${FIX_DIR}/fix-${n}.patch" "${ctx}/history/attempt-${n}.patch" "${MAX_LOG_BYTES}"
		fi
		if [[ -f "${FIX_DIR}/check-${n}.log" ]]; then
			tail_capped "${FIX_DIR}/check-${n}.log" "${ctx}/history/check-${n}.log" "${MAX_LOG_BYTES}"
		fi
	done

	tree_state >"${dir}/pre-tree"
	write_prompt "${dir}/prompt.md"
	log INFO "fix context prepared attempt=${ATTEMPT} diff_bytes=${size}"
}

write_prompt() {
	local out=$1
	cat >"${out}" <<EOF
An automated job ran this repository's code generator. The repository's checks
(\`${CHECK_COMMANDS}\`) now fail. Your current working directory is the
repository checkout with the regenerated changes applied. Fix the repository so
the checks pass. This is attempt ${ATTEMPT} of ${MAX_ATTEMPTS}.

Context files under /context:
- check-output.log: output of the latest failing check run. Start here.
- diff-stat.txt and diff.patch: everything changed against the last commit
  so far, the regeneration plus any earlier fix attempts.
- history/check-0.log: the first failure, right after regeneration.
- writing-rules.md: rules for every word you write. Follow them.
EOF
	if ((ATTEMPT > 1)); then
		cat >>"${out}" <<'EOF'
- history/attempt-N-notes.md, history/attempt-N.patch, history/check-N.log:
  for each earlier attempt, its own summary, exactly what it changed, and the
  checks output after it. Those attempts did not get the checks passing. Read
  all of them, work out why, and do not repeat what already failed. Keep their
  changes when they are right; revert them when they are wrong.
EOF
	fi
	cat >>"${out}" <<'EOF'

Before you change anything:
1. Read AGENTS.md and every file under .agents/rules/ in the checkout, plus any
   README.md or docs they point to. They are the repository's own standards.
   Follow them for naming, error handling, logging, layout, comments and
   tooling. Match the style of the surrounding code.
2. Use the repository's own tooling, the Make targets listed in AGENTS.md or
   `make help` (for example make generate, make dep, make lint, make test,
   make sec, make pkg-update). Do not run a toolchain directly when a Make
   target does the job. Change dependencies only through those targets.
3. Find the root cause in check-output.log.

How to fix:
- Generated files are overwritten on the next run. Fix the cause at its
  source: the spec patch scripts, the generator config, hand-written code,
  pinned versions in the Dockerfiles, or a dependency bump. Regenerate with the
  repository's generate target afterwards when your fix changes generator
  input.
- Do not weaken the checks. Never add skips or suppressions (t.Skip, nolint,
  nosemgrep, gitleaks:allow, #nosec, noqa, eslint-disable, shellcheck
  disable). Never delete or loosen a test to make it pass. The workflow
  rejects these.
- Never edit the protected paths listed at the end of this task. The
  workflow rejects any change to them, including the changelog and version
  files, which it writes itself.
- No attribution anywhere: no comment, string or file may say it was written,
  generated or fixed by Claude, Claude Code, Anthropic or any AI tool.
- Run the failing checks yourself until they pass. Leave no stray files behind.
- Do not commit, tag or push.

When you are done, reply with a short plain summary of what you changed and
why, as "- " bullet lines, following writing-rules.md. If you could not fix it,
say what blocks it.

Protected paths (globs, * also matches across directories):
EOF
	protected_globs | sed 's/^/- /' >>"${out}"
}

# Notes and changed files of this attempt in the job summary. The notes are
# model output, so they go in a fenced block and never render as Markdown.
summarize() {
	local changed=$1
	[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
	# shellcheck disable=SC2016 # literal backticks for Markdown
	{
		printf '### Fix attempt %s\n\nChanged files:\n\n```\n%s\n```\n\nClaude'"'"'s summary:\n\n```\n' "${ATTEMPT}" "${changed}"
		sed 's/```/` ` `/g' "${FIX_DIR}/notes-${ATTEMPT}.md"
		printf '```\n\n'
	} >>"${GITHUB_STEP_SUMMARY}"
}

guard() {
	local dir pre post changed bad added notes file line glob
	local -a globs
	require_env ATTEMPT

	dir="${FIX_DIR}/attempt-${ATTEMPT}"
	if [[ ! -s "${dir}/pre-tree" ]]; then
		log ERROR "no tree recorded before the attempt; prepare did not run attempt=${ATTEMPT}"
		exit 1
	fi
	pre="$(cat "${dir}/pre-tree")"
	post="$(tree_state)"

	notes="${RESULT:-}"
	notes="${notes:0:${MAX_NOTES_BYTES}}"
	[[ -n "${notes// /}" ]] || notes="(no summary given)"
	printf '%s\n' "${notes}" >"${FIX_DIR}/notes-${ATTEMPT}.md"

	if [[ "${pre}" == "${post}" ]]; then
		log WARN "fix attempt changed nothing attempt=${ATTEMPT}"
		echo "::warning::Fix attempt ${ATTEMPT} changed nothing"
		: >"${FIX_DIR}/fix-${ATTEMPT}.patch"
		summarize "(none)"
		return 0
	fi

	git diff "${pre}" "${post}" >"${FIX_DIR}/fix-${ATTEMPT}.patch"
	changed="$(git diff --name-only "${pre}" "${post}")"
	echo "::group::Files changed by fix attempt ${ATTEMPT}"
	printf '%s\n' "${changed}"
	echo "::endgroup::"

	mapfile -t globs < <(protected_globs)
	bad=""
	while IFS= read -r file; do
		for glob in "${globs[@]}"; do
			# shellcheck disable=SC2053 # the right side is a glob on purpose
			if [[ "${file}" == ${glob} ]]; then
				bad+="${file} "
				break
			fi
		done
	done <<<"${changed}"
	if [[ -n "${bad}" ]]; then
		echo "::error::Fix attempt ${ATTEMPT} edited protected paths: ${bad}"
		exit 1
	fi

	# Vendored and generated files carry upstream directives; only check
	# hand-written files.
	added="$(git diff --unified=0 "${pre}" "${post}" -- . ':(exclude)vendor/' |
		awk '
			/^\+\+\+ / { file = substr($0, 7); next }
			/^\+/ && file != "" { print file ": " substr($0, 2) }
		' | grep -E "${SUPPRESSION_RE}" || true)"
	if [[ -n "${added}" ]]; then
		while IFS= read -r line; do
			file="${line%%: *}"
			if [[ -f "${file}" ]] && head -n 5 "${file}" | grep -q 'Code generated .* DO NOT EDIT'; then
				continue
			fi
			echo "::error::Fix attempt ${ATTEMPT} added a check suppression in ${file}"
			exit 1
		done <<<"${added}"
	fi

	added="$(git diff --unified=0 "${pre}" "${post}" -- . ':(exclude)vendor/' |
		grep -E '^\+[^+]' | grep -iE "${ATTRIBUTION_RE}" || true)"
	if [[ -n "${added}" ]]; then
		echo "::error::Fix attempt ${ATTEMPT} added AI attribution"
		printf '%s\n' "${added}" | head -n 5
		exit 1
	fi

	summarize "${changed}"

	log INFO "fix attempt passed the guard attempt=${ATTEMPT} files=$(wc -l <<<"${changed}")"
}

main() {
	require_env FIX_DIR
	case "${1:-}" in
		prepare)
			require_env CHECK_COMMANDS
			require_env MAX_ATTEMPTS
			prepare
			;;
		guard) guard ;;
		*)
			log ERROR "usage: regen-fix.sh prepare|guard"
			exit 1
			;;
	esac
}

main "$@"
