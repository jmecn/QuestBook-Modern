#!/usr/bin/env bash
# QuestBook-Modern CI — config, release resolution, export, deploy, site build.
# Usage: bash ci/run.sh <command>
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_SCRIPTS="${CI_DIR}/scripts"
QBM_ROOT="$(cd "$CI_DIR/.." && pwd)"

ci_node() {
  node "$CI_SCRIPTS/$1" "${@:2}"
}

# GitHub semver release resolution (git ls-remote; empty ci/build.env pin = latest tag).
github_repo_git_url() {
  local spec="${1:?repo required}"
  if [[ "$spec" == https://* ]]; then
    echo "$spec"
    return 0
  fi
  echo "https://github.com/${spec}.git"
}

_semver_strip() {
  echo "${1#v}"
}

_semver_gt() {
  local a b a1 a2 a3 b1 b2 b3
  a="$(_semver_strip "$1")"
  b="$(_semver_strip "$2")"
  IFS=. read -r a1 a2 a3 <<< "$a"
  IFS=. read -r b1 b2 b3 <<< "$b"
  a1=${a1:-0}
  a2=${a2:-0}
  a3=${a3:-0}
  b1=${b1:-0}
  b2=${b2:-0}
  b3=${b3:-0}
  (( a1 > b1 )) && return 0
  (( a1 < b1 )) && return 1
  (( a2 > b2 )) && return 0
  (( a2 < b2 )) && return 1
  (( a3 > b3 )) && return 0
  return 1
}

resolve_latest_semver_release_tag() {
  local repo_spec="${1:?owner/name or git URL required}"
  local git_url best tag

  git_url="$(github_repo_git_url "$repo_spec")"
  best=""
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    if [[ -z "$best" ]] || _semver_gt "$tag" "$best"; then
      best="$tag"
    fi
  done < <(
    git ls-remote --tags "$git_url" \
      | awk -F/ '{print $NF}' \
      | sed 's/\^{}//' \
      | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$'
  )

  if [[ -z "$best" ]]; then
    echo "error: no semver release tags found on ${git_url}" >&2
    return 1
  fi
  echo "$best"
}

resolve_github_release_ref() {
  local repo_spec="${1:?repo required}"
  local pinned="${2:-}"
  if [[ -n "$pinned" ]]; then
    echo "$pinned"
    return 0
  fi
  resolve_latest_semver_release_tag "$repo_spec"
}

resolve_github_release_version() {
  local ref
  ref="$(resolve_github_release_ref "$@")" || return 1
  echo "${ref#v}"
}

resolve_modpack_tag() {
  resolve_github_release_ref \
    "${MODPACK_REPO:-https://github.com/TerraFirmaGreg-Team/Modpack-Modern.git}" \
    "${MODPACK_TAG:-}"
}

resolve_fqe_tag() {
  resolve_github_release_ref \
    "${FQE_REPO:-jmecn/ftb-quest-export}" \
    "${FQE_TAG:-${FQE_VERSION:-}}"
}

resolve_hmc_tag() {
  resolve_github_release_ref \
    "${HMC_REPO:-3arthqu4ke/headlessmc}" \
    "${HMC_TAG:-${HMC_VERSION:-}}"
}

resolve_site_viewer_tag() {
  resolve_github_release_ref \
    "${SITE_VIEWER_REPO:-jmecn/QuestBook-React}" \
    "${SITE_VIEWER_TAG:-${SITE_VIEWER_VERSION:-}}"
}

resolve_site_viewer_version() {
  resolve_github_release_version \
    "${SITE_VIEWER_REPO:-jmecn/QuestBook-React}" \
    "${SITE_VIEWER_TAG:-${SITE_VIEWER_VERSION:-}}"
}

resolve_fqe_version() {
  resolve_github_release_version \
    "${FQE_REPO:-jmecn/ftb-quest-export}" \
    "${FQE_TAG:-${FQE_VERSION:-}}"
}

resolve_hmc_version() {
  resolve_github_release_version \
    "${HMC_REPO:-3arthqu4ke/headlessmc}" \
    "${HMC_TAG:-${HMC_VERSION:-}}"
}

_normalize_version_ref() {
  echo "${1#v}"
}

resolve_quest_book_modern_commit() {
  local sha
  if ! sha="$(git -C "$QBM_ROOT" rev-parse HEAD 2>/dev/null)"; then
    echo "::error::Could not resolve QuestBook-Modern commit (git rev-parse HEAD)" >&2
    return 1
  fi
  printf '%s' "$sha"
}

resolve_build_version_refs() {
  load_config

  if [[ -z "${MODPACK_TAG:-}" ]]; then
    unset MODPACK_TAG
  fi

  BUILD_REF_MODPACK="$(_normalize_version_ref "$(resolve_modpack_tag)")" || return 1
  BUILD_REF_FQE="$(_normalize_version_ref "$(resolve_fqe_version)")" || return 1
  BUILD_REF_SITE="$(_normalize_version_ref "$(resolve_site_viewer_version)")" || return 1
  BUILD_REF_HMC="$(_normalize_version_ref "$(resolve_hmc_version)")" || return 1
  BUILD_REF_QBM="$(_normalize_version_ref "$(resolve_quest_book_modern_commit)")" || return 1
}

resolve_build_json_url() {
  if [[ -n "${BUILD_JSON_URL:-}" ]]; then
    echo "$BUILD_JSON_URL"
    return 0
  fi
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    echo "https://${GITHUB_REPOSITORY%/*}.github.io/${GITHUB_REPOSITORY#*/}/build.json"
    return 0
  fi
  return 1
}

fetch_recorded_build_json() {
  local dest="${1:?dest path required}"
  local url local_site

  if url="$(resolve_build_json_url 2>/dev/null)"; then
    if curl -fsSL --retry 2 --retry-delay 1 "$url" -o "$dest" 2>/dev/null; then
      echo "Loaded published build.json from ${url}" >&2
      return 0
    fi
    echo "No published build.json at ${url} — first deploy or site not ready" >&2
  fi

  local_site="${QBM_ROOT}/${SITE_OUTPUT_DIR:-site}/build.json"
  if [[ -f "$local_site" ]]; then
    cp "$local_site" "$dest"
    echo "Using local ${local_site}" >&2
    return 0
  fi

  echo '{}' > "$dest"
}

_write_build_versions_json() {
  local out="${1:?output path required}"
  local bundle_id="${BUNDLE_ID:?BUNDLE_ID required}"
  local hash_len="${SITE_RELEASE_HASH_LENGTH:-7}"
  resolve_build_version_refs || return 1
  ci_node write-build-versions.mjs \
    "$BUILD_REF_MODPACK" \
    "$BUILD_REF_FQE" \
    "$BUILD_REF_SITE" \
    "$BUILD_REF_HMC" \
    "$BUILD_REF_QBM" \
    "$bundle_id" \
    "$hash_len" \
    "$out"
}

_kv_from_lines() {
  local key="${1:?key required}"
  local lines="${2:?lines required}"
  printf '%s' "$lines" | grep -E "^${key}=" | tail -1 | cut -d= -f2-
}

_run_check_build_mjs() {
  local build_json="${1:?build.json path required}"
  local bundle_id="${2:?bundle id required}"
  (
    unset GITHUB_OUTPUT
    ci_node check-build-changes.mjs \
      "$build_json" \
      "$bundle_id" \
      "${SITE_RELEASE_HASH_LENGTH:-7}" \
      "$BUILD_REF_MODPACK" \
      "$BUILD_REF_FQE" \
      "$BUILD_REF_SITE" \
      "$BUILD_REF_HMC" \
      "$BUILD_REF_QBM"
  )
}

check_build_changes() {
  local build_json
  build_json="$(mktemp)"
  resolve_build_version_refs || exit 1
  fetch_recorded_build_json "$build_json"

  ci_node check-build-changes.mjs \
    "$build_json" \
    "${BUNDLE_ID:?BUNDLE_ID required — run prepare-check-bundle first}" \
    "${SITE_RELEASE_HASH_LENGTH:-7}" \
    "$BUILD_REF_MODPACK" \
    "$BUILD_REF_FQE" \
    "$BUILD_REF_SITE" \
    "$BUILD_REF_HMC" \
    "$BUILD_REF_QBM"
  rm -f "$build_json"
}

_resolve_expected_release_tag() {
  local tmp release_tag
  tmp="$(mktemp)"
  _write_build_versions_json "$tmp" || return 1
  release_tag="$(ci_node read-release-tag.mjs "$tmp")"
  rm -f "$tmp"
  printf '%s' "$release_tag"
}

_site_release_asset_exists() {
  local release_tag="${1:?release tag required}"
  local asset_name="${SITE_RELEASE_ASSET_NAME:-quest-book-site.tar.gz}"
  gh release view "$release_tag" \
    --repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}" \
    --json assets \
    --jq ".assets[].name" 2>/dev/null | grep -Fxq "$asset_name"
}

_probe_site_release() {
  local release_tag="${1:?release tag required}"
  local asset_name="${SITE_RELEASE_ASSET_NAME:-quest-book-site.tar.gz}"

  if ! command -v gh >/dev/null 2>&1; then
    echo "::warning::gh CLI unavailable — cannot probe site release" >&2
    echo "true"
    return 0
  fi
  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "::warning::GH_TOKEN unset — cannot probe site release" >&2
    echo "true"
    return 0
  fi
  if gh release view "$release_tag" --repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}" >/dev/null 2>&1; then
    if _site_release_asset_exists "$release_tag"; then
      echo "Site release probe hit: ${release_tag} (${asset_name})" >&2
      echo "false"
      return 0
    fi
    echo "Deploy required: release ${release_tag} exists but asset ${asset_name} is missing" >&2
    echo "true"
    return 0
  fi
  echo "Deploy required: site release ${release_tag} not found" >&2
  echo "true"
}

