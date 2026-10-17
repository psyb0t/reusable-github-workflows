#!/usr/bin/env bash
# Release step of regen-and-update-repo.yml. Runs in a checkout of the commit
# the regeneration started from, with full history and tags.
#
#   1. Applies the regeneration patch, and stops when the review verdict
#      blocks the release (see check_verdict).
#   2. Reads claudebox's output (CLAUDE_OUT_DIR) as UNTRUSTED input and
#      validates every file. Anything invalid falls back to a deterministic
#      value built from the diff stat and the apidiff report.
#   3. Maps change-kind.txt to a semver bump from the highest vX.Y.Z tag.
#   4. Prepends the changelog entry, bumps VERSION_FILES, commits as
#      github-actions[bot] and creates the annotated tag. Does NOT push.
#
# Writes `tag=` and `version=` to GITHUB_OUTPUT and a summary to
# GITHUB_STEP_SUMMARY.
set -euo pipefail

readonly LOG_FILE="${LOG_FILE:-${RUNNER_TEMP:-/tmp}/regen-release.log}"
readonly SEMVER_TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'
readonly MAX_SUBJECT_CHARS=72
readonly MAX_REASON_CHARS=500
readonly MAX_FALLBACK_API_LINES=30
readonly BOT_NAME='github-actions[bot]'
readonly BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
readonly EM_DASH=$'\xe2\x80\x94'
readonly EN_DASH=$'\xe2\x80\x93'

export LC_ALL=C.UTF-8

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

summary() {
	if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
		printf '%s\n' "$@" >>"${GITHUB_STEP_SUMMARY}"
	fi
}

# Shared checks for anything that ends up in git history.
has_forbidden_text() {
	local text=$1
	[[ "${text}" == *"${EM_DASH}"* || "${text}" == *"${EN_DASH}"* ]] && return 0
	grep -qiE 'co-authored-by|claude-session|claude\.ai/code' <<<"${text}" && return 0
	return 1
}

trim_blank_lines() {
	# Drop leading and trailing blank lines, and carriage returns.
	tr -d '\r' | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}

last_semver_tag() {
	git tag --list 'v*' | grep -E "${SEMVER_TAG_RE}" | sort -V | tail -n 1 || true
}

read_kind() {
	local raw=""
	if [[ -f "${CLAUDE_OUT_DIR}/change-kind.txt" ]]; then
		raw="$(tr -d '[:space:]' <"${CLAUDE_OUT_DIR}/change-kind.txt" | tr '[:upper:]' '[:lower:]')"
	fi
	case "${raw}" in
		fix | feature | breaking) printf '%s' "${raw}" ;;
		*)
			log WARN "change-kind.txt invalid or missing, falling back to fix value=${raw:0:40}"
			printf 'fix'
			;;
	esac
}

read_reason() {
	local reason=""
	if [[ -f "${CLAUDE_OUT_DIR}/bump-reason.txt" ]]; then
		reason="$(tr -d '\r' <"${CLAUDE_OUT_DIR}/bump-reason.txt" | tr '\n' ' ' | head -c "${MAX_REASON_CHARS}")"
	fi
	if [[ -z "${reason// /}" ]] || has_forbidden_text "${reason}"; then
		reason="(no usable reason given)"
	fi
	printf '%s' "${reason}"
}

# Pre-1.0: breaking -> minor, fix/feature -> patch.
# 1.0+:    fix -> patch, feature -> minor, breaking -> major
#          (minor instead when ALLOW_MAJOR is not true).
bump_for() {
	local kind=$1 major=$2
	if ((major == 0)); then
		[[ "${kind}" == "breaking" ]] && printf 'minor' || printf 'patch'
		return 0
	fi
	case "${kind}" in
		fix) printf 'patch' ;;
		feature) printf 'minor' ;;
		breaking) [[ "${ALLOW_MAJOR:-true}" == "true" ]] && printf 'major' || printf 'minor' ;;
	esac
}

next_tag() {
	local last=$1 bump=$2 major minor patch
	IFS=. read -r major minor patch <<<"${last#v}"
	case "${bump}" in
		major) printf 'v%d.0.0' "$((major + 1))" ;;
		minor) printf 'v%d.%d.0' "${major}" "$((minor + 1))" ;;
		patch) printf 'v%d.%d.%d' "${major}" "${minor}" "$((patch + 1))" ;;
	esac
}

validate_changelog() {
	local file="${CLAUDE_OUT_DIR}/changelog.md" text
	[[ -f "${file}" ]] || {
		log WARN "changelog.md missing"
		return 1
	}
	text="$(trim_blank_lines <"${file}")"
	if [[ -z "${text}" ]]; then
		log WARN "changelog.md empty"
		return 1
	fi
	if (($(printf '%s' "${text}" | wc -c) > MAX_CHANGELOG_BYTES)); then
		log WARN "changelog.md over ${MAX_CHANGELOG_BYTES} bytes"
		return 1
	fi
	if has_forbidden_text "${text}"; then
		log WARN "changelog.md has forbidden text (dash, trailer or session URL)"
		return 1
	fi
	# Bullets, or indented continuation lines of a bullet. No headings.
	if grep -vqE '^(- .+|  +.+|)$' <<<"${text}" || ! grep -qE '^- ' <<<"${text}"; then
		log WARN "changelog.md is not bullet lines"
		return 1
	fi
	printf '%s\n' "${text}"
}

