#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

readonly FORMAT="{{format}}"
readonly STAGING_DIR=$(mktemp -d)
readonly YQ="{{yq}}"
readonly IMAGE_DIR="{{image_dir}}"
readonly BLOBS_DIR="${STAGING_DIR}/blobs"
readonly TARBALL_PATH="{{tarball_path}}"
readonly REPOTAGS=($(cat "{{tags}}"))
readonly INDEX_FILE="${IMAGE_DIR}/index.json"

cp_f_with_mkdir() {
  SRC="$1"
  DST="$2"
  mkdir -p "$(dirname "${DST}")"
  cp -f "${SRC}" "${DST}"
}

MANIFEST_DIGEST=$(${YQ} eval '.manifests[0].digest | sub(":"; "/")' "${INDEX_FILE}" | tr  -d '"')

MANIFESTS_LENGTH=$("${YQ}" eval '.manifests | length' "${INDEX_FILE}")
if [[ "${MANIFESTS_LENGTH}" != 1 ]]; then
  echo >&2 "Expected exactly one manifest in ${INDEX_FILE}"
  exit 1
fi

MEDIA_TYPE=$("${YQ}" eval ".manifests[0].mediaType" "${INDEX_FILE}")

# Check that we know how to generate the output format given the input format.
# We may expand the supported options here in the future, but for now,
if [[ "${FORMAT}" != "docker" && "${FORMAT}" != "oci" ]]; then
  echo >&2 "Unknown format: ${FORMAT}. Only support docker|oci"
  exit 1
fi
if [[ "${FORMAT}" == "oci" && "${MEDIA_TYPE}" != "application/vnd.oci.image.index.v1+json" && "${MEDIA_TYPE}" != "application/vnd.docker.distribution.manifest.v2+json" ]]; then
  echo >&2 "Format oci is only supported for oci_image_index targets but saw ${MEDIA_TYPE}"
  exit 1
fi
if [[ "${FORMAT}" == "docker" && "${MEDIA_TYPE}" != "application/vnd.oci.image.manifest.v1+json" && "${MEDIA_TYPE}" != "application/vnd.docker.distribution.manifest.v2+json" ]]; then
  echo >&2 "Format docker is only supported for oci_image targets but saw ${MEDIA_TYPE}"
  exit 1
fi

