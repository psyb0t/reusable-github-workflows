#!/usr/bin/env bash
# Builds the read-only context and the prompt for the describe step of
# regen-and-update-repo.yml, from a working tree that already holds the
# regenerated (uncommitted) changes.
#
# Writes:
#   CONTEXT_DIR/last-tag.txt         previous release tag, or "none"
#   CONTEXT_DIR/diff-stat.txt        git diff --stat against HEAD
#   CONTEXT_DIR/diff.patch           text diff against HEAD, truncated
#   CONTEXT_DIR/changelog-head.md    top of the changelog, as a style reference
#   CONTEXT_DIR/apidiff.txt          Go exported-API diff (only with GO_APIDIFF=true)
#   CONTEXT_DIR/context.txt          stdout of CONTEXT_COMMAND (only when set)
#   PROMPT_DIR/prompt.md             the task for claudebox
# and `last_tag=<tag>` to GITHUB_OUTPUT.
#
# Everything under CONTEXT_DIR is untrusted data for the model. The prompt is
# built only from values this workflow controls (tag, sizes, file names).
set -euo pipefail

readonly LOG_FILE="${LOG_FILE:-${RUNNER_TEMP:-/tmp}/regen-context.log}"
readonly CHANGELOG_HEAD_LINES=80
readonly SEMVER_TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'
readonly MAX_SUBJECT_TEXT_CHARS=55

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

last_semver_tag() {
	git tag --list 'v*' | grep -E "${SEMVER_TAG_RE}" | sort -V | tail -n 1 || true
}

# Best effort: apidiff is evidence for the model, not a gate. A failure is
# recorded in apidiff.txt and surfaced as a warning, never silently dropped.
write_apidiff() {
	local last_tag=$1
	local out="${CONTEXT_DIR}/apidiff.txt"
	local module work

	if [[ "${last_tag}" == "none" ]]; then
		printf 'No previous release tag; nothing to compare against.\n' >"${out}"
		return 0
	fi

	module="${GO_MODULE:-}"
	if [[ -z "${module}" ]]; then
		module="$(awk '$1 == "module" { print $2; exit }' go.mod)"
	fi
	if [[ -z "${module}" ]]; then
		log WARN "apidiff skipped: no go_module input and no module line in go.mod"
		printf 'apidiff could not run: module path unknown.\n' >"${out}"
		return 0
	fi

	work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/apidiff.XXXXXX")"
	git worktree add --quiet --detach "${work}/old" "${last_tag}"

	if (cd "${work}/old" && "${APIDIFF_BIN}" -m -w "${work}/old.exp" "${module}") 2>"${work}/err" &&
		"${APIDIFF_BIN}" -m "${work}/old.exp" "${module}" >"${work}/report" 2>>"${work}/err"; then
		{
			printf 'Exported API of %s, %s compared with the regenerated working tree:\n\n' "${module}" "${last_tag}"
			if [[ -s "${work}/report" ]]; then
				cat "${work}/report"
			else
				printf 'No exported API changes.\n'
			fi
		} >"${out}"
		log INFO "apidiff completed module=${module} base=${last_tag}"
	else
		log WARN "apidiff failed module=${module} base=${last_tag}: $(tr '\n' ' ' <"${work}/err" | head -c 500)"
		printf 'apidiff could not run against %s.\n' "${last_tag}" >"${out}"
		echo "::warning::apidiff failed; the description step gets no API report"
	fi

	git worktree remove --force "${work}/old"
	rm -r -- "${work}"
}

