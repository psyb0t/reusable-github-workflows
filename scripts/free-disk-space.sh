#!/usr/bin/env bash
set -euo pipefail

readonly GITHUB_HOSTED_RUNNER='github-hosted'
readonly LINUX_RUNNER='Linux'
readonly ANDROID_DIRECTORY='/usr/local/lib/android'
readonly DOTNET_DIRECTORY='/usr/share/dotnet'
readonly HASKELL_DIRECTORY='/opt/ghc'
readonly GHCUP_DIRECTORY='/usr/local/.ghcup'
readonly LOG_FILE="${LOG_FILE:-${RUNNER_TEMP:-/tmp}/free-disk-space.log}"
readonly -a LARGE_PACKAGE_PATTERNS=(
	'^aspnetcore-.*'
	'^dotnet-.*'
	'^llvm-.*'
	'php.*'
	'^mongodb-.*'
	'^mysql-.*'
	'azure-cli'
	'google-chrome-stable'
	'firefox'
	'powershell'
	'mono-devel'
	'libgl1-mesa-dri'
	'google-cloud-sdk'
	'google-cloud-cli'
)

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

available_kilobytes() {
	df -Pk / | awk 'NR == 2 {print $4}'
}

run_optional_cleanup() {
	local action=$1
	shift

	if "$@"; then
		log DEBUG "cleanup action complete action=${action}"
		return
	fi
	log WARN "cleanup action failed, continuing action=${action}"
}

exec > >(tee -a "${LOG_FILE}") 2>&1

require_env RUNNER_ENVIRONMENT
require_env RUNNER_OS
if [[ "${RUNNER_ENVIRONMENT}" != "${GITHUB_HOSTED_RUNNER}" ]]; then
	log ERROR "free disk cleanup is restricted to GitHub hosted runners runner_environment=${RUNNER_ENVIRONMENT}"
	exit 1
fi
if [[ "${RUNNER_OS}" != "${LINUX_RUNNER}" ]]; then
	log ERROR "free disk cleanup is restricted to Linux runners runner_os=${RUNNER_OS}"
	exit 1
fi

before_kilobytes=$(available_kilobytes)
log INFO "starting GitHub hosted runner cleanup available_kilobytes=${before_kilobytes}"

run_optional_cleanup android sudo rm -rf -- "${ANDROID_DIRECTORY}"
run_optional_cleanup dotnet sudo rm -rf -- "${DOTNET_DIRECTORY}"
run_optional_cleanup haskell_ghc sudo rm -rf -- "${HASKELL_DIRECTORY}"
run_optional_cleanup haskell_ghcup sudo rm -rf -- "${GHCUP_DIRECTORY}"
run_optional_cleanup packages sudo apt-get remove -y --fix-missing "${LARGE_PACKAGE_PATTERNS[@]}"
run_optional_cleanup packages_autoremove sudo apt-get autoremove -y
run_optional_cleanup packages_clean sudo apt-get clean
run_optional_cleanup docker_images sudo docker image prune --all --force

after_kilobytes=$(available_kilobytes)
freed_kilobytes=$((after_kilobytes - before_kilobytes))
log INFO "GitHub hosted runner cleanup complete available_kilobytes=${after_kilobytes} freed_kilobytes=${freed_kilobytes}"
