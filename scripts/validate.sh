#!/usr/bin/env bash
# Checks the shared Qodana configuration without uploading anything.
#
#   scripts/validate.sh
#
# 1. Rules of this repository that Qodana's own tools do not enforce (README, "Rules for shared files").
# 2. Every configuration in the catalog is built with Qodana's configuration loader, the tool each scan
#    uses to merge a global configuration, and the flattened result is printed for review.
#
# Needs bash, curl and Java 21 or newer. Set CONFIG_LOADER_JAR to use a local copy of the loader.
set -euo pipefail

# The loader bundled with qodana-cli 2026.3.1. Bump it together with the Qodana version the projects run.
LOADER_VERSION=0.0.38
LOADER_SHA256=785f91349597d7dd6bb5d1c3f5ffc086e728db4b08e5b668f7b7731758d294b2
LOADER_URL="https://packages.jetbrains.team/maven/p/ij/intellij-dependencies/org/jetbrains/qodana/config-loader-cli/${LOADER_VERSION}/config-loader-cli-${LOADER_VERSION}.jar"

CATALOG=qodana-global-configurations.yaml
BASE=base/qodana.yaml

# Top-level keys a shared file may use: the keys of qodana.yaml in qodana-cli 2026.3.1 and in the
# Qodana 2026.3 documentation, minus the four that rule 1 keeps in the repositories.
KNOWN_KEYS=(
  version imports profile include exclude bootstrap plugins properties fixesStrategy failThreshold
  failureConditions script includeAbsent runPromoInspections disableSanityInspections
  failOnErrorNotification maxRuntimeNotifications airGapped projectJDK php dotnet cpp coverage
  hardcodedPasswords mavenSettingsPath onlyDirectory rootJavaProjects licenseRules projectLicenses
  dependencyIgnores dependencyOverrides customDependencies dependencySbomExclude modulesToAnalyze
  analyzeDevDependencies raiseLicenseProblems
)
REPOSITORY_ONLY_KEYS=(linter ide image withinDocker)

cd "$(dirname "$0")/.."

errors=0
error() {
  echo "ERROR: $*" >&2
  errors=$((errors + 1))
}