write_prompt() {
	local last_tag=$1
	local version_note has_apidiff has_context

	if [[ "${last_tag}" == "none" ]]; then
		version_note="There is no previous release tag."
	elif [[ "${last_tag}" == v0.* ]]; then
		version_note="The previous release is ${last_tag}. The project is pre-1.0."
	else
		version_note="The previous release is ${last_tag}. The project is 1.0 or later."
	fi
	has_apidiff="no"
	[[ -f "${CONTEXT_DIR}/apidiff.txt" ]] && has_apidiff="yes"
	has_context="no"
	[[ -f "${CONTEXT_DIR}/context.txt" ]] && has_context="yes"

	{
		cat <<'EOF'
An automated job ran this repository's code generator and it produced changes.
Describe those changes for the changelog and the commit subject, and classify
them so the workflow can pick the next version.

Context files under /context:
- diff-stat.txt: files changed by the regeneration.
- diff.patch: the full diff against the last commit (may be truncated; a note at the end says so).
- changelog-head.md: the top of the repository's existing changelog. Match its style.
- last-tag.txt: the previous release tag.
EOF
		[[ "${has_apidiff}" == "yes" ]] && printf -- '- apidiff.txt: a Go exported-API comparison between the previous release and the regenerated tree. Strong evidence for the classification and for naming changed identifiers.\n'
		[[ "${has_context}" == "yes" ]] && printf -- '- context.txt: extra facts the repository collected about this regeneration (for example upstream version lines).\n'
		printf '\n%s\n\n' "${version_note}"
		cat <<EOF
Write exactly these four files in the output directory and nothing else:

1. changelog.md: the body of ONE changelog entry. No heading, no version, no date.
   - Bullet lines only, each starting with "- ". Plain English, one change per bullet.
   - Describe user-visible changes to the public API or behavior. Name the added,
     removed and changed functions, methods, types and fields in backticks, taken
     from the diff (and apidiff.txt when present).
   - No em dashes and no en dashes. Use commas, colons or separate sentences.
   - No marketing words (for example: seamless, powerful, robust, enhanced, comprehensive).
   - No URLs to chat sessions, no "Co-authored-by" lines, no mention of AI tools.
   - Under 3000 bytes. If the change is large, summarize by area.

2. subject.txt: ONE line, the commit subject text WITHOUT any version prefix
   (the workflow prepends "vX.Y.Z: "). Lower-case start, concrete, at most
   ${MAX_SUBJECT_TEXT_CHARS} characters, no trailing period, no dashes of the kinds above.

3. change-kind.txt: exactly one word, one of:
   - fix: regenerated output changed without adding or removing public API
     (documentation, defaults, internal fixes).
   - feature: new public API was added and every existing caller still compiles
     and behaves the same.
   - breaking: public API was removed or renamed, or a signature, type or
     behavior changed so existing callers must change their code.
   When in doubt between two kinds, pick the stronger one.

4. bump-reason.txt: one or two plain sentences explaining the change-kind choice,
   citing the specific identifiers that drove it.
EOF
	} >"${PROMPT_DIR}/prompt.md"
}

main() {
	local last_tag size

	require_env CONTEXT_DIR
	require_env PROMPT_DIR
	require_env MAX_DIFF_BYTES

	mkdir -p "${CONTEXT_DIR}" "${PROMPT_DIR}"

	last_tag="$(last_semver_tag)"
	[[ -n "${last_tag}" ]] || last_tag="none"
	printf '%s\n' "${last_tag}" >"${CONTEXT_DIR}/last-tag.txt"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf 'last_tag=%s\n' "${last_tag}" >>"${GITHUB_OUTPUT}"
	fi

	# Intent-to-add makes new untracked files show up in the diffs below.
	git add --intent-to-add --all
	git diff --stat HEAD >"${CONTEXT_DIR}/diff-stat.txt"
	git diff HEAD >"${CONTEXT_DIR}/diff.full"
	size="$(wc -c <"${CONTEXT_DIR}/diff.full")"
	if ((size > MAX_DIFF_BYTES)); then
		head -c "${MAX_DIFF_BYTES}" "${CONTEXT_DIR}/diff.full" >"${CONTEXT_DIR}/diff.patch"
		printf '\n\n[diff truncated: showing %d of %d bytes; diff-stat.txt lists every file]\n' \
			"${MAX_DIFF_BYTES}" "${size}" >>"${CONTEXT_DIR}/diff.patch"
	else
		mv "${CONTEXT_DIR}/diff.full" "${CONTEXT_DIR}/diff.patch"
	fi
	rm -f -- "${CONTEXT_DIR}/diff.full"

	if [[ -n "${CHANGELOG_PATH:-}" && -f "${CHANGELOG_PATH}" ]]; then
		head -n "${CHANGELOG_HEAD_LINES}" "${CHANGELOG_PATH}" >"${CONTEXT_DIR}/changelog-head.md"
	else
		printf 'No changelog yet. Use "- " bullet lines.\n' >"${CONTEXT_DIR}/changelog-head.md"
	fi

	if [[ "${GO_APIDIFF:-false}" == "true" ]]; then
		require_env APIDIFF_BIN
		write_apidiff "${last_tag}"
	fi

	if [[ -n "${CONTEXT_COMMAND:-}" ]]; then
		if ! bash -euo pipefail -c "${CONTEXT_COMMAND}" >"${CONTEXT_DIR}/context.txt"; then
			log WARN "context_command failed; context.txt may be partial"
			echo "::warning::context_command failed; context.txt may be partial"
		fi
	fi

	write_prompt "${last_tag}"
	log INFO "context built last_tag=${last_tag} diff_bytes=${size}"
}

main "$@"