probe_site_release() {
  load_config

  local release_tag="${EXPECTED_RELEASE_TAG:-}"
  local probe_needed

  if [[ -z "$release_tag" ]]; then
    release_tag="$(_resolve_expected_release_tag)" || exit 1
  fi

  probe_needed="$(_probe_site_release "$release_tag")"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "release_tag=${release_tag}"
      echo "release_probe_needed=${probe_needed}"
    } >> "$GITHUB_OUTPUT"
  else
    echo "release_tag=${release_tag}"
    echo "release_probe_needed=${probe_needed}"
  fi
}

finalize_deploy_decision() {
  local deploy_needed=false

  if [[ "${VERSION_DEPLOY_NEEDED:-false}" == "true" ]]; then
    deploy_needed=true
    echo "Deploy required: version or build.json metadata gate" >&2
  elif [[ "${RELEASE_PROBE_NEEDED:-false}" == "true" ]]; then
    deploy_needed=true
    echo "Deploy required: site release missing or incomplete (${EXPECTED_RELEASE_TAG:-})" >&2
  else
    echo "Deploy skipped: versions, build.json metadata, and site release all match" >&2
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "deploy_needed=${deploy_needed}" >> "$GITHUB_OUTPUT"
  else
    echo "deploy_needed=${deploy_needed}"
  fi
}

check_gates() {
  load_config

  local tag="${MODPACK_TAG:-}"
  local build_json mjs_out
  local bundle_id cache_key fingerprint
  local version_export_needed version_deploy_needed expected_release_tag release_probe_needed
  local deploy_needed=false

  if [[ -z "$tag" ]]; then
    tag="$(resolve_modpack_tag)" || exit 1
  fi
  export MODPACK_TAG="$tag"
  bundle_id="$(bundle_id_for_tag "$tag")"
  export BUNDLE_ID="$bundle_id"
  fingerprint="$(export_cache_fingerprint)" || exit 1
  cache_key="$(export_cache_key "$bundle_id" "$fingerprint")"

  build_json="$(mktemp)"
  resolve_build_version_refs || exit 1
  fetch_recorded_build_json "$build_json"
  mjs_out="$(_run_check_build_mjs "$build_json" "$bundle_id")"
  rm -f "$build_json"

  version_export_needed="$(_kv_from_lines export_needed "$mjs_out")"
  version_deploy_needed="$(_kv_from_lines version_deploy_needed "$mjs_out")"
  expected_release_tag="$(_kv_from_lines expected_release_tag "$mjs_out")"

  release_probe_needed="$(_probe_site_release "$expected_release_tag")"

  if [[ "$version_deploy_needed" == "true" || "$release_probe_needed" == "true" || "${FORCE_EXPORT:-}" == "true" ]]; then
    deploy_needed=true
    if [[ "${FORCE_EXPORT:-}" == "true" ]]; then
      echo "Deploy required: force_export" >&2
    elif [[ "$version_deploy_needed" == "true" ]]; then
      echo "Deploy required: version or build.json metadata gate" >&2
    else
      echo "Deploy required: site release missing or incomplete (${expected_release_tag})" >&2
    fi
  else
    echo "Deploy skipped: versions, build.json metadata, and site release all match" >&2
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "bundle_id=${bundle_id}"
      echo "modpack_tag=${tag}"
      echo "export_cache_key=${cache_key}"
      echo "version_export_needed=${version_export_needed}"
      echo "expected_release_tag=${expected_release_tag}"
      echo "deploy_needed=${deploy_needed}"
    } >> "$GITHUB_OUTPUT"
  else
    echo "bundle_id=${bundle_id}"
    echo "modpack_tag=${tag}"
    echo "export_cache_key=${cache_key}"
    echo "version_export_needed=${version_export_needed}"
    echo "expected_release_tag=${expected_release_tag}"
    echo "deploy_needed=${deploy_needed}"
  fi

  echo "check bundle_id=${bundle_id} export_cache_key=${cache_key}" >&2
  echo "version_export_needed=${version_export_needed} deploy_needed=${deploy_needed}" >&2
}

