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

# Refuse to build from an implicitly re-resolved dependency graph. Release and
# development artifacts must use the immutable revisions checked into
# Package.resolved and verified by the repository's dependency-pin gate.
zsh "${script_dir}/verify-sdk-revision.sh"

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
    -clonedSourcePackagesDirPath "${package_dir}/.build" \
    -skipPackagePluginValidation \
    -onlyUsePackageVersionsFromResolvedFile \
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
swift_runtime_dir="${contents_dir}/lib"

if [[ -e "${app_dir}" ]]; then
  rm -rf "${app_dir}"
fi

mkdir -p "${macos_dir}" "${resources_dir}"
cp "${binary}" "${macos_dir}/AudioMonster"
# Swift package schemes can retain coverage/local symbols in an otherwise optimized
# product. They are not useful in the distributable app and may contain build paths.
strip -x "${macos_dir}/AudioMonster"

# A Swift executable built by a newer toolchain can weak-link compatibility
# runtimes that are not present on every supported macOS release. SwiftPM does
# not assemble an application bundle for us, so copy the exact runtimes that
# Xcode's own discovery tool reports and retain only the app's arm64 slice.
# The executable already contains @executable_path/../lib in its runpath list.
swift_runtime_libraries=(
  "${(@f)$(
    xcrun swift-stdlib-tool \
      --print \
      --scan-executable "${macos_dir}/AudioMonster" \
      --platform macosx
  )}"
)
swift_runtime_libraries=("${swift_runtime_libraries[@]:#}")
if (( ${#swift_runtime_libraries[@]} > 0 )); then
  mkdir -p "${swift_runtime_dir}"
fi

for runtime_library in "${swift_runtime_libraries[@]}"; do
  if [[ ! -f "${runtime_library}" ]]; then
    print -u2 "Swift runtime discovery returned a missing file: ${runtime_library}."
    exit 1
  fi

  runtime_name="${runtime_library:t}"
  if ! print -r -- "${runtime_name}" | grep -Eq '^libswift[A-Za-z0-9_]+\.dylib$'; then
    print -u2 "Swift runtime discovery returned an unsafe filename: ${runtime_name}."
    exit 1
  fi

  packaged_runtime="${swift_runtime_dir}/${runtime_name}"
  if [[ -e "${packaged_runtime}" ]]; then
    print -u2 "Swift runtime discovery returned duplicate ${runtime_name}."
    exit 1
  fi

  runtime_architectures="$(lipo -archs "${runtime_library}")"
  if [[ " ${runtime_architectures} " != *' arm64 '* ]]; then
    print -u2 "${runtime_library} does not contain an arm64 slice."
    exit 1
  fi
  if [[ "${runtime_architectures}" == "arm64" ]]; then
    cp "${runtime_library}" "${packaged_runtime}"
  else
    lipo "${runtime_library}" -thin arm64 -output "${packaged_runtime}"
  fi
done

cp "${package_dir}/Resources/Info.plist" "${contents_dir}/Info.plist"
cp "${package_dir}/Resources/AudioMonster.icns" "${resources_dir}/"
cp "${package_dir}/Resources/AudioMonsterMenuBarTemplate.png" "${resources_dir}/"
cp "${package_dir}/Resources/AudioMonsterMenuBarTemplate@2x.png" "${resources_dir}/"
for legal_file in LICENSE THIRD_PARTY_NOTICES.md; do
  if [[ ! -s "${repo_root}/${legal_file}" ]]; then
    print -u2 "The distributable app is missing ${repo_root}/${legal_file}."
    exit 1
  fi
  cp "${repo_root}/${legal_file}" "${resources_dir}/${legal_file}"
done
zsh "${script_dir}/package-third-party-licenses.sh" \
  collect \
  "${resources_dir}/ThirdPartyLicenses"

# SwiftPM resource accessors look in the app's Resources directory first.
resource_bundles=("${products_dir}"/*.bundle(N))
for bundle in "${resource_bundles[@]}"; do
  ditto "${bundle}" "${resources_dir}/${bundle:t}"
done

metal_libraries=(
  "${resources_dir}"/*.bundle/Contents/Resources/default.metallib(N)
)
if (( ${#metal_libraries[@]} != 1 )) || [[ ! -s "${metal_libraries[1]}" ]]; then
  print -u2 "The app bundle is missing its compiled MLX Metal library."
  exit 1
fi

legacy_extraction_assets=()
while IFS= read -r -d '' legacy_asset; do
  legacy_extraction_assets+=("${legacy_asset}")
done < <(
  find "${resources_dir}" -type f \
    \( -iname 'Readability*.js' -o -iname 'Snapshot*.js' \) \
    -print0
)
if (( ${#legacy_extraction_assets[@]} > 0 )); then
  print -u2 "${(F)legacy_extraction_assets}"
  print -u2 "The app bundle contains a legacy JavaScript extraction payload."
  exit 1
fi

if [[ "${signing_identity}" == "-" ]]; then
  # Ad-hoc signing keeps the zero-setup development build available. Restricted
  # iCloud entitlements are intentionally omitted because no profile authorizes
  # them in this mode.
  for runtime_library in "${swift_runtime_dir}"/*.dylib(N); do
    codesign --force --sign - "${runtime_library}" >/dev/null
  done
  codesign --force --sign - "${app_dir}" >/dev/null
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
  # Nested code must be signed before the outer bundle. Do not pre-sign the main
  # executable: the app-bundle signature below applies its production
  # entitlements and avoids an earlier entitlement-free signature.
  for runtime_library in "${swift_runtime_dir}"/*.dylib(N); do
    codesign \
      --force \
      --options runtime \
      --timestamp \
      --sign "${signing_identity}" \
      "${runtime_library}"
  done
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "${resolved_entitlements}" \
    --sign "${signing_identity}" \
    "${app_dir}"
fi

print "Built ${app_dir}"
