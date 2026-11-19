#!/usr/bin/env bash
# Tests for scripts/regen-report-recovery.sh with a fake gh.
#
# Run: bash tests/test-regen-report-recovery.sh
# Needs: bash, jq. No token or network access.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPOSITORY_DIR
readonly SCRIPT="${REPOSITORY_DIR}/scripts/regen-report-recovery.sh"
readonly PREFIX='https://github.com/o/r/actions/runs/'
readonly ISSUE_TITLE='Scheduled regeneration failed'
readonly BOT='github-actions[bot]'
readonly FAILED='The scheduled regeneration failed in this run: '
readonly CURRENT_RUN=500

failures=0
work_directory="$(mktemp -d)"
readonly work_directory
trap 'rm -r -- "${work_directory}"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	failures=$((failures + 1))
}

# issue NUMBER TITLE LOGIN BODY [PULL]: one issue object.
issue() {
	jq -cn --argjson n "$1" --arg t "$2" --arg u "$3" --arg b "$4" --arg pr "${5:-}" \
		'{number: $n, title: $t, user: {login: $u}, body: $b} + (if $pr == "" then {} else {pull_request: {}} end)'
}

# comment LOGIN BODY: one comment object.
comment() {
	jq -cn --arg u "$1" --arg b "$2" '{user: {login: $u}, body: $b}'
}

# setup DIR: writes the fake gh. Issues come from DIR/issues.json (a slurped
# page list) and comments for issue N from DIR/comments-N.json. Closes are
# appended to DIR/closed.
setup() {
	local dir=$1
	mkdir -p "${dir}/bin"
	cat >"${dir}/bin/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = api ]; then
	path="\${@: -1}"
	case "\${path}" in
	*/comments*)
		number="\$(sed -E 's#.*/issues/([0-9]+)/comments.*#\1#' <<<"\${path}")"
		cat "${dir}/comments-\${number}.json" 2>/dev/null || echo '[[]]'
		;;
	*) cat "${dir}/issues.json" ;;
	esac
elif [ "\$1" = issue ] && [ "\$2" = close ]; then
	printf '%s %s\n' "\$3" "\${@: -1}" >>"${dir}/closed"
fi
EOF
	chmod +x "${dir}/bin/gh"
	: >"${dir}/closed"
}

run() {
	local dir=$1
	GH_BIN="${dir}/bin/gh" GH_REPO=o/r RUN_ID="${CURRENT_RUN}" RUN_PREFIX="${PREFIX}" TITLE="${ISSUE_TITLE}" \
		bash "${SCRIPT}" 2>"${dir}/err"
}

dir="${work_directory}/cases"
setup "${dir}"
{
	printf '[['
	issue 1 "${ISSUE_TITLE}" "${BOT}" "${FAILED}${PREFIX}400
details"
	printf ','
	issue 2 "${ISSUE_TITLE}" "${BOT}" "${FAILED}${PREFIX}400"
	printf ','
	issue 3 "${ISSUE_TITLE}" "someone" "${FAILED}${PREFIX}100"
	printf ','
	issue 4 "Other title" "${BOT}" "${FAILED}${PREFIX}100"
	printf ','
	issue 5 "${ISSUE_TITLE}" "${BOT}" "${FAILED}${PREFIX}100" pr
	printf ','
	issue 6 "${ISSUE_TITLE}" "${BOT}" "Unrelated text"
	printf ','
	issue 7 "${ISSUE_TITLE}" "${BOT}" "${FAILED}https://example.com/elsewhere/9"
	printf ']]'
} >"${dir}/issues.json"
# Issue 2 has a newer failure (600) in a bot comment, and a forged human one.
{
	printf '[['
	comment "${BOT}" "${FAILED}${PREFIX}450"
	printf ','
	comment "${BOT}" "${FAILED}${PREFIX}600"
	printf ']]'
} >"${dir}/comments-2.json"
{
	printf '[['
	comment "someone" "${FAILED}${PREFIX}900"
	printf ']]'
} >"${dir}/comments-1.json"

run "${dir}" || fail "script failed: $(cat "${dir}/err")"
closed="$(cat "${dir}/closed")"
[[ "${closed}" == "1 Regeneration and validation recovered: ${PREFIX}${CURRENT_RUN}" ]] ||
	fail "only issue 1 should close, got: ${closed:-nothing}"

# No open issues: nothing to do, still succeeds.
dir="${work_directory}/empty"
setup "${dir}"
printf '[[]]' >"${dir}/issues.json"
run "${dir}" || fail "no issues should succeed"
[[ ! -s "${dir}/closed" ]] || fail "nothing should close"

# A failure from this very run is cleared (equal IDs), a later one is not.
dir="${work_directory}/equal"
setup "${dir}"
printf '[[%s]]' "$(issue 8 "${ISSUE_TITLE}" "${BOT}" "${FAILED}${PREFIX}${CURRENT_RUN}")" >"${dir}/issues.json"
run "${dir}" || fail "equal run ID case failed"
grep -q '^8 ' "${dir}/closed" || fail "issue reporting this run's ID should close"

# Both report formats preserve newer failure comments.
dir="${work_directory}/new-format"
setup "${dir}"
readonly NEW_FAILED='Regeneration or validation failed in this run: '
printf '[[%s,%s]]' \
	"$(issue 9 "${ISSUE_TITLE}" "${BOT}" "${NEW_FAILED}${PREFIX}400")" \
	"$(issue 10 "${ISSUE_TITLE}" "${BOT}" "${FAILED}${PREFIX}400")" >"${dir}/issues.json"
printf '[[%s]]' "$(comment "${BOT}" "${NEW_FAILED}${PREFIX}600")" >"${dir}/comments-10.json"
run "${dir}" || fail "new report format failed"
if [[ ! -s "${dir}/closed" ]] || ! grep -q '^9 ' "${dir}/closed"; then
	fail "new report format must close"
fi
if [[ -s "${dir}/closed" ]] && grep -q '^10 ' "${dir}/closed"; then
	fail "new-format comment reporting a newer failure must stay open"
fi

# Missing environment fails.
if GH_BIN="${dir}/bin/gh" GH_REPO=o/r RUN_ID='' RUN_PREFIX="${PREFIX}" TITLE="${ISSUE_TITLE}" bash "${SCRIPT}" 2>/dev/null; then
	fail "empty RUN_ID must fail"
fi

if ((failures > 0)); then
	printf '%d failure(s)\n' "${failures}" >&2
	exit 1
fi
printf 'all regen-report-recovery tests passed\n'