export_cache_fingerprint() {
  resolve_build_version_refs || return 1
  printf '%s:%s' "$BUILD_REF_MODPACK" "$BUILD_REF_FQE" \
    | sha256sum | awk '{print substr($1,1,8)}'
}

export_cache_key() {
  local bundle_id="${1:?bundle_id required}"
  local fingerprint="${2:?fingerprint required}"
  printf '%s-%s-%s' "${EXPORT_CACHE_KEY_PREFIX:-quest-export}" "$bundle_id" "$fingerprint"
}

bundle_id_for_tag() {
  printf 'qb-%s' "${1:?modpack tag required}"
}

_write_bundle_outputs() {
  local tag="${1:?modpack tag required}"
  local label="${2:-bundle}"
  local id cache_key fingerprint

  export MODPACK_TAG="$tag"
  id="$(bundle_id_for_tag "$tag")"
  export BUNDLE_ID="$id"
  fingerprint="$(export_cache_fingerprint)" || exit 1
  cache_key="$(export_cache_key "$id" "$fingerprint")"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "bundle_id=${id}"
      echo "modpack_tag=${tag}"
      echo "export_cache_key=${cache_key}"
    } >> "$GITHUB_OUTPUT"
  fi
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf 'BUNDLE_ID=%s\n' "$id" >> "$GITHUB_ENV"
  fi
  echo "${label} bundle_id=${id} export_cache_key=${cache_key}"
}

prepare_check_bundle() {
  load_config
  local tag="${MODPACK_TAG:-}"

  if [[ -z "$tag" ]]; then
    tag="$(resolve_modpack_tag)" || exit 1
  fi
  _write_bundle_outputs "$tag" "check"
}

finalize_export_decision() {
  local export_needed=false

  if [[ "${VERSION_EXPORT_NEEDED:-false}" == "true" ]]; then
    export_needed=true
    echo "Export required: version gate" >&2
  elif [[ "${EXPORT_CACHE_HIT:-}" != "true" ]]; then
    export_needed=true
    echo "Export required: cache miss (${EXPORT_CACHE_KEY:-<unset>})" >&2
  else
    echo "Export skipped: versions unchanged and export cache hit" >&2
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "export_needed=${export_needed}" >> "$GITHUB_OUTPUT"
  else
    echo "export_needed=${export_needed}"
  fi
}

record_build_versions() {
  local site_dir="${QBM_ROOT}/${SITE_OUTPUT_DIR:-site}"
  local build_json="${BUILD_JSON:-$site_dir/build.json}"
  mkdir -p "$site_dir"
  _write_build_versions_json "$build_json"
  echo "Recorded build versions → ${build_json} (deployed with site)"
  cat "$build_json"
}

publish_site_release() {
  load_config

  local site_dir="${QBM_ROOT}/${SITE_OUTPUT_DIR:-site}"
  local build_json="$site_dir/build.json"
  local asset_name="${SITE_RELEASE_ASSET_NAME:-quest-book-site.tar.gz}"
  local archive="$QBM_ROOT/$asset_name"
  local release_tag notes

  if [[ ! -f "$build_json" ]]; then
    echo "::error::Missing ${build_json} — run record-build-versions first" >&2
    exit 1
  fi

  if [[ ! -f "$site_dir/index.html" ]]; then
    echo "::error::Missing ${site_dir}/index.html — run build-site first" >&2
    exit 1
  fi

  release_tag="$(ci_node read-release-tag.mjs "$build_json")"

  if ! command -v gh >/dev/null 2>&1; then
    echo "::error::gh CLI required to publish site release" >&2
    exit 1
  fi

  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "::error::GH_TOKEN is required to publish site release" >&2
    exit 1
  fi

  echo "::group::Package site release (${release_tag})"
  rm -f "$archive"
  tar -czf "$archive" -C "$site_dir" .
  echo "Created ${archive} ($(du -h "$archive" | awk '{print $1}'))"
  echo "::endgroup::"

  if gh release view "$release_tag" --repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}" >/dev/null 2>&1; then
    if _site_release_asset_exists "$release_tag"; then
      echo "Release ${release_tag} already has ${asset_name} — skipping upload"
      rm -f "$archive"
      return 0
    fi
    echo "::group::Upload missing asset to release ${release_tag}"
    gh release upload "$release_tag" "$archive" \
      --repo "${GITHUB_REPOSITORY}" \
      --clobber
    rm -f "$archive"
    echo "Uploaded ${asset_name} → existing release ${release_tag}"
    echo "::endgroup::"
    return 0
  fi

  notes="$(mktemp)"
  cp "$build_json" "$notes"

  echo "::group::Create GitHub Release ${release_tag}"
  gh release create "$release_tag" "$archive" \
    --repo "${GITHUB_REPOSITORY}" \
    --title "Quest book site ${release_tag}" \
    --notes-file "$notes"
  rm -f "$notes" "$archive"
  echo "Published ${asset_name} → release ${release_tag}"
  echo "::endgroup::"
}

