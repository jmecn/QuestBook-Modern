#!/usr/bin/env bash
# QuestBook-Modern CI — config, release resolution, export, deploy, site build.
# Usage: bash ci/run.sh <command>
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QBM_ROOT="$(cd "$CI_DIR/.." && pwd)"

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

resolve_mwe_tag() {
  resolve_github_release_ref \
    "${MWE_REPO:-jmecn/minecraft-web-export}" \
    "${MWE_TAG:-${MWE_VERSION:-}}"
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
  export FQE_REPO FQE_VERSION MWE_REPO MWE_VERSION
  export SITE_VIEWER_REPO SITE_VIEWER_VERSION NODE_VERSION
  export EXPORT_WARMUP_TICKS EXPORT_WORLD_DELAY_TICKS EXPORT_TIMEOUT_SECONDS
  export EXPORT_ROOT EXPORT_QUEST EXPORT_ROOT_DIR QUEST_SUBDIR SITE_OUTPUT_DIR RECIPE_BOOK_BASE_URL
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
      printf 'MWE_REPO=%s\n' "${MWE_REPO:-jmecn/minecraft-web-export}"
      printf 'MWE_VERSION=%s\n' "${MWE_VERSION:-}"
      printf 'SITE_VIEWER_REPO=%s\n' "${SITE_VIEWER_REPO:-jmecn/QuestBook-React}"
      printf 'SITE_VIEWER_VERSION=%s\n' "${SITE_VIEWER_VERSION:-}"
      printf 'NODE_VERSION=%s\n' "${NODE_VERSION:-24}"
      printf 'EXPORT_WARMUP_TICKS=%s\n' "$EXPORT_WARMUP_TICKS"
      printf 'EXPORT_WORLD_DELAY_TICKS=%s\n' "$EXPORT_WORLD_DELAY_TICKS"
      printf 'EXPORT_TIMEOUT_SECONDS=%s\n' "$EXPORT_TIMEOUT_SECONDS"
      printf 'EXPORT_ROOT_DIR=%s\n' "${EXPORT_ROOT_DIR:-export}"
      printf 'QUEST_SUBDIR=%s\n' "${QUEST_SUBDIR:-quest-export}"
      printf 'EXPORT_ROOT=%s\n' "$EXPORT_ROOT"
      printf 'EXPORT_QUEST=%s\n' "$EXPORT_QUEST"
      printf 'SITE_OUTPUT_DIR=%s\n' "${SITE_OUTPUT_DIR:-site}"
      printf 'RECIPE_BOOK_BASE_URL=%s\n' "${RECIPE_BOOK_BASE_URL:-}"
      printf 'EXPORT_ARTIFACT_NAME=%s\n' "${EXPORT_ARTIFACT_NAME:-quest-book}"
    } >> "$GITHUB_ENV"
  fi
}

