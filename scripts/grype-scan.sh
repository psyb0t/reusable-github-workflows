#!/usr/bin/env bash
set -euo pipefail

readonly GRYPE_RELEASE_URL='https://github.com/anchore/grype/releases/download'
readonly LOG_FILE="${LOG_FILE:-${RUNNER_TEMP:-/tmp}/grype-scan.log}"
readonly GRYPE_THRESHOLD_EXIT=2

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
	local name=$1
	if [[ -z "${!name:-}" ]]; then
		log ERROR "required environment variable is empty name=${name}"
		exit 1
	fi
}

exec > >(tee -a "${LOG_FILE}") 2>&1

require_env DOCKERHUB_USERNAME
require_env DOCKERHUB_TOKEN
require_env GRYPE_VERSION
require_env GRYPE_SHA256_LINUX_AMD64
require_env GRYPE_SHA256_LINUX_ARM64
require_env IMAGE
require_env OUTPUT_FILE
require_env SCAN_FAIL_BUILD
require_env SCAN_SEVERITY

case "${SCAN_FAIL_BUILD}" in
true | false) ;;
*)
	log ERROR "SCAN_FAIL_BUILD must be true or false"
	exit 1
	;;
esac

case "${SCAN_SEVERITY}" in
negligible | low | medium | high | critical) ;;
*)
	log ERROR "SCAN_SEVERITY is unsupported"
	exit 1
	;;
esac

only_fixed=${ONLY_FIXED:-false}
case "${only_fixed}" in
true | false) ;;
*)
	log ERROR "ONLY_FIXED must be true or false"
	exit 1
	;;
esac

vex_file=${VEX_FILE:-}
if [[ -n "${vex_file}" && (! -f "${vex_file}" || ! -r "${vex_file}") ]]; then
	log ERROR "VEX_FILE is not a readable file"
	exit 1
fi

if [[ -e "${OUTPUT_FILE}" ]]; then
	log ERROR "OUTPUT_FILE must not already exist"
	exit 1
fi

if ! work_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/grype.XXXXXX"); then
	log ERROR "could not create temporary Grype directory"
	exit 1
fi
trap 'rm -r -- "${work_dir}"' EXIT

arch=$(uname -m)
case "${arch}" in
x86_64) grype_arch=amd64 ;;
aarch64) grype_arch=arm64 ;;
*)
	log ERROR "unsupported runner architecture arch=${arch}"
	exit 1
	;;
esac

case "${grype_arch}" in
amd64) expected_sha="${GRYPE_SHA256_LINUX_AMD64}" ;;
arm64) expected_sha="${GRYPE_SHA256_LINUX_ARM64}" ;;
esac

tarball="${work_dir}/grype_${GRYPE_VERSION}_linux_${grype_arch}.tar.gz"
log DEBUG "downloading Grype version=${GRYPE_VERSION} arch=${grype_arch}"
if ! curl -fsSL --retry 3 --retry-all-errors --retry-delay 1 \
	-o "${tarball}" \
	"${GRYPE_RELEASE_URL}/v${GRYPE_VERSION}/grype_${GRYPE_VERSION}_linux_${grype_arch}.tar.gz"; then
	log ERROR "Grype download failed version=${GRYPE_VERSION} arch=${grype_arch}"
	exit 1
fi
if ! printf '%s  %s\n' "${expected_sha}" "${tarball}" | sha256sum -c -; then
	log ERROR "Grype checksum verification failed version=${GRYPE_VERSION} arch=${grype_arch}"
	exit 1
fi
if ! tar -xzf "${tarball}" -C "${work_dir}" grype; then
	log ERROR "Grype extraction failed version=${GRYPE_VERSION} arch=${grype_arch}"
	exit 1
fi
grype_bin="${work_dir}/grype"
if [[ ! -x "${grype_bin}" ]]; then
	log ERROR "Grype binary was not extracted"
	exit 1
fi

log DEBUG "authenticating Docker Hub image=${IMAGE}"
if ! printf '%s' "${DOCKERHUB_TOKEN}" |
	docker login --username "${DOCKERHUB_USERNAME}" --password-stdin >/dev/null; then
	log ERROR "Docker Hub login failed image=${IMAGE}"
	exit 1
fi

grype_args=("${grype_bin}" "${IMAGE}" --output "sarif=${OUTPUT_FILE}")
if [[ "${only_fixed}" == true ]]; then
	grype_args+=(--only-fixed)
fi
if [[ -n "${vex_file}" ]]; then
	grype_args+=(--vex "${vex_file}")
fi
if [[ "${SCAN_FAIL_BUILD}" == true ]]; then
	grype_args+=(--fail-on "${SCAN_SEVERITY}")
fi

log INFO "scanning image=${IMAGE}"
set +e
"${grype_args[@]}"
scan_status=$?
set -e

if [[ ! -s "${OUTPUT_FILE}" ]]; then
	log ERROR "Grype did not produce SARIF output"
	exit 1
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	printf 'sarif=%s\n' "${OUTPUT_FILE}" >>"${GITHUB_OUTPUT}"
fi

if [[ "${scan_status}" -eq 0 ]]; then
	log INFO "image scan complete outcome=clean"
	exit 0
fi
if [[ "${scan_status}" -eq "${GRYPE_THRESHOLD_EXIT}" && "${SCAN_FAIL_BUILD}" == true ]]; then
	log WARN "image scan threshold reached severity=${SCAN_SEVERITY}"
	exit "${scan_status}"
fi

log ERROR "image scan failed exit=${scan_status}"
exit "${scan_status}"
