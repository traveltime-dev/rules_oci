#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

readonly STAGING_DIR=$(mktemp -d)
readonly YQ="{{yq}}"
readonly TAR="{{tar}}"
readonly IMAGE_DIR="{{image_dir}}"
readonly TARBALL_PATH="{{tarball_path}}"
readonly TAGS_FILE="{{tags}}"

# Write tar manifest in mtree format
# https://man.freebsd.org/cgi/man.cgi?mtree(8)
# so that tar produces a deterministic output.
mtree=$(mktemp)

MANIFEST_DIGEST=$(${YQ} eval '.manifests[0].digest | sub(":"; "/")' "${IMAGE_DIR}/index.json" | tr  -d '"')
MANIFEST_BLOB_PATH="${IMAGE_DIR}/blobs/${MANIFEST_DIGEST}"

CONFIG_DIGEST=$(${YQ} eval '.config.digest  | sub(":"; "/")' ${MANIFEST_BLOB_PATH})
CONFIG_BLOB_PATH="${IMAGE_DIR}/blobs/${CONFIG_DIGEST}"
echo >>"${mtree}" "blobs/${CONFIG_DIGEST} uid=0 gid=0 mode=0755 time=1672560000 type=file content=${CONFIG_BLOB_PATH}"

LAYERS=$(${YQ} eval '.layers | map(.digest | sub(":"; "/"))' ${MANIFEST_BLOB_PATH})
for LAYER in $(${YQ} ".[]" <<< $LAYERS); do 
    echo >>"${mtree}" "blobs/${LAYER}.tar.gz  uid=0 gid=0 mode=0755 time=0 type=file content=${IMAGE_DIR}/blobs/${LAYER}"
done

# Replace newlines (unix or windows line endings) with % character.
# We can't pass newlines to yq due to https://github.com/mikefarah/yq/issues/1430 and
# we can't update YQ at the moment because structure_test depends on a specific version:
# see https://github.com/bazel-contrib/rules_oci/issues/212
repo_tags="$(tr -d '\r' < "${TAGS_FILE}" | tr '\n' '%')" \
config="blobs/${CONFIG_DIGEST}" \
layers="${LAYERS}" \
"${YQ}" eval \
        --null-input '.[0] = {"Config": env(config), "RepoTags": "${repo_tags}" | envsubst | split("%") | map(select(. != "")) , "Layers": env(layers) | map( "blobs/" + . + ".tar.gz") }' \
        --output-format json > "${STAGING_DIR}/manifest.json"

echo >>"${mtree}" "manifest.json uid=0 gid=0 mode=0644 time=1672560000 type=file content=${STAGING_DIR}/manifest.json"

# We've created the manifest, now hand it off to tar to create our final output
"${TAR}" --create --file "${TARBALL_PATH}" "@${mtree}"