print_versions() {
  load_config

  if [[ -z "${MODPACK_TAG:-}" ]]; then
    unset MODPACK_TAG
  fi

  local modpack fqe mwe hmc viewer
  modpack="${MODPACK_TAG:-$(resolve_modpack_tag)}"
  if [[ -z "$modpack" ]]; then
    echo "::error::Could not resolve Modpack-Modern release tag" >&2
    exit 1
  fi

  fqe="$(resolve_fqe_tag)" || exit 1
  mwe="$(resolve_mwe_tag)" || exit 1
  hmc="$(resolve_hmc_tag)" || exit 1
  viewer="$(resolve_site_viewer_tag)" || exit 1

  export MODPACK_TAG="$modpack"
  export FQE_TAG="$fqe"
  export MWE_TAG="$mwe"
  export HMC_TAG="$hmc"
  export SITE_VIEWER_TAG="$viewer"

  if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
      printf 'MODPACK_TAG=%s\n' "$modpack"
      printf 'FQE_TAG=%s\n' "$fqe"
      printf 'MWE_TAG=%s\n' "$mwe"
      printf 'HMC_TAG=%s\n' "$hmc"
      printf 'SITE_VIEWER_TAG=%s\n' "$viewer"
      printf 'FQE_VERSION=%s\n' "$fqe"
      printf 'MWE_VERSION=%s\n' "$mwe"
      printf 'HMC_VERSION=%s\n' "$hmc"
      printf 'SITE_VIEWER_VERSION=%s\n' "$viewer"
    } >> "$GITHUB_ENV"
  fi

  echo "::group::CI resolved versions"
  printf '%s\n' \
    "modpack_tag=${modpack}" \
    "ftb-quest-export=${fqe}" \
    "minecraft-web-export=${mwe}" \
    "questbook-react=${viewer}" \
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
      echo "| ftb-quest-export | \`${fqe}\` |"
      echo "| minecraft-web-export | \`${mwe}\` |"
      echo "| QuestBook-React | \`${viewer}\` |"
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
  local tag="${MODPACK_TAG:?MODPACK_TAG required}"
  local id="qb-${tag}"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "bundle_id=${id}"
      echo "modpack_tag=${tag}"
    } >> "$GITHUB_OUTPUT"
  fi
  echo "bundle_id=${id} (modpack @ ${tag})"
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
  local fqe_tag mwe_tag
  fqe_tag="$(resolve_fqe_tag)" || exit 1
  mwe_tag="$(resolve_mwe_tag)" || exit 1
  echo "Installing ftb-quest-export ${fqe_tag}, minecraft-web-export ${mwe_tag}"

  install_gh_release_jar "${FQE_REPO:-jmecn/ftb-quest-export}" "$fqe_tag" ftb-quest-export \
    'ftb-quest-forge*.jar' 'ftbquest*.jar'
  install_gh_release_jar "${MWE_REPO:-jmecn/minecraft-web-export}" "$mwe_tag" minecraft-web-export
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

  if [[ ! -d "$quest/data" ]]; then
    echo "::warning::Missing optional $quest/data (texture-only closure)"
  fi

  if [[ ! -d "$quest/assets/icons" ]]; then
    echo "::error::Missing $quest/assets/icons — install minecraft-web-export and re-export"
    exit 1
  fi

  for icon_file in icons.css index.json; do
    if [[ ! -f "$quest/assets/icons/$icon_file" ]]; then
      echo "::error::Missing $quest/assets/icons/$icon_file"
      exit 1
    fi
  done

  if ! grep -qF -- '--atlas-w:' "$quest/assets/icons/icons.css"; then
    echo "::error::icons.css missing sprite CSS variables (--atlas-w)"
    exit 1
  fi

  echo "quest-export OK: $quest"
  du -sh "$quest" "$quest/assets" "$quest/data" "$quest/lang" "$quest/quests" "$quest/assets/icons" 2>/dev/null || true
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
  local id

  if [[ -n "${BUNDLE_ID_INPUT:-}" ]]; then
    id="$BUNDLE_ID_INPUT"
  elif [[ -f "$QBM_ROOT/export-meta/bundle-id" ]]; then
    id="$(tr -d '\r\n' < "$QBM_ROOT/export-meta/bundle-id")"
  elif [[ -n "${MODPACK_TAG:-}" ]]; then
    id="qb-${MODPACK_TAG}"
  else
    load_config
    MODPACK_TAG="$(resolve_modpack_tag)"
    if [[ -z "$MODPACK_TAG" ]]; then
      echo "::error::Could not resolve modpack tag for bundle id" >&2
      exit 1
    fi
    id="qb-${MODPACK_TAG}"
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "bundle_id=${id}" >> "$GITHUB_OUTPUT"
  fi
  echo "bundle_id=${id}"
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
  local url="${RECIPE_BOOK_BASE_URL:-}"

  cat > "$site_dir/site-config.json" <<EOF
{
  "recipeBookBaseUrl": "${url}"
}
EOF
  echo "Wrote site-config.json (recipeBookBaseUrl=${url:-<empty>})"
}

assemble_deploy_site() {
  local site_dir="${SITE_OUTPUT_DIR:?SITE_OUTPUT_DIR required}"

  cp -f "$QBM_ROOT/language.json" "$site_dir/language.json"
  write_site_config
  stage_quest_export

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
  prepare-export      env + modpack checkout + bundle id + resolve FQE/MWE/HMC tags
  prepare-game        xvfb deps + export mod jars + HeadlessMC
  finalize-export     export-meta + tar (needs BUNDLE_ID, MODPACK_TAG)
  prepare-deploy      env + resolve bundle id
  install-bundle      extract or fetch (ACQUIRE=extract|fetch, BUNDLE_ID)
  build-site            fetch React site + stage quest-export

Granular (local debugging):
  env, print-versions, checkout-modpack, prepare-bundle-id, export-languages,
  install-mods, setup-hmc, launch-export, write-export-meta,
  resolve-bundle-id, extract-bundle, fetch-bundle,
  fetch-quest-site, assemble-deploy-site
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
    assemble-deploy-site)
      load_config
      assemble_deploy_site "$@"
      ;;
    build-site) build_site "$@" ;;
    -h|--help|help) usage ;;
    *)
      echo "::error::Unknown command: $cmd" >&2
      usage >&2
      exit 1
      ;;
  esac
fi