load_config() {
  local env_file="${CI_BUILD_ENV:-$CI_DIR/build.env}"
  if [[ ! -f "$env_file" ]]; then
    echo "::error::Missing CI config: $env_file" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a

  local ws="${GITHUB_WORKSPACE:-$QBM_ROOT}"
  EXPORT_ROOT="${ws}/${EXPORT_ROOT_DIR:-export}"
  EXPORT_QUEST="${EXPORT_ROOT}/${QUEST_SUBDIR:-quest-export}"
  RUNNER_HOME="${RUNNER_HOME:-${HOME:-/home/runner}}"

  export RUNNER_HOME JAVA_VERSION
  export MC_VERSION MC_ASSET_INDEX FORGE_BUILD
  export HMC_REPO HMC_VERSION MODPACK_DIR MODPACK_REPO
  export FQE_REPO FQE_VERSION
  export SITE_VIEWER_REPO SITE_VIEWER_VERSION NODE_VERSION
  export EXPORT_WARMUP_TICKS EXPORT_WORLD_DELAY_TICKS EXPORT_TIMEOUT_SECONDS
  export EXPORT_ROOT EXPORT_QUEST EXPORT_ROOT_DIR QUEST_SUBDIR SITE_OUTPUT_DIR
  export RECIPE_BOOK_BASE_URL FIELD_GUIDE_BASE_URL SITE_BASE_URL
  export EXPORT_ARTIFACT_NAME="${EXPORT_ARTIFACT_NAME:-quest-book}"

  if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
      printf 'RUNNER_HOME=%s\n' "$RUNNER_HOME"
      printf 'JAVA_VERSION=%s\n' "$JAVA_VERSION"
      printf 'MC_VERSION=%s\n' "$MC_VERSION"
      printf 'MC_ASSET_INDEX=%s\n' "$MC_ASSET_INDEX"
      printf 'FORGE_BUILD=%s\n' "$FORGE_BUILD"
      printf 'HMC_REPO=%s\n' "${HMC_REPO:-3arthqu4ke/headlessmc}"
      printf 'HMC_VERSION=%s\n' "${HMC_VERSION:-}"
      printf 'MODPACK_DIR=%s\n' "$MODPACK_DIR"
      printf 'MODPACK_REPO=%s\n' "$MODPACK_REPO"
      printf 'FQE_REPO=%s\n' "${FQE_REPO:-jmecn/ftb-quest-export}"
      printf 'FQE_VERSION=%s\n' "${FQE_VERSION:-}"
      printf 'SITE_VIEWER_REPO=%s\n' "${SITE_VIEWER_REPO:-jmecn/QuestBook-React}"
      printf 'SITE_VIEWER_VERSION=%s\n' "${SITE_VIEWER_VERSION:-}"
      printf 'NODE_VERSION=%s\n' "${NODE_VERSION:-24}"
      printf 'EXPORT_CACHE_KEY_PREFIX=%s\n' "${EXPORT_CACHE_KEY_PREFIX:-quest-export}"
      printf 'SITE_RELEASE_ASSET_NAME=%s\n' "${SITE_RELEASE_ASSET_NAME:-quest-book-site.tar.gz}"
      printf 'SITE_RELEASE_HASH_LENGTH=%s\n' "${SITE_RELEASE_HASH_LENGTH:-7}"
      printf 'EXPORT_WARMUP_TICKS=%s\n' "$EXPORT_WARMUP_TICKS"
      printf 'EXPORT_WORLD_DELAY_TICKS=%s\n' "$EXPORT_WORLD_DELAY_TICKS"
      printf 'EXPORT_TIMEOUT_SECONDS=%s\n' "$EXPORT_TIMEOUT_SECONDS"
      printf 'EXPORT_ROOT_DIR=%s\n' "${EXPORT_ROOT_DIR:-export}"
      printf 'QUEST_SUBDIR=%s\n' "${QUEST_SUBDIR:-quest-export}"
      printf 'EXPORT_ROOT=%s\n' "$EXPORT_ROOT"
      printf 'EXPORT_QUEST=%s\n' "$EXPORT_QUEST"
      printf 'SITE_OUTPUT_DIR=%s\n' "${SITE_OUTPUT_DIR:-site}"
      printf 'RECIPE_BOOK_BASE_URL=%s\n' "${RECIPE_BOOK_BASE_URL:-}"
      printf 'FIELD_GUIDE_BASE_URL=%s\n' "${FIELD_GUIDE_BASE_URL:-}"
      printf 'SITE_BASE_URL=%s\n' "${SITE_BASE_URL:-}"
      printf 'EXPORT_ARTIFACT_NAME=%s\n' "${EXPORT_ARTIFACT_NAME:-quest-book}"
    } >> "$GITHUB_ENV"
  fi
}

print_versions() {
  load_config

  if [[ -z "${MODPACK_TAG:-}" ]]; then
    unset MODPACK_TAG
  fi

  local modpack fqe hmc viewer bundle_id meta_file qbm_commit
  meta_file="$QBM_ROOT/export-meta/bundle-id"
  if [[ -f "$meta_file" ]]; then
    bundle_id="$(tr -d '[:space:]' < "$meta_file")"
    if [[ -z "$bundle_id" ]]; then
      echo "::error::export-meta/bundle-id is empty" >&2
      exit 1
    fi
    modpack="${bundle_id#qb-}"
    echo "bundle from export-meta: ${bundle_id}"
  else
    modpack="${MODPACK_TAG:-$(resolve_modpack_tag)}"
    if [[ -z "$modpack" ]]; then
      echo "::error::Could not resolve Modpack-Modern release tag" >&2
      exit 1
    fi
    bundle_id="$(bundle_id_for_tag "$modpack")"
  fi

  fqe="$(resolve_fqe_tag)" || exit 1
  hmc="$(resolve_hmc_tag)" || exit 1
  viewer="$(resolve_site_viewer_tag)" || exit 1
  qbm_commit="$(resolve_quest_book_modern_commit)" || exit 1

  export MODPACK_TAG="$modpack"
  export BUNDLE_ID="$bundle_id"
  export FQE_TAG="$fqe"
  export HMC_TAG="$hmc"
  export SITE_VIEWER_TAG="$viewer"

  if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
      printf 'MODPACK_TAG=%s\n' "$modpack"
      printf 'FQE_TAG=%s\n' "$fqe"
      printf 'HMC_TAG=%s\n' "$hmc"
      printf 'SITE_VIEWER_TAG=%s\n' "$viewer"
      printf 'FQE_VERSION=%s\n' "$fqe"
      printf 'HMC_VERSION=%s\n' "$hmc"
      printf 'SITE_VIEWER_VERSION=%s\n' "$viewer"
      printf 'BUNDLE_ID=%s\n' "$bundle_id"
      printf 'QUEST_BOOK_MODERN_COMMIT=%s\n' "$qbm_commit"
    } >> "$GITHUB_ENV"
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      printf 'modpack_tag=%s\n' "$modpack"
      printf 'bundle_id=%s\n' "$bundle_id"
    } >> "$GITHUB_OUTPUT"
  fi

  echo "::group::CI resolved versions"
  printf '%s\n' \
    "modpack_tag=${modpack}" \
    "bundle_id=${bundle_id}" \
    "ftb-quest-export=${fqe}" \
    "questbook-react=${viewer}" \
    "quest-book-modern=${qbm_commit}" \
    "minecraft=${MC_VERSION} (assets ${MC_ASSET_INDEX})" \
    "forge_build=${FORGE_BUILD}" \
    "headlessmc=${hmc}"
  echo "::endgroup::"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## Resolved versions"
      echo ""
      echo "| Component | Version |"
      echo "|-----------|---------|"
      echo "| Modpack-Modern | \`${modpack}\` |"
      echo "| Bundle id | \`${bundle_id}\` |"
      echo "| ftb-quest-export | \`${fqe}\` |"
      echo "| QuestBook-React | \`${viewer}\` |"
      echo "| QuestBook-Modern | \`${qbm_commit}\` |"
      echo "| Minecraft / Forge | \`${MC_VERSION}\` / \`${FORGE_BUILD}\` |"
      echo "| HeadlessMC | \`${hmc}\` |"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

