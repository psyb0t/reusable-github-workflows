#!/usr/bin/env bash
# Close the failure issues report-failure opened once regeneration and validation
# succeeds again. Called by regen-and-update-repo.yml's report-recovery job.
#
# An issue is closed only when the newest failed run it reports, in its body
# or in a bot comment, is older than this run, so a newer failure stays open.
#
# Environment:
#   GH_TOKEN, GH_REPO  read by gh
#   RUN_ID             this run's ID
#   RUN_PREFIX         URL prefix of run links, ending in /actions/runs/
#   TITLE              the failure issue title
#   GH_BIN             overridable for tests (default gh)
set -euo pipefail

readonly BOT_LOGIN='github-actions[bot]'
readonly FAILURE_PREFIX='The scheduled regeneration failed in this run: '
readonly VALIDATION_FAILURE_PREFIX='Regeneration or validation failed in this run: '

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
		'{time: $time, level: $level, file: $file, line: $line, func: $func, msg: $msg}' >&2
}

require_env() {
	local name
	for name in "$@"; do
		if [[ -z "${!name:-}" ]]; then
			log ERROR "required environment variable is empty name=${name}"
			exit 1
		fi
	done
}

# failure_issues prints one {number, body} object per open failure issue the
# bot opened under TITLE.
failure_issues() {
	"${GH_BIN}" api --paginate --slurp "repos/${GH_REPO}/issues?state=open&per_page=100" |
		jq -c --arg title "${TITLE}" --arg bot "${BOT_LOGIN}" --arg prefix "${FAILURE_PREFIX}" \
			--arg validation "${VALIDATION_FAILURE_PREFIX}" '
			.[][]
			| select(.pull_request == null and .title == $title and .user.login == $bot)
			| select((.body // "") | startswith($prefix) or startswith($validation))
			| {number, body}'
}

# latest_failure_run NUMBER BODY prints the highest run ID reported as failed
# in the issue body and the bot's comments, or nothing.
latest_failure_run() {
	local number=$1 body=$2

	"${GH_BIN}" api --paginate --slurp "repos/${GH_REPO}/issues/${number}/comments?per_page=100" |
		jq -r --arg body "${body}" --arg prefix "${RUN_PREFIX}" --arg bot "${BOT_LOGIN}" \
			--arg failure "${FAILURE_PREFIX}" --arg validation "${VALIDATION_FAILURE_PREFIX}" '
			[$body, (.[][] | select(.user.login == $bot) | (.body // ""))]
			| map(select(startswith($failure) or startswith($validation))
				| ltrimstr($failure)
				| ltrimstr($validation)
				| split("\n")[0]
				| select(startswith($prefix)) | ltrimstr($prefix)
				| select(test("^[0-9]+$")) | tonumber)
			| max // empty'
}

main() {
	local issues issue number body latest closed=0

	GH_BIN="${GH_BIN:-gh}"
	require_env GH_REPO RUN_ID RUN_PREFIX TITLE

	issues="$(failure_issues)"
	while IFS= read -r issue; do
		[[ -n "${issue}" ]] || continue
		number="$(jq -r '.number' <<<"${issue}")"
		body="$(jq -r '.body' <<<"${issue}")"
		latest="$(latest_failure_run "${number}" "${body}")"

		# A later scheduled failure must not be cleared by an older run.
		if [[ -z "${latest}" ]] || ((latest > RUN_ID)); then
			log INFO "leaving failure issue open number=${number} latest_failure_run=${latest:-none}"
			continue
		fi
		"${GH_BIN}" issue close "${number}" --reason completed \
			--comment "Regeneration and validation recovered: ${RUN_PREFIX}${RUN_ID}"
		log INFO "closed recovered failure issue number=${number}"
		closed=$((closed + 1))
		if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
			echo "Closed recovered failure issue #${number}." >>"${GITHUB_STEP_SUMMARY}"
		fi
	done <<<"${issues}"
	log INFO "recovery check finished closed=${closed}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