validate_subject() {
	local tag=$1 file="${CLAUDE_OUT_DIR}/subject.txt" text full
	[[ -f "${file}" ]] || {
		log WARN "subject.txt missing"
		return 1
	}
	text="$(trim_blank_lines <"${file}")"
	if [[ -z "${text}" || "${text}" == *$'\n'* ]]; then
		log WARN "subject.txt is not exactly one line"
		return 1
	fi
	# Tolerate the model adding the right prefix itself; reject any other version.
	[[ -n "${tag}" ]] && text="${text#"${tag}: "}"
	if [[ "${text}" =~ ^v?[0-9]+\.[0-9]+ ]]; then
		log WARN "subject.txt starts with a different version"
		return 1
	fi
	full="${text}"
	[[ -n "${tag}" ]] && full="${tag}: ${text}"
	if ((${#full} > MAX_SUBJECT_CHARS)); then
		log WARN "subject over ${MAX_SUBJECT_CHARS} chars len=${#full}"
		return 1
	fi
	if has_forbidden_text "${text}"; then
		log WARN "subject.txt has forbidden text"
		return 1
	fi
	printf '%s\n' "${full}"
}

fallback_changelog() {
	local shortstat api_lines
	shortstat="$(git diff --cached --shortstat HEAD | sed -e 's/^ *//')"
	printf -- '- Regenerated the generated code (%s).\n' "${shortstat:-no line changes}"
	if [[ -f "${CONTEXT_DIR}/apidiff.txt" ]]; then
		# apidiff lines look like "- Name: change". Quote the identifier.
		# shellcheck disable=SC2016 # literal backticks for Markdown
		api_lines="$(grep -E '^- [^:]+: ' "${CONTEXT_DIR}/apidiff.txt" |
			head -n "${MAX_FALLBACK_API_LINES}" |
			sed -E 's/^- ([^:]+): (.*)$/- `\1`: \2./' |
			tr -d '\r' | sed -e "s/${EM_DASH}/,/g" -e "s/${EN_DASH}/,/g")" || true
		[[ -n "${api_lines}" ]] && printf '%s\n' "${api_lines}"
	fi
}

prepend_changelog() {
	local tag=$1 entry_file=$2 date heading tmp
	date="$(date -u '+%Y-%m-%d')"
	heading="## ${tag}, ${date}"
	tmp="$(mktemp)"
	if [[ ! -f "${CHANGELOG_PATH}" ]]; then
		printf '# Changelog\n\n' >"${CHANGELOG_PATH}"
	fi
	# Insert before the first "## " heading; append when there is none.
	awk -v heading="${heading}" -v entry="${entry_file}" '
		function emit(   line) {
			print heading
			print ""
			while ((getline line < entry) > 0) print line
			print ""
			done = 1
		}
		!done && /^## / { emit() }
		{ print }
		END { if (!done) { print ""; emit() } }
	' "${CHANGELOG_PATH}" >"${tmp}"
	mv "${tmp}" "${CHANGELOG_PATH}"
}

bump_version_files() {
	local version=$1 file old
	for file in ${VERSION_FILES:-}; do
		if [[ ! -f "${file}" ]]; then
			log ERROR "version file missing file=${file}"
			exit 1
		fi
		old="$(jq -er '.version | strings' "${file}")" || {
			log ERROR "version file has no top-level string .version file=${file}"
			exit 1
		}
		# Edit the one line in place so the file keeps its formatting, then
		# let jq confirm the top-level value really changed.
		sed -i -E "0,/\"version\"[[:space:]]*:[[:space:]]*\"${old//./\\.}\"/s//\"version\": \"${version}\"/" "${file}"
		if [[ "$(jq -r '.version' "${file}")" != "${version}" ]]; then
			log ERROR "version bump did not take file=${file}"
			exit 1
		fi
		log INFO "bumped version file=${file} from=${old} to=${version}"
	done
}

# verdict.txt is "ok" or "block: <reason>". With BLOCK_ON_REVIEW=true a block
# stops the release. A missing or malformed verdict also stops it when the fix
# loop changed code (CONTEXT_DIR/fixes.md exists): a fix nobody reviewed must
# not ship. Without fixes it only warns, like the other fallbacks.
check_verdict() {
	local raw="" reason
	if [[ -f "${CLAUDE_OUT_DIR}/verdict.txt" ]]; then
		raw="$(tr -d '\r' <"${CLAUDE_OUT_DIR}/verdict.txt" | sed -e '/./,$!d' | head -n 1)"
	fi
	case "${raw}" in
		ok | OK | Ok)
			log INFO "review verdict ok"
			return 0
			;;
		block:* | BLOCK:* | Block:*)
			reason="${raw#*:}"
			reason="${reason:0:300}"
			summary "### Release blocked by review" "" "Reason (model output, shown as code): \`${reason//\`/\'}\`"
			if [[ "${BLOCK_ON_REVIEW:-true}" == "true" ]]; then
				echo "::error::Review blocked the release:${reason}"
				exit 1
			fi
			echo "::warning::Review would block the release (block_on_review is off):${reason}"
			return 0
			;;
	esac
	if [[ -f "${CONTEXT_DIR}/fixes.md" && "${BLOCK_ON_REVIEW:-true}" == "true" ]]; then
		echo "::error::No valid review verdict for a release that includes automated fixes"
		exit 1
	fi
	log WARN "verdict.txt missing or invalid value=${raw:0:40}"
	echo "::warning::No valid review verdict; releasing without one"
}