checkout_modpack() {
  local mp="${MODPACK_DIR:-$QBM_ROOT/Modpack-Modern}"
  local repo="${MODPACK_REPO:-https://github.com/TerraFirmaGreg-Team/Modpack-Modern.git}"
  local tag

  if [[ -n "${MODPACK_TAG:-}" ]]; then
    tag="$MODPACK_TAG"
    echo "Using MODPACK_TAG override: $tag"
  else
    tag="$(resolve_modpack_tag)"
    if [[ -z "$tag" ]]; then
      echo "::error::No semver release tags found on ${MODPACK_REPO:-Modpack-Modern}" >&2
      exit 1
    fi
    echo "Latest release tag: $tag"
  fi

  cd "$QBM_ROOT"
  if [[ -e "$mp/.git" ]]; then
    local current
    current="$(git -C "$mp" describe --tags --exact-match 2>/dev/null || true)"
    if [[ "$current" == "$tag" ]]; then
      echo "Modpack-Modern already at $tag"
    else
      echo "Replacing $mp (was ${current:-unknown}) with shallow clone @ $tag ..."
      rm -rf "$mp"
      git clone --depth 1 --branch "$tag" "$repo" "$mp"
    fi
  else
    echo "Shallow cloning Modpack-Modern @ $tag into $mp ..."
    git clone --depth 1 --branch "$tag" "$repo" "$mp"
  fi

  cd "$mp"
  git describe --tags --exact-match 2>/dev/null || git describe --tags --always

  export MODPACK_TAG="$tag"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "modpack_tag=$tag" >> "$GITHUB_OUTPUT"
  fi
}

prepare_export() {
  load_config
  checkout_modpack
  prepare_bundle_id
  print_versions
  echo "Modpack-Modern @ ${MODPACK_TAG} → bundle_id=qb-${MODPACK_TAG}"
}

prepare_bundle_id() {
  _write_bundle_outputs "${MODPACK_TAG:?MODPACK_TAG required}" "export"
}

export_languages() {
  local lang_cfg="$QBM_ROOT/language.json"
  if [[ ! -f "$lang_cfg" ]]; then
    echo "::error::Missing $lang_cfg" >&2
    exit 1
  fi

  local csv
  csv="$(node -e "
const fs=require('fs');
const cfg=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
const arr=Array.isArray(cfg.enabledLocales)?cfg.enabledLocales:[];
const norm=[...new Set(arr.map(s=>String(s||'').trim().toLowerCase().replace(/-/g,'_')).filter(Boolean))];
process.stdout.write((norm.length?norm:['en_us','zh_cn']).join(','));
" "$lang_cfg")"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "export_languages<<EOF"
      echo "$csv"
      echo "EOF"
    } >> "$GITHUB_OUTPUT"
  fi
  echo "Export languages (language.json): ${csv}"
}

install_gh_release_jar() {
  local repo=$1 tag=$2 jar_prefix=$3
  shift 3
  local extra_patterns=("$@")

  local ver="${tag#v}"
  local jar_name="${jar_prefix}-${ver}.jar"
  local mp="${MODPACK_DIR:-$QBM_ROOT/Modpack-Modern}"

  cd "$QBM_ROOT"
  rm -f "${jar_prefix}-"*.jar
  gh release download "$tag" --repo "$repo" --pattern "$jar_name" --clobber

  mkdir -p "$mp/mods"
  find "$mp/mods" -maxdepth 1 -name "${jar_prefix}*.jar" -delete
  for pat in "${extra_patterns[@]}"; do
    find "$mp/mods" -maxdepth 1 -name "$pat" -delete
  done

  local jar
  jar=$(ls "${jar_prefix}-"*.jar | head -1)
  if [[ -z "$jar" ]]; then
    echo "::error::No ${jar_prefix} jar from ${repo}@${tag}" >&2
    exit 1
  fi
  cp -v "$jar" "$mp/mods/"
}

install_export_mods() {
  local fqe_tag
  fqe_tag="$(resolve_fqe_tag)" || exit 1
  echo "Installing ftb-quest-export ${fqe_tag}"

  install_gh_release_jar "${FQE_REPO:-jmecn/ftb-quest-export}" "$fqe_tag" ftb-quest-export \
    'ftb-quest-forge*.jar' 'ftbquest*.jar' 'minecraft-web-export*.jar'
}

install_display_deps() {
  if command -v xvfb-run >/dev/null 2>&1; then
    return 0
  fi
  sudo DEBIAN_FRONTEND=noninteractive apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    xvfb x11-xserver-utils \
    libgl1 libgl1-mesa-dri \
    libopenal1
}

prepare_game() {
  install_display_deps
  install_export_mods
  setup_hmc
}

setup_hmc() {
  local hmc_ver mc_ver forge mp mp_abs launcher

  hmc_ver="$(resolve_hmc_tag)" || exit 1
  mc_ver="${MC_VERSION:?MC_VERSION required}"
  forge="${FORGE_BUILD:?FORGE_BUILD required}"
  mp="${MODPACK_DIR:-Modpack-Modern}"
  mp_abs="$(cd "$QBM_ROOT/$mp" && pwd)"
  launcher="headlessmc-launcher-${hmc_ver}.jar"

  cd "$QBM_ROOT"
  if [[ ! -f "$launcher" ]]; then
    gh release download "$hmc_ver" \
      --repo "${HMC_REPO:-3arthqu4ke/headlessmc}" \
      --pattern "$launcher" \
      --clobber
  fi

  mkdir -p HeadlessMC
  cat > HeadlessMC/config.properties <<EOF
hmc.java.versions=$JAVA_HOME/bin/java
hmc.gamedir=$mp_abs
hmc.offline=true
hmc.rethrow.launch.exceptions=true
hmc.exit.on.failed.command=true
EOF

  if [[ ! -f "$HOME/.minecraft/versions/$mc_ver/$mc_ver.json" ]]; then
    java -jar "$launcher" --command "download $mc_ver"
  fi
  if ! ls "$HOME/.minecraft/versions" 2>/dev/null | grep -q "$forge"; then
    java -jar "$launcher" --command "forge $mc_ver --uid $forge"
  fi
}

