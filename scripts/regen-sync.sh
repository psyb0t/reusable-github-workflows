#!/usr/bin/env bash
# Moves the regenerated, checked working tree onto the branch tip when the
# branch moved while regen-and-update-repo.yml was running.
#
# A regeneration plus its checks and fix attempts can take an hour, and a
# commit pushed meanwhile would otherwise make the final push fail. This runs
# after the checks pass: it saves the working tree as a patch against the
# commit the run started from, checks out the current tip, and applies the
# patch three-way. A conflict leaves standard conflict markers in the files;
# the workflow then runs the checks again and, when they fail or markers
# remain, gives Claude one more fix attempt on the new tip.
#
# Outputs (GITHUB_OUTPUT):
#   moved=true|false     the branch tip differs from the commit regen started on
#   conflict=true|false  the patch did not apply cleanly onto the new tip
#   base_sha=<sha>       the commit the working tree now sits on
set -euo pipefail

readonly LOG_FILE="${LOG_FILE:-${RUNNER_TEMP:-/tmp}/regen-sync.log}"

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

main() {
	local base tip patch conflict

	require_env BRANCH
	require_env FIX_DIR
	mkdir -p "${FIX_DIR}"

	base="$(git rev-parse HEAD)"
	git fetch --quiet origin "refs/heads/${BRANCH}"
	tip="$(git rev-parse FETCH_HEAD)"

	if [[ "${tip}" == "${base}" ]]; then
		log INFO "branch did not move base=${base}"
		printf 'moved=false\nconflict=false\nbase_sha=%s\n' "${base}" >>"${GITHUB_OUTPUT}"
		return
	fi

	patch="${FIX_DIR}/sync.patch"
	git add --intent-to-add --all
	git diff --binary HEAD >"${patch}"

	# Drop the working tree changes (now saved in the patch) and move to the
	# tip. Ignored files such as downloaded specs stay where they are.
	git reset --quiet --hard
	git clean --quiet -d --force
	git checkout --quiet --detach "${tip}"

	conflict=false
	if ! git apply --binary --3way "${patch}"; then
		conflict=true
	fi
	# Leave every change, conflict markers included, unstaged for the checks.
	git reset --quiet

	log INFO "branch moved during the run base=${base} tip=${tip} conflict=${conflict}"
	printf 'moved=true\nconflict=%s\nbase_sha=%s\n' "${conflict}" "${tip}" >>"${GITHUB_OUTPUT}"
	# shellcheck disable=SC2016 # literal backticks for Markdown
	{
		printf '### Branch moved during the run\n\n'
		printf 'Moved the regenerated changes from `%s` onto `%s`.' "${base:0:12}" "${tip:0:12}"
		if [[ "${conflict}" == "true" ]]; then
			printf ' The patch conflicted; the checks and a fix attempt run on the result.\n\n'
		else
			printf ' The patch applied cleanly; the checks run again on the result.\n\n'
		fi
	} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
}

main "$@"
