#!/usr/bin/env bash
# Tests for scripts/apify-publish.sh with fake apify and docker binaries.
#
# Run: bash tests/test-apify-publish.sh
# Needs: bash, jq, awk. No token or network access.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPOSITORY_DIR
readonly SCRIPT="${REPOSITORY_DIR}/scripts/apify-publish.sh"
DIGEST="sha256:$(printf 'a%.0s' {1..64})"
readonly DIGEST

failures=0
work_directory="$(mktemp -d)"
readonly work_directory
trap 'rm -r -- "${work_directory}"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	failures=$((failures + 1))
}

pass() {
	printf 'ok: %s\n' "$*"
}

# shellcheck source=scripts/apify-publish.sh
source "${SCRIPT}"

# make_fakes DIR PUSH_FAILURES WAIT_EXIT: writes fake apify and docker. The fake
# apify fails its first PUSH_FAILURES pushes, then prints a build object, and
# "builds wait" exits WAIT_EXIT. Every call is appended to DIR/calls.
make_fakes() {
	local dir=$1 push_failures=$2 wait_exit=$3

	mkdir -p "${dir}/bin"
	printf '0' >"${dir}/pushes"
	cat >"${dir}/bin/apify" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${dir}/calls"
case "\$1" in
push)
	count=\$(( \$(cat "${dir}/pushes") + 1 ))
	printf '%s' "\${count}" >"${dir}/pushes"
	echo "Warning: You are using an old version of Apify CLI." >&2
	if (( count <= ${push_failures} )); then
		echo "network error" >&2
		exit 1
	fi
	printf '{"id":"build123","status":"READY"}\n'
	;;
builds)
	[ "\$2" = wait ] && exit ${wait_exit}
	[ "\$2" = log ] && echo "build log line"
	;;
esac
EOF
	cat >"${dir}/bin/docker" <<EOF
#!/usr/bin/env bash
printf 'docker %s\n' "\$*" >>"${dir}/calls"
printf '{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"${DIGEST}","size":1}\n'
EOF
	chmod +x "${dir}/bin/apify" "${dir}/bin/docker"
}

# make_actor DIR DOCKERFILE_TEXT: writes .actor/actor.json and .actor/Dockerfile.
make_actor() {
	local dir=$1 dockerfile=$2

	mkdir -p "${dir}/.actor"
	printf '{"actorSpecification":1,"name":"test-actor","version":"0.0"}\n' >"${dir}/.actor/actor.json"
	printf '%s\n' "${dockerfile}" >"${dir}/.actor/Dockerfile"
}

# run_main DIR [VAR=VALUE...]: runs the script in a subshell with fakes on PATH.
run_main() {
	local dir=$1
	shift
	(
		export PATH="${dir}/bin:${PATH}"
		export APIFY_TOKEN=apify_api_test_not_a_secret
		export ACTOR_DIR="${dir}" BACKOFF_SECONDS=0 WAIT_SECONDS=5
		export GITHUB_STEP_SUMMARY="${dir}/summary"
		for assignment in "$@"; do
			export "${assignment?}"
		done
		bash "${SCRIPT}"
	) >"${dir}/out" 2>"${dir}/err"
}

test_actor_version() {
	# expect_version EXPLICIT TAG WANT
	expect_version() {
		local got
		if ! got="$(actor_version "$1" "$2")" || [[ "${got}" != "$3" ]]; then
			fail "actor_version '$1' '$2' should give $3, got ${got:-nothing}"
		fi
	}
	expect_version "" v3.7.0 3.7
	expect_version "" 1.12.4-rc.1 1.12
	expect_version 2.0 v3.7.0 2.0
	if actor_version "" main 2>/dev/null; then fail "a branch name must not give a version"; fi
	if actor_version 2 v1.0.0 2>/dev/null; then fail "explicit version must be MAJOR.MINOR"; fi
	pass "actor_version"
}

test_pin_base_image() {
	local dir="${work_directory}/pin" dockerfile
	mkdir -p "${dir}"
	dockerfile="${dir}/Dockerfile"

	# shellcheck disable=SC2016 # a literal Dockerfile build variable
	printf 'FROM --platform=$BUILDPLATFORM psyb0t/app:old@sha256:%064d AS base\nFROM psyb0t/other:1\nRUN echo FROM psyb0t/app\n' 0 >"${dockerfile}"
	pin_base_image "${dockerfile}" psyb0t/app v2.0.0 "${DIGEST}" 2>/dev/null || fail "pin should succeed"
	grep -qxF "FROM --platform=\$BUILDPLATFORM psyb0t/app:v2.0.0@${DIGEST} AS base" "${dockerfile}" ||
		fail "FROM line not pinned: $(head -1 "${dockerfile}")"
	grep -qxF 'FROM psyb0t/other:1' "${dockerfile}" || fail "other FROM line changed"
	grep -qxF 'RUN echo FROM psyb0t/app' "${dockerfile}" || fail "non-FROM line changed"

	printf 'FROM registry.example.com:5000/psyb0t/app\n' >"${dockerfile}"
	pin_base_image "${dockerfile}" registry.example.com:5000/psyb0t/app v1.0.0 "${DIGEST}" 2>/dev/null ||
		fail "an untagged image behind a registry port should pin"
	grep -qxF "FROM registry.example.com:5000/psyb0t/app:v1.0.0@${DIGEST}" "${dockerfile}" ||
		fail "registry port mistaken for a tag: $(cat "${dockerfile}")"

	printf 'FROM psyb0t/apple:1\n' >"${dockerfile}"
	if pin_base_image "${dockerfile}" psyb0t/app v1.0.0 "${DIGEST}" 2>/dev/null; then
		fail "a FROM line for a different image must not match"
	fi
	grep -qxF 'FROM psyb0t/apple:1' "${dockerfile}" || fail "Dockerfile changed after a failed pin"
	pass "pin_base_image"
}