# tag: false. The regenerated code is committed with the description as the
# message body; no version, changelog entry, version file or tag changes.
commit_only() {
	local subject entry_file
	entry_file="$(mktemp)"
	if ! validate_changelog >"${entry_file}"; then
		echo "::warning::claudebox changelog entry rejected; using the deterministic fallback"
		fallback_changelog >"${entry_file}"
	fi
	if ! subject="$(validate_subject "")"; then
		echo "::warning::claudebox subject rejected; using the deterministic fallback"
		subject="regenerate generated code"
	fi

	git config user.name "${BOT_NAME}"
	git config user.email "${BOT_EMAIL}"
	git add --all
	{
		printf '%s\n\n' "${subject}"
		cat "${entry_file}"
	} | git commit --quiet --cleanup=verbatim --file=-

	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf 'tag=\nversion=\n' >>"${GITHUB_OUTPUT}"
	fi
	summary "### Regenerated commit (no tag)" "" "- Subject: \`${subject}\`"
	log INFO "commit prepared without a tag"
	rm -f -- "${entry_file}"
}

main() {
	local last kind reason bump tag version subject entry_file major

	require_env PATCH_FILE
	require_env CLAUDE_OUT_DIR
	require_env CONTEXT_DIR
	require_env CHANGELOG_PATH
	require_env MAX_CHANGELOG_BYTES

	check_verdict

	# The checkout is the branch tip, which may be ahead of the commit regen
	# started from. --3way resolves the patch against its preimage blobs from
	# that commit, so unrelated commits pushed meanwhile do not stop it; a real
	# conflict with them still fails here.
	if [[ -n "${BASE_SHA:-}" && "$(git rev-parse HEAD)" != "${BASE_SHA}" ]]; then
		log INFO "branch moved during regeneration base=${BASE_SHA} head=$(git rev-parse HEAD)"
	fi
	if ! git apply --binary --index --3way "${PATCH_FILE}"; then
		log ERROR "regenerated patch conflicts with commits pushed during the run"
		exit 1
	fi
	if git diff --cached --quiet HEAD; then
		log ERROR "patch applied but produced no changes"
		exit 1
	fi

	if [[ "${TAG_ENABLED:-false}" != "true" ]]; then
		commit_only
		return 0
	fi

	last="$(last_semver_tag)"
	[[ -n "${last}" ]] || last="v0.0.0"
	major="${last#v}"
	major="${major%%.*}"

	kind="$(read_kind)"
	reason="$(read_reason)"
	bump="$(bump_for "${kind}" "${major}")"
	tag="$(next_tag "${last}" "${bump}")"
	version="${tag#v}"

	# Never reuse a version: the tag must exist neither here nor on the remote.
	if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null ||
		git ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null 2>&1; then
		log ERROR "tag already exists tag=${tag}"
		exit 1
	fi

	entry_file="$(mktemp)"
	if ! validate_changelog >"${entry_file}"; then
		echo "::warning::claudebox changelog entry rejected; using the deterministic fallback"
		fallback_changelog >"${entry_file}"
	fi
	if ! subject="$(validate_subject "${tag}")"; then
		echo "::warning::claudebox subject rejected; using the deterministic fallback"
		subject="${tag}: regenerate generated code"
	fi

	prepend_changelog "${tag}" "${entry_file}"
	bump_version_files "${version}"

	git config user.name "${BOT_NAME}"
	git config user.email "${BOT_EMAIL}"
	git add --all
	git commit --quiet --message "${subject}"
	{
		printf '%s\n\n' "${tag}"
		cat "${entry_file}"
	} | git tag --annotate --cleanup=verbatim --file=- "${tag}"

	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf 'tag=%s\nversion=%s\n' "${tag}" "${version}" >>"${GITHUB_OUTPUT}"
	fi
	summary "### Regenerated release ${tag}" "" \
		"- Previous tag: \`${last}\`" \
		"- Change kind: \`${kind}\`" \
		"- Bump: \`${bump}\`" \
		"- Reason (model output, shown as code): \`${reason//\`/\'}\`" \
		"- Subject: \`${subject}\`"
	log INFO "release prepared tag=${tag} kind=${kind} bump=${bump}"
	rm -f -- "${entry_file}"
}

main "$@"
