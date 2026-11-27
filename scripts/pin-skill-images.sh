#!/usr/bin/env bash
# Pins the caller's own Docker images in skill files before they are published.
#
# Usage: pin-skill-images.sh TAG IMAGES_JSON SKILL_DIR...
#
# Every bare reference to an image in IMAGES_JSON ("owner/name" or
# "owner/name:latest") in the files under each SKILL_DIR becomes
# "owner/name:TAG@sha256:...", with the digest Docker Hub reports for TAG.
# A reference that already names a tag or digest, or that is part of a URL or
# a longer name, is left alone. The repository keeps its unpinned references;
# only the files about to be published change.
#
# With SOURCE_REPO set to "owner/repo", raw GitHub URLs of that repository on
# main, master or HEAD are pinned to TAG as well, so an install script the skill
# links to is the one from the release.
#
# Environment:
#   SOURCE_REPO        owner/repo whose raw GitHub URLs to pin (default: none)
#   DOCKERHUB_API_URL  Docker Hub API base (default https://hub.docker.com/v2)
#   MAX_ATTEMPTS       Digest lookup attempts per image (default 5)
#   BACKOFF_SECONDS    First retry delay, doubled after each failure (default 2)
set -euo pipefail

readonly IMAGE_PATTERN='^[a-z0-9]+([._-][a-z0-9]+)*/[a-z0-9]+([._-][a-z0-9]+)*$'
readonly TAG_PATTERN='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
readonly DIGEST_PATTERN='^sha256:[0-9a-f]{64}$'
readonly REPO_PATTERN='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'

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

if [ "$#" -lt 3 ]; then
	log ERROR 'usage: pin-skill-images.sh TAG IMAGES_JSON SKILL_DIR...'
	exit 2
fi

tag=$1
images_json=$2
shift 2
api_url="${DOCKERHUB_API_URL:-https://hub.docker.com/v2}"
max_attempts="${MAX_ATTEMPTS:-5}"
backoff_seconds="${BACKOFF_SECONDS:-2}"

if ! [[ "${tag}" =~ ${TAG_PATTERN} ]]; then
	log ERROR "tag ${tag} is not a valid Docker tag"
	exit 1
fi
if ! [[ "${max_attempts}" =~ ^[1-9][0-9]?$ ]] || ! [[ "${backoff_seconds}" =~ ^[0-9]{1,3}$ ]]; then
	log ERROR 'MAX_ATTEMPTS must be 1 to 99 and BACKOFF_SECONDS 0 to 999'
	exit 1
fi
if ! jq -e 'type == "array"' <<<"${images_json}" >/dev/null 2>&1; then
	log ERROR 'IMAGES_JSON must be a JSON array of owner/name image names'
	exit 1
fi
source_repo="${SOURCE_REPO:-}"
if [ -n "${source_repo}" ] && ! [[ "${source_repo}" =~ ${REPO_PATTERN} ]]; then
	log ERROR "SOURCE_REPO ${source_repo} is not owner/repo"
	exit 1
fi
for dir in "$@"; do
	if [ ! -d "${dir}" ]; then
		log ERROR "skill directory ${dir} does not exist"
		exit 1
	fi
done

# digest prints the digest Docker Hub reports for image:tag.
digest() {
	local image=$1 namespace=${1%%/*} name=${1#*/} attempt=1 delay="${backoff_seconds}" response value
	while :; do
		if response="$(curl -fsS --connect-timeout 10 --max-time 30 \
			"${api_url%/}/namespaces/${namespace}/repositories/${name}/tags/${tag}")" &&
			value="$(jq -er '.digest // empty' <<<"${response}")" &&
			[[ "${value}" =~ ${DIGEST_PATTERN} ]]; then
			printf '%s\n' "${value}"
			return 0
		fi
		if [ "${attempt}" -ge "${max_attempts}" ]; then
			log ERROR "Docker Hub has no digest for ${image}:${tag} after ${attempt} attempt(s); publish the image before the skill"
			return 1
		fi
		log WARN "digest lookup for ${image}:${tag} failed (attempt ${attempt}/${max_attempts}); retrying in ${delay}s"
		sleep "${delay}"
		attempt=$((attempt + 1))
		delay=$((delay * 2))
	done
}

replacements='{}'
while IFS= read -r image; do
	if ! [[ "${image}" =~ ${IMAGE_PATTERN} ]]; then
		log ERROR "image ${image} is not an owner/name Docker Hub image"
		exit 1
	fi
	value="$(digest "${image}")"
	replacements="$(jq -c --arg image "${image}" --arg pinned "${image}:${tag}@${value}" '. + {($image): $pinned}' <<<"${replacements}")"
	log INFO "pinning ${image} to ${image}:${tag}@${value}"
done < <(jq -r '.[]' <<<"${images_json}")

if [ "${replacements}" = '{}' ] && [ -z "${source_repo}" ]; then
	log INFO 'nothing to pin'
	exit 0
fi

python3 - "${replacements}" "${source_repo}" "${tag}" "$@" <<'PYTHON'
import json
import pathlib
import re
import sys

replacements = json.loads(sys.argv[1])
source_repo, tag = sys.argv[2], sys.argv[3]
source_patterns = []
if source_repo:
    repo = re.escape(source_repo)
    source_patterns = [
        (re.compile(r"https://raw\.githubusercontent\.com/" + repo + r"/(?:main|master|HEAD)/"),
         f"https://raw.githubusercontent.com/{source_repo}/{tag}/"),
        (re.compile(r"https://github\.com/" + repo + r"/raw/(?:main|master|HEAD)/"),
         f"https://github.com/{source_repo}/raw/{tag}/"),
    ]
changed = 0
for directory in sys.argv[4:]:
    for path in sorted(pathlib.Path(directory).rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        updated = text
        for image, pinned in replacements.items():
            pattern = re.compile(r"(?<![\w./@-])" + re.escape(image) + r"(?::latest)?(?![\w.:/@-])")
            updated = pattern.sub(pinned, updated)
        for pattern, pinned_url in source_patterns:
            updated = pattern.sub(pinned_url, updated)
        if updated != text:
            path.write_text(updated, encoding="utf-8")
            changed += 1
            print(json.dumps({"level": "INFO", "msg": f"pinned images in {path}"}), file=sys.stderr)
print(json.dumps({"level": "INFO", "msg": f"pinned images in {changed} file(s)"}), file=sys.stderr)
PYTHON