test_publish_success() {
	local dir="${work_directory}/success"
	make_fakes "${dir}" 0 0
	make_actor "${dir}" 'FROM psyb0t/app:v0.0.1'

	run_main "${dir}" RELEASE_TAG=v3.7.0 BASE_IMAGE=psyb0t/app || fail "publish should succeed: $(cat "${dir}/err")"
	grep -q -- "push --dir ${dir} --version 3.7 --build-tag latest --wait-for-finish 0 --force --json" "${dir}/calls" ||
		fail "unexpected push arguments: $(cat "${dir}/calls")"
	grep -qxF 'builds wait build123 --timeout 5' "${dir}/calls" || fail "build not awaited"
	grep -qF 'buildx imagetools inspect psyb0t/app:v3.7.0' "${dir}/calls" || fail "digest not resolved for the release tag"
	grep -qxF "FROM psyb0t/app:v3.7.0@${DIGEST}" "${dir}/.actor/Dockerfile" || fail "base image not pinned"
	grep -qF 'version 3.7 built (build build123, tag latest)' "${dir}/summary" || fail "no step summary"
	pass "publish success"
}

test_push_retries_until_a_build_exists() {
	local dir="${work_directory}/retry"
	make_fakes "${dir}" 2 0
	make_actor "${dir}" 'FROM alpine'

	run_main "${dir}" RELEASE_TAG=v1.0.0 MAX_ATTEMPTS=3 || fail "third push should succeed: $(cat "${dir}/err")"
	[[ "$(cat "${dir}/pushes")" == 3 ]] || fail "expected 3 pushes, got $(cat "${dir}/pushes")"

	dir="${work_directory}/retry-exhausted"
	make_fakes "${dir}" 5 0
	make_actor "${dir}" 'FROM alpine'
	if run_main "${dir}" RELEASE_TAG=v1.0.0 MAX_ATTEMPTS=2; then fail "exhausted retries must fail"; fi
	[[ "$(cat "${dir}/pushes")" == 2 ]] || fail "expected 2 pushes, got $(cat "${dir}/pushes")"
	if grep -q '^builds wait' "${dir}/calls"; then fail "no build to wait for after failed pushes"; fi
	pass "push retries"
}

test_failed_build_fails_without_a_rebuild() {
	local dir="${work_directory}/build-failed"
	make_fakes "${dir}" 0 1
	make_actor "${dir}" 'FROM alpine'

	if run_main "${dir}" RELEASE_TAG=v1.0.0; then fail "a failed build must fail the run"; fi
	[[ "$(cat "${dir}/pushes")" == 1 ]] || fail "a failed build must not be pushed again"
	grep -q 'build log line' "${dir}/err" || fail "build log not shown on failure"
	pass "failed build"
}

test_preconditions() {
	local dir="${work_directory}/pre"
	make_fakes "${dir}" 0 0
	make_actor "${dir}" 'FROM alpine'

	if run_main "${dir}" RELEASE_TAG=v1.0.0 APIFY_TOKEN=; then fail "empty token must fail"; fi
	if run_main "${dir}" RELEASE_TAG=; then fail "no tag and no version must fail"; fi
	run_main "${dir}" RELEASE_TAG= ACTOR_VERSION=0.1 || fail "explicit version without a tag should work"
	if run_main "${dir}" ACTOR_VERSION=0.1 BASE_IMAGE=psyb0t/app; then fail "base image without a tag must fail"; fi
	rm "${dir}/.actor/actor.json"
	if run_main "${dir}" RELEASE_TAG=v1.0.0; then fail "missing actor.json must fail"; fi
	pass "preconditions"
}

test_actor_version
test_pin_base_image
test_publish_success
test_push_retries_until_a_build_exists
test_failed_build_fails_without_a_rebuild
test_preconditions

if ((failures > 0)); then
	printf '%d failure(s)\n' "${failures}" >&2
	exit 1
fi
printf 'all apify-publish tests passed\n'