is_known_key() {
  local known
  for known in "${KNOWN_KEYS[@]}" "${REPOSITORY_ONLY_KEYS[@]}"; do
    [ "$known" = "$1" ] && return 0
  done
  return 1
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# --- 1. Repository rules ----------------------------------------------------------------------------

[ -f "$CATALOG" ] || { echo "ERROR: $CATALOG not found" >&2; exit 1; }
[ -f "$BASE" ] || { echo "ERROR: $BASE not found" >&2; exit 1; }

ids=()
while IFS= read -r id; do
  ids+=("$id")
done < <(sed -nE "s/^[[:space:]]*-?[[:space:]]*id:[[:space:]]*[\"']?([^\"'[:space:]#]+).*/\1/p" "$CATALOG")

stack_files=()
while IFS= read -r file; do
  stack_files+=("$file")
done < <(sed -nE "s/^[[:space:]]*qodanaYaml:[[:space:]]*[\"']?([^\"'[:space:]#]+).*/\1/p" "$CATALOG")

[ "${#ids[@]}" -gt 0 ] || { echo "ERROR: no configuration id found in $CATALOG" >&2; exit 1; }
[ "${#ids[@]}" -eq "${#stack_files[@]}" ] || {
  echo "ERROR: $CATALOG: every configuration needs an id and a qodanaYaml" >&2
  exit 1
}

duplicate_ids="$(printf '%s\n' "${ids[@]}" | sort | uniq -d | tr '\n' ' ')"
[ -z "$duplicate_ids" ] || error "$CATALOG: duplicate id(s): $duplicate_ids"

for file in "$BASE" "${stack_files[@]}"; do
  if [ ! -f "$file" ]; then
    error "$file: listed in $CATALOG but missing"
    continue
  fi

  # Rule 1. The linter and the Docker or native mode are chosen in each repository, before any merge.
  # In a shared file these keys select nothing, and a shared linter or ide stops the scan of every
  # repository whose own qodana.yaml does not repeat it.
  if grep -nE '^(linter|ide|image|withinDocker)[[:space:]]*:' "$file"; then
    error "$file: linter, ide, image and withinDocker belong in each repository, not in a shared file"
  fi

  # Rule 2. The uploader accepts any key, but the linter stops with "Unexpected keys in qodana.yaml" on
  # one it does not know, in every connected project. This catches a mistyped key before it is uploaded.
  while IFS= read -r key; do
    is_known_key "$key" || error "$file: unknown top-level key '$key'"
  done < <(sed -nE 's/^([A-Za-z][A-Za-z0-9_-]*)[[:space:]]*:.*/\1/p' "$file")

  # An imports key that is not a list is dropped without any message, and the base with it.
  if grep -nE '^imports[[:space:]]*:[[:space:]]*[^[:space:]#[]' "$file"; then
    error "$file: imports must be a YAML list"
  fi
done

for file in "${stack_files[@]}"; do
  [ -f "$file" ] || continue
  if ! grep -qE '^([[:space:]]*-[[:space:]]*|imports[[:space:]]*:[[:space:]]*\[.*)\.\./base/qodana\.yaml' "$file"; then
    error "$file: must import ../base/qodana.yaml"
  fi
done

# --- 2. Build every configuration with Qodana's loader --------------------------------------------

command -v java >/dev/null 2>&1 || { echo "ERROR: java not found (Java 21 or newer is needed)" >&2; exit 1; }

jar="${CONFIG_LOADER_JAR:-}"
if [ -z "$jar" ]; then
  cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/qodana-config-loader"
  jar="$cache_dir/config-loader-cli-${LOADER_VERSION}.jar"
  if [ ! -f "$jar" ]; then
    mkdir -p "$cache_dir"
    echo "Downloading config-loader-cli ${LOADER_VERSION}"
    curl -fsSL --retry 3 -o "$jar.part" "$LOADER_URL"
    mv "$jar.part" "$jar"
  fi
fi
actual_sha256="$(sha256_of "$jar")"
if [ "$actual_sha256" != "$LOADER_SHA256" ]; then
  echo "ERROR: $jar has checksum $actual_sha256, expected $LOADER_SHA256" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

for id in "${ids[@]}"; do
  out_dir="$work_dir/$id"
  mkdir -p "$out_dir"
  echo
  echo "===== $id"
  # With these variables set the loader would contact Qodana Cloud; the check is meant to run offline.
  if ! (
    unset QODANA_TOKEN QODANA_ORGANIZATION_ID
    java --enable-native-access=ALL-UNNAMED -jar "$jar" \
      --effective-config-out-dir "$out_dir" \
      --global-configs-file "$PWD/$CATALOG" \
      --global-config-id "$id"
  ) >"$out_dir/loader.log" 2>&1; then
    cat "$out_dir/loader.log" >&2
    hint=""
    if grep -q 'must not be null' "$out_dir/loader.log"; then
      hint=": a key has an empty value"
    fi
    error "$id: the loader could not build this configuration$hint (its output is above)"
    continue
  fi

  effective="$out_dir/effective.qodana.yaml"
  if [ ! -f "$effective" ]; then
    cat "$out_dir/loader.log" >&2
    error "$id: the loader wrote no configuration"
    continue
  fi
  awk 1 "$effective" # like cat, but ends the output with a newline even when the file does not

  # A profile is selected with profile.name only. Through imports, name and path (or base) would both
  # stay in the uploaded file.
  selectors="$(awk '
    /^profile:/ { in_profile = 1; next }
    /^[^[:space:]#]/ { in_profile = 0 }
    in_profile && /^  (name|path|base):/ { count++ }
    END { print count + 0 }
  ' "$effective")"
  if [ "$selectors" -gt 1 ]; then
    error "$id: profile has more than one of name, path and base; shared files select a profile with profile.name only"
  fi
done

echo
if [ "$errors" -gt 0 ]; then
  echo "FAILED: $errors problem(s)" >&2
  exit 1
fi
echo "OK: ${#ids[@]} configuration(s) are valid"