if [[ "${FORMAT}" == "oci" ]]; then
  # Handle multi-architecture image indexes.
  # Ideally the toolchains we rely on would output these for us, but they don't seem to.

  echo -n '{"imageLayoutVersion": "1.0.0"}' > "${STAGING_DIR}/oci-layout"

  INDEX_FILE_MANIFEST_DIGEST=$("${YQ}" eval '.manifests[0].digest | sub(":"; "/")' "${INDEX_FILE}" | tr  -d '"')
  INDEX_FILE_MANIFEST_BLOB_PATH="${IMAGE_DIR}/blobs/${INDEX_FILE_MANIFEST_DIGEST}"

  cp_f_with_mkdir "${INDEX_FILE_MANIFEST_BLOB_PATH}" "${BLOBS_DIR}/${INDEX_FILE_MANIFEST_DIGEST}"

  IMAGE_MANIFESTS_DIGESTS=($("${YQ}" '.manifests[] | .digest | sub(":"; "/")' "${INDEX_FILE_MANIFEST_BLOB_PATH}"))

  for IMAGE_MANIFEST_DIGEST in "${IMAGE_MANIFESTS_DIGESTS[@]}"; do
    IMAGE_MANIFEST_BLOB_PATH="${IMAGE_DIR}/blobs/${IMAGE_MANIFEST_DIGEST}"
    cp_f_with_mkdir "${IMAGE_MANIFEST_BLOB_PATH}" "${BLOBS_DIR}/${IMAGE_MANIFEST_DIGEST}"

    CONFIG_DIGEST=$("${YQ}" eval '.config.digest  | sub(":"; "/")' ${IMAGE_MANIFEST_BLOB_PATH})
    CONFIG_BLOB_PATH="${IMAGE_DIR}/blobs/${CONFIG_DIGEST}"
    cp_f_with_mkdir "${CONFIG_BLOB_PATH}" "${BLOBS_DIR}/${CONFIG_DIGEST}"

    LAYER_DIGESTS=$("${YQ}" eval '.layers | map(.digest | sub(":"; "/"))' "${IMAGE_MANIFEST_BLOB_PATH}")
    for LAYER_DIGEST in $("${YQ}" ".[]" <<< $LAYER_DIGESTS); do
      cp_f_with_mkdir "${IMAGE_DIR}/blobs/${LAYER_DIGEST}" ${BLOBS_DIR}/${LAYER_DIGEST}
    done
  done

  # Fill in repo tags as per https://github.com/opencontainers/image-spec/issues/796
  # If there's more than one repo tag, we need to duplicate the manifest entry, so we have one copy per repo tag.
  MANIFEST_COPIES=".manifests"
  if [[ "${#REPOTAGS[@]}" -gt 1 ]]; then
    for i in $(seq 2 "${#REPOTAGS[@]}"); do
      MANIFEST_COPIES="${MANIFEST_COPIES} + .manifests"
    done
  fi
  # Convert:
  # {
  #   "schemaVersion": 2,
  #   "manifests": [
  #     {
  #       "mediaType": "application/vnd.oci.image.index.v1+json",
  #       "size": 668,
  #       "digest": "sha256:41981de3b7207f5260fd94fac77272218518d58a6335d843136d88d91341e3d9"
  #     }
  #   ]
  # }
  # Into:
  # {
  #   "schemaVersion": 2,
  #   "manifests": [
  #     {
  #       "mediaType": "application/vnd.oci.image.index.v1+json",
  #       "size": 668,
  #       "digest": "sha256:41981de3b7207f5260fd94fac77272218518d58a6335d843136d88d91341e3d9",
  #       "annotations": {
  #         "org.opencontainers.image.ref.name": "repo-tag:1"
  #       }
  #     },
  #     {
  #       "mediaType": "application/vnd.oci.image.index.v1+json",
  #       "size": 668,
  #       "digest": "sha256:41981de3b7207f5260fd94fac77272218518d58a6335d843136d88d91341e3d9",
  #       "annotations": {
  #         "org.opencontainers.image.ref.name": "repo-tag:2"
  #       }
  #     }
  #   ]
  # }
  repo_tags="${REPOTAGS[@]}" "${YQ}" -o json eval "(.manifests = ${MANIFEST_COPIES}) *d {\"manifests\": (env(repo_tags) | split \" \" | map {\"annotations\": {\"org.opencontainers.image.ref.name\": .}})}" "${INDEX_FILE}" > "${STAGING_DIR}/index.json"

  tar -C "${STAGING_DIR}" -cf "${TARBALL_PATH}" index.json blobs oci-layout
  exit 0
fi

MANIFEST_BLOB_PATH="${IMAGE_DIR}/blobs/${MANIFEST_DIGEST}"

CONFIG_DIGEST=$(${YQ} eval '.config.digest  | sub(":"; "/")' ${MANIFEST_BLOB_PATH})
CONFIG_BLOB_PATH="${IMAGE_DIR}/blobs/${CONFIG_DIGEST}"

LAYERS=$(${YQ} eval '.layers | map(.digest | sub(":"; "/"))' ${MANIFEST_BLOB_PATH})

cp_f_with_mkdir "${CONFIG_BLOB_PATH}" "${BLOBS_DIR}/${CONFIG_DIGEST}"

for LAYER in $(${YQ} ".[]" <<< $LAYERS); do
  cp_f_with_mkdir "${IMAGE_DIR}/blobs/${LAYER}" "${BLOBS_DIR}/${LAYER}.tar.gz"
done

repo_tags="${REPOTAGS[@]+"${REPOTAGS[@]}"}" \
config="blobs/${CONFIG_DIGEST}" \
layers="${LAYERS}" \
"${YQ}" eval \
        --null-input '.[0] = {"Config": env(config), "RepoTags": "${repo_tags}" | envsubst | split(" ") | map(select(. != "")) , "Layers": env(layers) | map( "blobs/" + . + ".tar.gz") }' \
        --output-format json > "${STAGING_DIR}/manifest.json"

# TODO: https://github.com/bazel-contrib/rules_oci/issues/217
tar -C "${STAGING_DIR}" -cf "${TARBALL_PATH}" --mtime='2000-01-01' manifest.json blobs