# Chapter quest icon atlases + global UI atlas (replaces legacy assets/icons/items/).
verify_quest_icon_atlases() {
  local quest="${1:?quest-export root required}"

  if [[ -f "$quest/assets/icons/items/manifest.json" ]] \
      || find "$quest/assets/icons/items" -name '*.png' 2>/dev/null | grep -q .; then
    echo "::error::Legacy per-item icons under $quest/assets/icons/items — re-export with current ftb-quest-export" >&2
    return 1
  fi

  if [[ ! -f "$quest/quests/global-atlas.png" ]]; then
    echo "::error::Missing $quest/quests/global-atlas.png" >&2
    return 1
  fi

  if [[ ! -f "$quest/quests/index.json" ]]; then
    echo "::error::Missing $quest/quests/index.json" >&2
    return 1
  fi

  local chapter_atlas_count
  chapter_atlas_count="$(find "$quest/quests/chapters" -maxdepth 1 -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$chapter_atlas_count" -lt 1 ]]; then
    echo "::error::No chapter icon atlases under $quest/quests/chapters/*.png" >&2
    return 1
  fi

  python3 - "$quest" "$chapter_atlas_count" <<'PY'
import json
import sys
from pathlib import Path

quest = Path(sys.argv[1])
chapter_atlas_count = int(sys.argv[2])

index = json.loads((quest / "quests/index.json").read_text(encoding="utf-8"))
global_atlas = index.get("globalAtlas")
if not global_atlas:
    raise SystemExit("::error::quests/index.json missing globalAtlas")

for key in ("src", "width", "height", "missingIconId", "sprites"):
    if key not in global_atlas:
        raise SystemExit(f"::error::globalAtlas missing {key}")

missing_id = global_atlas["missingIconId"]
if missing_id != "fqe:missing_icon":
    raise SystemExit(f"::error::globalAtlas.missingIconId must be fqe:missing_icon (got: {missing_id})")

sprites = global_atlas["sprites"]
if missing_id not in sprites:
    raise SystemExit(f"::error::globalAtlas.sprites missing {missing_id}")

rect = sprites[missing_id]
if rect.get("w") != 16 or rect.get("h") != 16:
    raise SystemExit(f"::error::{missing_id} must be 16x16 in global atlas index")

atlas_png = quest / global_atlas["src"]
if not atlas_png.is_file():
    raise SystemExit(f"::error::global atlas file missing: {atlas_png}")

chapters = index.get("chapters") or []
if not chapters:
    raise SystemExit("::error::index.json has no chapters")

with_icon = [c for c in chapters if c.get("icon") and (c.get("iconDisplay") or {}).get("spriteId")]
if not with_icon:
    raise SystemExit("::error::index chapters missing iconDisplay for sidebar icons")

sample_filename = with_icon[0]["filename"]
expected_sprite = f"chapter:{sample_filename}"
if with_icon[0]["iconDisplay"]["spriteId"] != expected_sprite:
    raise SystemExit(
        f"::error::chapter iconDisplay.spriteId must be chapter:{{filename}} (got: {with_icon[0]['iconDisplay']['spriteId']})"
    )
if expected_sprite not in sprites:
    raise SystemExit(f"::error::globalAtlas.sprites missing {expected_sprite}")

chapters_dir = quest / "quests/chapters"
chapter_jsons = sorted(chapters_dir.glob("*.json"))
if not chapter_jsons:
    raise SystemExit(f"::error::No chapter JSON under {chapters_dir}")

sample = json.loads(chapter_jsons[0].read_text(encoding="utf-8"))
for key in ("iconAtlases", "iconSprites"):
    if key not in sample:
        raise SystemExit(f"::error::{chapter_jsons[0].name} missing {key}")

quests = sample.get("quests") or []
if quests and not (quests[0].get("iconDisplay") or {}).get("spriteId"):
    raise SystemExit(f"::error::{chapter_jsons[0].name} quests[0] missing iconDisplay.spriteId")

manifest = json.loads((quest / "manifest.json").read_text(encoding="utf-8"))
cia = manifest.get("chapterIconAtlases") or {}
sprites_packed = int(cia.get("spritesPacked") or 0)
ga = manifest.get("globalAtlas") or {}

print(
    f"quest icons: global-atlas ({len(sprites)} sprites, {len(with_icon)} chapter icons) + "
    f"{chapter_atlas_count} chapter quest atlas PNG(s), {sprites_packed} quest sprites packed"
)
PY
}

verify_quest_export() {
  local quest="${EXPORT_QUEST:?EXPORT_QUEST required}"

  for f in manifest.json meta.json; do
    if [[ ! -f "$quest/$f" ]]; then
      echo "::error::Missing $quest/$f"
      exit 1
    fi
  done

  local exporter
  exporter=$(python3 -c "import json; print(json.load(open('$quest/manifest.json')).get('exporter',''))")
  if [[ "$exporter" != "ftb-quest-export" ]]; then
    echo "::error::manifest.exporter must be ftb-quest-export (got: $exporter)"
    exit 1
  fi

  for d in assets lang quests extras; do
    if [[ ! -d "$quest/$d" ]]; then
      echo "::error::Missing directory $quest/$d"
      exit 1
    fi
  done

  verify_quest_icon_atlases "$quest"

  echo "quest-export OK: $quest"
  du -sh "$quest" "$quest/assets" "$quest/lang" "$quest/quests" "$quest/quests/chapters" 2>/dev/null || true
}

launch_export() {
  local mp hmc_ver launcher

  mp="${MODPACK_DIR:-$QBM_ROOT/Modpack-Modern}"
  hmc_ver="$(resolve_hmc_tag)" || exit 1
  launcher="headlessmc-launcher-${hmc_ver}.jar"

  mkdir -p "$mp/config" "$mp/saves" "${EXPORT_ROOT:?EXPORT_ROOT required}"
  cp -f "$CI_DIR/config/export-fml.toml" "$mp/config/fml.toml"
  cp -f "$CI_DIR/config/export-forge-client.toml" "$mp/config/forge-client.toml"
  cat > "$mp/options.txt" <<EOF
onboardAccessibility:false
pauseOnLostFocus:false
EOF

  cd "$QBM_ROOT"
  xvfb-run --server-args="-screen 0 1280x720x24" -a java \
    -Dhmc.check.xvfb=true \
    -jar "$launcher" \
    --command "launch .*forge.* -regex --jvm \"${FQE_JVM_FLAGS:?FQE_JVM_FLAGS required}\""

  verify_quest_export
}

write_export_meta() {
  local bundle_id="${BUNDLE_ID:?BUNDLE_ID required}"
  local modpack_tag="${MODPACK_TAG:?MODPACK_TAG required}"
  local out="$QBM_ROOT/export-meta"

  mkdir -p "$out"
  printf '%s\n' "$bundle_id" > "$out/bundle-id"
  printf '%s\n' "$modpack_tag" > "$out/modpack-tag"
  echo "Wrote export-meta (bundle_id=$bundle_id modpack_tag=$modpack_tag)"
}

