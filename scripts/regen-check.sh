#!/usr/bin/env bash
# Check step of regen-and-update-repo.yml. Runs CHECK_COMMANDS once against the
# working tree, keeps the full output as FIX_DIR/check-ATTEMPT.log and writes
# `passed=true|false` to GITHUB_OUTPUT.
#
# A failing check is a normal result here (the fix loop reads the log), so the
# script exits 0 either way. It exits non-zero only when the check commands
# changed the working tree, because checks must be read-only.
set -euo pipefail

readonly LOG_FILE="${LOG_FILE:-${RUNNER_TEMP:-/tmp}/regen-check.log}"

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

# Tree id of the working state, ignored files excluded, without touching the
# real index.
tree_state() {
	local index
	index="$(mktemp)"
	rm -f -- "${index}"
	GIT_INDEX_FILE="${index}" git add --all
	GIT_INDEX_FILE="${index}" git write-tree
	rm -f -- "${index}"
}

main() {
	local before after status check_log

	require_env CHECK_COMMANDS
	require_env FIX_DIR
	require_env ATTEMPT

	mkdir -p "${FIX_DIR}"
	check_log="${FIX_DIR}/check-${ATTEMPT}.log"

	before="$(tree_state)"
	status=0
	bash -euo pipefail -c "${CHECK_COMMANDS}" 2>&1 | tee "${check_log}" || status=$?
	after="$(tree_state)"

	if [[ "${before}" != "${after}" ]]; then
		echo "::error::The check commands changed tracked or new files. Make them read-only (no --fix, no regeneration)."
		git diff --stat "${before}" "${after}"
		exit 1
	fi

	if ((status == 0)); then
		log INFO "checks passed attempt=${ATTEMPT}"
		printf 'passed=true\n' >>"${GITHUB_OUTPUT}"
	else
		log WARN "checks failed attempt=${ATTEMPT} status=${status}"
		echo "::warning::Checks failed (attempt ${ATTEMPT}, exit ${status})"
		printf 'passed=false\n' >>"${GITHUB_OUTPUT}"
	fi
}

main "$@"
