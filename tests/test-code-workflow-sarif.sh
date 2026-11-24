#!/usr/bin/env bash
# Run: bash tests/test-code-workflow-sarif.sh
# Needs bash, awk and jq. No token or network access.
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
validation="$(awk '
	/^[[:space:]]+- name: Validate SARIF categories$/ { in_step = 1 }
	in_step && /^        run: \|$/ { in_script = 1; next }
	in_script && /^          / { print substr($0, 11); next }
	in_script { exit }
' "${repo}/.github/workflows/code-workflow.yml")"
[[ -n "${validation}" ]]
report_file="$(mktemp)"
trap 'rm -- "${report_file}"' EXIT

check() {
	local expected="$1"
	local report="$2"
	local status=0

	printf '%s\n' "${report}" >"${report_file}"
	SARIF_FILE="${report_file}" SARIF_CATEGORY=go/ bash -c "${validation}" || status=$?
	if [[ "${status}" != "${expected}" ]]; then
		printf 'SARIF validation exited %s, expected %s\n' "${status}" "${expected}" >&2
		return 1
	fi
}

report() {
	jq -cn --args '
		{version: "2.1.0", runs: [$ARGS.positional[] | fromjson]}
	' "$@"
}

gitleaks='{"tool":{"driver":{"name":"gitleaks"}}}'
worktree='{"tool":{"driver":{"name":"gitleaks"}},"automationDetails":{"id":"go/gitleaks-worktree/"}}'
history='{"tool":{"driver":{"name":"gitleaks"}},"automationDetails":{"id":"go/gitleaks-history/"}}'
semgrep='{"tool":{"driver":{"name":"Semgrep OSS"}}}'
explicit_go='{"tool":{"driver":{"name":"gitleaks"}},"automationDetails":{"id":"go/run-1"}}'
another_go='{"tool":{"driver":{"name":"gitleaks"}},"automationDetails":{"id":"go/run-2"}}'

check 0 "$(report "${gitleaks}" "${semgrep}")"
check 0 "$(report "${worktree}" "${history}" "${semgrep}")"
check 1 "$(report "${gitleaks}" "${gitleaks}")"
check 1 "$(report "${gitleaks}" "${explicit_go}")"
check 1 "$(report "${explicit_go}" "${another_go}")"
check 1 "$(report)"
check 1 'not-json'
check 1 "$(report "${semgrep}") $(report "${gitleaks}")"
status=0
SARIF_FILE=/dev/null SARIF_CATEGORY=go bash -c "${validation}" || status=$?
[[ "${status}" == 1 ]]