finalize_export() {
  write_export_meta
  local bundle_id="${BUNDLE_ID:?BUNDLE_ID required}"
  local archive="$QBM_ROOT/quest-export-${bundle_id}.tar.gz"

  load_config
  tar -czf "$archive" -C "$EXPORT_ROOT" quest-export
  ls -lh "$archive"
}

collect_export_debug() {
  load_config

  local mp="${MODPACK_DIR:-$QBM_ROOT/Modpack-Modern}"
  local out="$QBM_ROOT/ci-debug"
  local quest="${EXPORT_QUEST:?EXPORT_QUEST required}"

  rm -rf "$out"
  mkdir -p "$out"

  if [[ -d "$mp/logs" ]]; then
    mkdir -p "$out/modpack/logs"
    for f in "$mp/logs"/*; do
      [[ -f "$f" ]] || continue
      local base
      base=$(basename "$f")
      if [[ "$base" == latest.log ]] || [[ $(stat -c%s "$f" 2>/dev/null || stat -f%z "$f") -lt 5242880 ]]; then
        cp -a "$f" "$out/modpack/logs/"
      fi
    done
  fi

  if [[ -d "$mp/crash-reports" ]]; then
    cp -a "$mp/crash-reports" "$out/modpack/"
  fi

  if [[ -f "$quest/manifest.json" ]]; then
    mkdir -p "$out/export/quest-export"
    cp "$quest/manifest.json" "$out/export/quest-export/"
    if [[ -f "$quest/meta.json" ]]; then
      cp "$quest/meta.json" "$out/export/quest-export/"
    fi
    du -sh "$quest" > "$out/export/quest-export-size.txt" 2>/dev/null || true
    find "$quest" -type f 2>/dev/null | head -200 > "$out/export/quest-export-file-sample.txt" || true
  fi

  if [[ -d "$QBM_ROOT/export-meta" ]]; then
    cp -a "$QBM_ROOT/export-meta" "$out/"
  fi

  if [[ -z "$(find "$out" -type f 2>/dev/null | head -1)" ]]; then
    echo "no debug files collected" > "$out/README.txt"
  fi

  echo "debug files under $out:"
  find "$out" -type f | head -50
}

prepare_deploy() {
  load_config
  resolve_bundle_id
}

install_bundle() {
  case "${ACQUIRE:-extract}" in
    extract) extract_bundle ;;
    fetch) fetch_bundle ;;
    *)
      echo "::error::ACQUIRE must be extract or fetch (got: ${ACQUIRE:-})" >&2
      exit 1
      ;;
  esac
}

resolve_bundle_id() {
  local id tag

  if [[ -n "${BUNDLE_ID_INPUT:-}" ]]; then
    id="$BUNDLE_ID_INPUT"
  elif [[ -f "$QBM_ROOT/export-meta/bundle-id" ]]; then
    id="$(tr -d '\r\n' < "$QBM_ROOT/export-meta/bundle-id")"
  elif [[ -n "${MODPACK_TAG:-}" ]]; then
    id="$(bundle_id_for_tag "$MODPACK_TAG")"
  else
    load_config
    if [[ -z "${MODPACK_TAG:-}" ]]; then
      unset MODPACK_TAG
    fi
    tag="$(resolve_modpack_tag)"
    if [[ -z "$tag" ]]; then
      echo "::error::Could not resolve modpack tag for bundle id" >&2
      exit 1
    fi
    id="$(bundle_id_for_tag "$tag")"
    export MODPACK_TAG="$tag"
  fi

  export BUNDLE_ID="$id"

  local fingerprint cache_key
  fingerprint="$(export_cache_fingerprint)" || exit 1
  cache_key="$(export_cache_key "$id" "$fingerprint")"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "bundle_id=${id}"
      echo "export_cache_key=${cache_key}"
    } >> "$GITHUB_OUTPUT"
  fi
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf 'BUNDLE_ID=%s\n' "$id" >> "$GITHUB_ENV"
  fi
  echo "deploy bundle_id=${id} export_cache_key=${cache_key}"
}

extract_bundle() {
  local bundle_id="${BUNDLE_ID:?BUNDLE_ID required}"
  local archive="$QBM_ROOT/quest-export-${bundle_id}.tar.gz"

  load_config

  if [[ ! -f "$archive" ]]; then
    echo "::error::Missing ${archive} after artifact download" >&2
    ls -la "$QBM_ROOT" >&2
    exit 1
  fi

  rm -rf "$EXPORT_ROOT"
  mkdir -p "$EXPORT_ROOT"
  tar -xzf "$archive" -C "$EXPORT_ROOT"
  rm -f "$archive"

  verify_quest_export
  echo "Extracted export bundle to ${EXPORT_ROOT}"
}

fetch_bundle() {
  local bundle_id="${BUNDLE_ID:?BUNDLE_ID required}"

  load_config

  if [[ -f "${EXPORT_ROOT}/quest-export/manifest.json" ]]; then
    echo "Export bundle already at ${EXPORT_ROOT}"
    verify_quest_export
    return 0
  fi

  if ! command -v gh >/dev/null 2>&1; then
    echo "::error::gh CLI required to download artifact ${EXPORT_ARTIFACT_NAME}" >&2
    exit 1
  fi

  local artifact_name="${EXPORT_ARTIFACT_NAME:-quest-book}"
  local workflow_name="${EXPORT_WORKFLOW_NAME:-Export quests}"

  local run_id
  run_id="$(
    gh run list \
      --repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}" \
      --workflow "$workflow_name" \
      --branch "${GITHUB_REF_NAME:-main}" \
      --status success \
      --limit 1 \
      --json databaseId \
      -q '.[0].databaseId'
  )"

  if [[ -z "$run_id" ]]; then
    echo "::error::No successful「${workflow_name}」run on branch ${GITHUB_REF_NAME:-main}" >&2
    exit 1
  fi

  rm -f "$QBM_ROOT/quest-export-${bundle_id}.tar.gz"
  gh run download "$run_id" --repo "$GITHUB_REPOSITORY" -n "$artifact_name" -D "$QBM_ROOT"
  extract_bundle
  echo "Installed export from run ${run_id} (artifact ${artifact_name})"
}

fetch_quest_site_release() {
  local repo="${SITE_VIEWER_REPO:-jmecn/QuestBook-React}"
  local site_dir="${SITE_OUTPUT_DIR:?SITE_OUTPUT_DIR required}"
  local version tag

  version="$(resolve_site_viewer_tag)" || return 1
  if [[ "$version" == v* ]]; then
    tag="$version"
  else
    tag="v${version}"
  fi
  echo "QuestBook-React site @ ${tag}"

  if ! command -v gh >/dev/null 2>&1; then
    echo "::error::gh CLI required to download viewer site from ${repo} ${tag}" >&2
    return 1
  fi

  local staging archive
  staging="$(mktemp -d)"
  archive="quest-book-site-v${version#v}.tar.gz"

  echo "::group::Fetch quest site ${tag} (${repo})"
  if ! ( cd "$staging" && gh release download "$tag" --repo "$repo" --pattern "$archive" --clobber ); then
    rm -rf "$staging"
    echo "::error::gh release download failed for ${repo} ${tag} pattern ${archive}" >&2
    return 1
  fi

  if [[ ! -f "$staging/$archive" ]]; then
    rm -rf "$staging"
    echo "::error::Release asset ${archive} not found on ${repo} tag ${tag}" >&2
    return 1
  fi

  mkdir -p "$site_dir"
  find "$site_dir" -mindepth 1 -maxdepth 1 ! -name data -exec rm -rf {} +
  tar -xzf "$staging/$archive" -C "$site_dir"

  if [[ ! -f "$site_dir/index.html" ]]; then
    rm -rf "$staging"
    echo "::error::Extracted site missing index.html (layout=dist-root expected)" >&2
    return 1
  fi

  echo "Quest site installed at ${site_dir} (${archive})"
  echo "::endgroup::"
  rm -rf "$staging"
}

stage_quest_export() {
  local export_src="${EXPORT_QUEST:?EXPORT_QUEST required}"
  local site_dir="${SITE_OUTPUT_DIR:?SITE_OUTPUT_DIR required}"
  local dest="${site_dir}/data/quest-export"

  if [[ ! -f "$export_src/manifest.json" ]]; then
    echo "::error::Missing $export_src/manifest.json — install export bundle first" >&2
    return 1
  fi

  rm -rf "$dest"
  mkdir -p "$site_dir/data"
  cp -a "$export_src" "$dest"
  echo "Staged quest-export at ${dest}"
}

write_site_config() {
  local site_dir="${SITE_OUTPUT_DIR:?SITE_OUTPUT_DIR required}"
  local site_url="${SITE_BASE_URL:-}"
  local recipe_url="${RECIPE_BOOK_BASE_URL:-}"
  local guide_url="${FIELD_GUIDE_BASE_URL:-}"

  cat > "$site_dir/site-config.json" <<EOF
{
  "siteBaseUrl": "${site_url}",
  "recipeBookBaseUrl": "${recipe_url}",
  "fieldGuideBaseUrl": "${guide_url}"
}
EOF
  echo "Wrote site-config.json (siteBaseUrl=${site_url:-<empty>} recipeBookBaseUrl=${recipe_url:-<empty>} fieldGuideBaseUrl=${guide_url:-<empty>})"
}

verify_staged_quest_icons() {
  local site_dir="${SITE_OUTPUT_DIR:?SITE_OUTPUT_DIR required}"
  local quest="$site_dir/data/quest-export"

  if [[ ! -f "$quest/manifest.json" ]]; then
    echo "::error::Missing $quest/manifest.json — stage quest-export first" >&2
    return 1
  fi

  verify_quest_icon_atlases "$quest"
}

assemble_deploy_site() {
  local site_dir="${SITE_OUTPUT_DIR:?SITE_OUTPUT_DIR required}"

  cp -f "$QBM_ROOT/language.json" "$site_dir/language.json"
  write_site_config
  stage_quest_export
  verify_staged_quest_icons

  if ! compgen -G "$site_dir/assets/*.js" > /dev/null; then
    echo "::error::Missing $site_dir/assets/*.js — quest site release may be corrupt" >&2
    return 1
  fi

  echo "Deploy site ready at ${site_dir} (viewer: $(resolve_site_viewer_tag))"
}

build_site() {
  load_config
  fetch_quest_site_release
  assemble_deploy_site
}

usage() {
  cat <<'EOF'
Usage: bash ci/run.sh <command>

Workflow composites:
  check-gates, prepare-check-bundle, finalize-export-decision,
  prepare-export, prepare-game, finalize-export,
  prepare-deploy, extract-bundle, build-site,
  record-build-versions, publish-site-release

Granular (local debugging):
  env, print-versions, checkout-modpack, prepare-bundle-id, export-languages,
  install-mods, setup-hmc, launch-export, write-export-meta,
  resolve-bundle-id, extract-bundle, fetch-bundle,
  fetch-quest-site, verify-staged-quest-icons, assemble-deploy-site,
  check-build-changes, probe-site-release, finalize-deploy-decision,
  collect-export-debug
EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    usage >&2
    exit 1
  fi
  shift

  case "$cmd" in
    env) load_config "$@" ;;
    print-versions) print_versions "$@" ;;
    check-gates) check_gates "$@" ;;
    prepare-check-bundle) prepare_check_bundle "$@" ;;
    check-build-changes) check_build_changes "$@" ;;
    finalize-export-decision) finalize_export_decision "$@" ;;
    probe-site-release) probe_site_release "$@" ;;
    finalize-deploy-decision) finalize_deploy_decision "$@" ;;
    record-build-versions) record_build_versions "$@" ;;
    publish-site-release) publish_site_release "$@" ;;
    prepare-export) prepare_export "$@" ;;
    prepare-game) prepare_game "$@" ;;
    finalize-export) finalize_export "$@" ;;
    prepare-deploy) prepare_deploy "$@" ;;
    install-bundle) install_bundle "$@" ;;
    checkout-modpack) checkout_modpack "$@" ;;
    prepare-bundle-id) prepare_bundle_id "$@" ;;
    export-languages) export_languages "$@" ;;
    install-mods) install_export_mods "$@" ;;
    setup-hmc) setup_hmc "$@" ;;
    launch-export) launch_export "$@" ;;
    write-export-meta) write_export_meta "$@" ;;
    resolve-bundle-id) resolve_bundle_id "$@" ;;
    extract-bundle) extract_bundle "$@" ;;
    fetch-bundle) fetch_bundle "$@" ;;
    fetch-quest-site)
      load_config
      fetch_quest_site_release "$@"
      ;;
    verify-staged-quest-icons|optimize-quest-icons)
      load_config
      verify_staged_quest_icons "$@"
      ;;
    assemble-deploy-site)
      load_config
      assemble_deploy_site "$@"
      ;;
    build-site) build_site "$@" ;;
    collect-export-debug) collect_export_debug "$@" ;;
    -h|--help|help) usage ;;
    *)
      echo "::error::Unknown command: $cmd" >&2
      usage >&2
      exit 1
      ;;
  esac
fi
