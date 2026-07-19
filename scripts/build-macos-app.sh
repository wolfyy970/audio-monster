#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
package_dir="${repo_root}/apps/macos"
requested_configuration="${1:-release}"
signing_identity="${AUDIO_MONSTER_SIGNING_IDENTITY:--}"
provisioning_profile="${AUDIO_MONSTER_PROVISIONING_PROFILE:-}"
entitlements_template="${package_dir}/Resources/AudioMonster.entitlements"

case "${requested_configuration}" in
  debug) configuration="Debug" ;;
  release) configuration="Release" ;;
  *)
    print -u2 "Usage: $0 [debug|release]"
    exit 2
    ;;
esac

derived_data="${package_dir}/.build/xcode-derived"
products_dir="${derived_data}/Build/Products/${configuration}"
app_dir="${repo_root}/dist/Audio Monster.app"
installed_executable="${app_dir}/Contents/MacOS/AudioMonster"
portable_source_root="/AudioMonster"
clang_prefix_maps="-ffile-prefix-map=${repo_root}=${portable_source_root} -fmacro-prefix-map=${repo_root}=${portable_source_root} -fdebug-prefix-map=${repo_root}=${portable_source_root}"

# Replacing a bundle while that exact executable is still running can leave the
# new signature in an indeterminate state when the old process finally exits.
# Require an explicit quit instead of silently producing a damaged release.
if [[ -x "${installed_executable}" ]] \
  && [[ -n "$(lsof -t "${installed_executable}" 2>/dev/null)" ]]; then
  print -u2 "Audio Monster is running from ${app_dir}. Quit it before rebuilding."
  exit 1
fi

# Products from an older dependency graph must never be swept into a fresh app.
# Keep Xcode's intermediates and package checkout cache, but force it to recreate
# the complete configuration-specific Products directory before packaging.
if [[ -d "${products_dir}" ]]; then
  rm -rf -- "${products_dir}"
fi

(
  cd "${package_dir}"
  xcodebuild \
    -scheme AudioMonster \
    -destination "platform=macOS,arch=arm64" \
    -configuration "${configuration}" \
    -derivedDataPath "${derived_data}" \
    -skipPackagePluginValidation \
    build \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_CODE_COVERAGE=NO \
    OTHER_CFLAGS="${clang_prefix_maps}" \
    OTHER_CPLUSPLUSFLAGS="${clang_prefix_maps}"
)

binary="${products_dir}/AudioMonster"
if [[ ! -x "${binary}" ]]; then
  print -u2 "Xcode did not produce ${binary}."
  exit 1
fi

contents_dir="${app_dir}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"

if [[ -e "${app_dir}" ]]; then
  rm -rf "${app_dir}"
fi

mkdir -p "${macos_dir}" "${resources_dir}"
cp "${binary}" "${macos_dir}/AudioMonster"
# Swift package schemes can retain coverage/local symbols in an otherwise optimized
# product. They are not useful in the distributable app and may contain build paths.
strip -x "${macos_dir}/AudioMonster"
cp "${package_dir}/Resources/Info.plist" "${contents_dir}/Info.plist"
cp "${package_dir}/Resources/AudioMonsterMenuBarTemplate.png" "${resources_dir}/"
cp "${package_dir}/Resources/AudioMonsterMenuBarTemplate@2x.png" "${resources_dir}/"

# SwiftPM resource accessors look in the app's Resources directory first.
resource_bundles=("${products_dir}"/*.bundle(N))
for bundle in "${resource_bundles[@]}"; do
  ditto "${bundle}" "${resources_dir}/${bundle:t}"
done

readability_assets=(
  "${resources_dir}"/*.bundle/Contents/Resources/Readability/Readability.js(N)
)
snapshot_assets=(
  "${resources_dir}"/*.bundle/Contents/Resources/Extraction/Snapshot.js(N)
)
metal_libraries=(
  "${resources_dir}"/*.bundle/Contents/Resources/default.metallib(N)
)
if (( ${#readability_assets[@]} != 1 )); then
  print -u2 "The app bundle is missing its pinned Mozilla Readability resource."
  exit 1
fi
if (( ${#snapshot_assets[@]} != 1 )); then
  print -u2 "The app bundle is missing its extraction Snapshot.js resource."
  exit 1
fi
if (( ${#metal_libraries[@]} != 1 )) || [[ ! -s "${metal_libraries[1]}" ]]; then
  print -u2 "The app bundle is missing its compiled MLX Metal library."
  exit 1
fi

readability_metadata="${package_dir}/Sources/AudioMonster/Resources/Readability/UPSTREAM.md"
expected_readability_sha="$({
  sed -nE 's/^- Source SHA-256: `([0-9a-f]{64})`$/\1/p' "${readability_metadata}"
})"
if ! print -r -- "${expected_readability_sha}" | grep -Eq '^[0-9a-f]{64}$'; then
  print -u2 "Could not read the pinned Readability SHA-256 from ${readability_metadata}."
  exit 1
fi

packaged_readability_sha="$(shasum -a 256 "${readability_assets[1]}" | awk '{print $1}')"
if [[ "${packaged_readability_sha}" != "${expected_readability_sha}" ]]; then
  print -u2 "The packaged Mozilla Readability resource does not match its pinned SHA-256."
  exit 1
fi

if [[ "${signing_identity}" == "-" ]]; then
  # Ad-hoc signing keeps the zero-setup development build available. Restricted
  # iCloud entitlements are intentionally omitted because no profile authorizes
  # them in this mode.
  codesign --force --deep --sign - "${app_dir}" >/dev/null
else
  if [[ -z "${provisioning_profile}" || ! -f "${provisioning_profile}" ]]; then
    print -u2 "AUDIO_MONSTER_PROVISIONING_PROFILE must name a readable Developer ID profile."
    exit 1
  fi
  if [[ ! -f "${entitlements_template}" ]]; then
    print -u2 "The signed build is missing ${entitlements_template}."
    exit 1
  fi

  profile_plist="$(mktemp)"
  resolved_entitlements="$(mktemp)"
  cleanup_signing_files() {
    rm -f -- "${profile_plist}" "${resolved_entitlements}"
  }
  trap cleanup_signing_files EXIT

  security cms -D -i "${provisioning_profile}" > "${profile_plist}"
  profile_team_id="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "${profile_plist}")"
  if [[ -z "${profile_team_id}" ]]; then
    print -u2 "The provisioning profile does not contain an Apple Developer Team ID."
    exit 1
  fi

  expected_container="${profile_team_id}.iCloud.org.audiomonster.AudioMonster"
  profile_containers="$(/usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.developer.ubiquity-container-identifiers' \
    "${profile_plist}")"
  if ! print -r -- "${profile_containers}" | grep -Fq "${expected_container}" \
    && ! print -r -- "${profile_containers}" | grep -Fq "${profile_team_id}.*"; then
      print -u2 "The provisioning profile does not authorize ${expected_container}."
      exit 1
  fi

  cp "${entitlements_template}" "${resolved_entitlements}"
  /usr/libexec/PlistBuddy \
    -c "Set :com.apple.developer.ubiquity-container-identifiers:0 ${expected_container}" \
    "${resolved_entitlements}"

  cp "${provisioning_profile}" "${contents_dir}/embedded.provisionprofile"
  # Sign the application bundle in one pass. Pre-signing the main executable
  # creates a second entitlement-free signature that can leave the final
  # entitlement blob unreadable by macOS.
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "${resolved_entitlements}" \
    --sign "${signing_identity}" \
    "${app_dir}"
fi

print "Built ${app_dir}"
