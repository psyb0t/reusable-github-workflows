#!/usr/bin/env bash
# Validation step of regen-and-update-repo.yml. Runs generation, the repair
# guard when configured, and CHECK_COMMANDS, keeping FIX_DIR/check-ATTEMPT.log.
# Writes `passed=true|false` to GITHUB_OUTPUT.
#
# A failing check is a normal result here (the fix loop reads the log), so the
# script exits 0 either way. It exits non-zero when the check commands
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

	require_env FIX_DIR
	require_env ATTEMPT

	mkdir -p "${FIX_DIR}"
	check_log="${FIX_DIR}/check-${ATTEMPT}.log"

	# A rejected model patch cannot become acceptable merely because tests pass.
	if [[ -n "${GUARD_OUTCOME:-}" && "${GUARD_OUTCOME}" != success ]]; then
		{
			printf 'Repair rejected. Remove the prohibited changes and fix the original cause.\n'
			cat "${FIX_DIR}/guard-${ATTEMPT}.log"
			printf '\nOriginal failure:\n'
			cat "${FIX_DIR}/check-0.log"
		} >"${check_log}"
		printf 'passed=false\n' >>"${GITHUB_OUTPUT}"
		log WARN "guard rejected repair attempt=${ATTEMPT}"
		return 0
	fi

	: >"${check_log}"
	status=0
	if [[ -n "${GENERATE_COMMAND:-}" && "${GENERATE_COMMAND}" != - ]]; then
		bash -euo pipefail -c "${GENERATE_COMMAND}" 2>&1 | tee -a "${check_log}" || status=$?
	fi
	if ((status == 0)) && [[ -n "${GUARD_SCRIPT:-}" ]]; then
		bash "${GUARD_SCRIPT}" guard 2>&1 | tee -a "${check_log}" "${FIX_DIR}/guard-${ATTEMPT}.log" || status=$?
	fi
	before="$(tree_state)"
	if ((status == 0)) && [[ -n "${CHECK_COMMANDS:-}" && "${CHECK_COMMANDS}" != - ]]; then
		bash -euo pipefail -c "${CHECK_COMMANDS}" 2>&1 | tee -a "${check_log}" || status=$?
	fi
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
