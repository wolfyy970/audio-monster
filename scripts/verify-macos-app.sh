#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
app_dir="${1:-${repo_root}/dist/Audio Monster.app}"
contents_dir="${app_dir}/Contents"
resources_dir="${contents_dir}/Resources"
binary="${contents_dir}/MacOS/AudioMonster"
source_info="${repo_root}/apps/macos/Resources/Info.plist"
source_entitlements="${repo_root}/apps/macos/Resources/AudioMonster.entitlements"
source_readability_dir="${repo_root}/apps/macos/Sources/AudioMonster/Resources/Readability"
readability_swift="${repo_root}/apps/macos/Sources/AudioMonster/MozillaReadabilityAsset.swift"

fail() {
  print -u2 "App verification failed: $1"
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing $1"
}

require_file "${binary}"
[[ -x "${binary}" ]] || fail "${binary} is not executable."
require_file "${contents_dir}/Info.plist"

plutil -lint "${contents_dir}/Info.plist" >/dev/null
cmp -s "${source_info}" "${contents_dir}/Info.plist" \
  || fail "packaged Info.plist differs from the source plist."
bundle_identifier="$(plutil -extract CFBundleIdentifier raw "${contents_dir}/Info.plist")"
[[ "${bundle_identifier}" == "org.audiomonster.AudioMonster" ]] \
  || fail "unexpected bundle identifier ${bundle_identifier}."
grep -Fq '<key>iCloud.org.audiomonster.AudioMonster</key>' "${contents_dir}/Info.plist" \
  || fail "the neutral Audio Monster iCloud container is missing."
codesign --verify --deep --strict "${app_dir}" \
  || fail "the app's code signature is invalid."

if [[ -f "${contents_dir}/embedded.provisionprofile" ]]; then
  require_file "${source_entitlements}"
  signed_entitlements="$(mktemp)"
  profile_plist="$(mktemp)"
  trap 'rm -f -- "${signed_entitlements}" "${profile_plist}"' EXIT

  codesign -d --xml --entitlements - "${binary}" > "${signed_entitlements}" 2>/dev/null \
    || fail "could not read the signed app entitlements."
  security cms -D -i "${contents_dir}/embedded.provisionprofile" > "${profile_plist}" \
    || fail "the embedded provisioning profile is invalid."
  plutil -lint "${signed_entitlements}" >/dev/null \
    || fail "the signed entitlements are not a valid plist."
  # Developer ID profiles use the macOS entitlement spelling while App Store
  # and development profiles commonly use `application-identifier`.
  if ! profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "${profile_plist}" 2>/dev/null)"; then
    profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "${profile_plist}")"
  fi
  [[ "${profile_app_id}" == *."${bundle_identifier}" ]] \
    || fail "the provisioning profile does not authorize ${bundle_identifier}."

  profile_team_id="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "${profile_plist}")"
  [[ -n "${profile_team_id}" ]] \
    || fail "the provisioning profile does not identify an Apple Developer team."

  for entitlement_key in \
    com.apple.developer.ubiquity-container-identifiers; do
    expected_entitlement_value="${profile_team_id}.iCloud.org.audiomonster.AudioMonster"
    profile_entitlement_values="$(
      /usr/libexec/PlistBuddy -c "Print :Entitlements:${entitlement_key}" "${profile_plist}"
    )"
    if ! print -r -- "${profile_entitlement_values}" \
      | grep -Fq "${expected_entitlement_value}" \
      && ! print -r -- "${profile_entitlement_values}" \
        | grep -Fq "${profile_team_id}.*"; then
      fail "the provisioning profile does not authorize ${expected_entitlement_value}."
    fi
    /usr/libexec/PlistBuddy -c "Print :${entitlement_key}" "${signed_entitlements}" \
      | grep -Fq "${expected_entitlement_value}" \
      || fail "the signed app is missing ${entitlement_key}."
  done

  # `codesign -dv` may report Authority=(unavailable) when the verification
  # process cannot consult the user's keychain. The designated requirement is
  # embedded in the signature itself; Apple's 1.2.840.113635.100.6.1.13 OID
  # identifies a Developer ID Application leaf certificate.
  designated_requirement="$(codesign -d -r- "${app_dir}" 2>&1)"
  print -r -- "${designated_requirement}" \
    | grep -Fq 'certificate leaf[field.1.2.840.113635.100.6.1.13]' \
    || fail "the provisioned app is not signed with Developer ID Application."
  print -r -- "${designated_requirement}" \
    | grep -Fq "certificate leaf[subject.OU] = ${profile_team_id}" \
    || fail "the Developer ID signature belongs to the wrong team."
fi

verify_icon() {
  local filename="$1"
  local expected_dimension="$2"
  local source_icon="${repo_root}/apps/macos/Resources/${filename}"
  local packaged_icon="${resources_dir}/${filename}"
  require_file "${source_icon}"
  require_file "${packaged_icon}"
  cmp -s "${source_icon}" "${packaged_icon}" \
    || fail "packaged ${filename} differs from its source."

  local width
  local height
  width="$(sips -g pixelWidth "${packaged_icon}" 2>/dev/null | awk '/pixelWidth/ { print $2 }')"
  height="$(sips -g pixelHeight "${packaged_icon}" 2>/dev/null | awk '/pixelHeight/ { print $2 }')"
  [[ "${width}" == "${expected_dimension}" && "${height}" == "${expected_dimension}" ]] \
    || fail "${filename} is ${width}x${height}; expected ${expected_dimension}x${expected_dimension}."
}

verify_icon "AudioMonsterMenuBarTemplate.png" 18
verify_icon "AudioMonsterMenuBarTemplate@2x.png" 36

readability_scripts=(
  "${resources_dir}"/*.bundle/Contents/Resources/Readability/Readability.js(N)
)
readability_licenses=(
  "${resources_dir}"/*.bundle/Contents/Resources/Readability/LICENSE.md(N)
)
readability_metadata_files=(
  "${resources_dir}"/*.bundle/Contents/Resources/Readability/UPSTREAM.md(N)
)
snapshot_scripts=(
  "${resources_dir}"/*.bundle/Contents/Resources/Extraction/Snapshot.js(N)
)
metal_libraries=(
  "${resources_dir}"/*.bundle/Contents/Resources/default.metallib(N)
)
(( ${#readability_scripts[@]} == 1 )) \
  || fail "expected one bundled Readability.js, found ${#readability_scripts[@]}."
(( ${#readability_licenses[@]} == 1 )) \
  || fail "expected one bundled Readability license, found ${#readability_licenses[@]}."
(( ${#readability_metadata_files[@]} == 1 )) \
  || fail "expected one bundled Readability metadata file, found ${#readability_metadata_files[@]}."
(( ${#snapshot_scripts[@]} == 1 )) \
  || fail "expected one bundled extraction Snapshot.js, found ${#snapshot_scripts[@]}."
(( ${#metal_libraries[@]} == 1 )) \
  || fail "expected one bundled MLX default.metallib, found ${#metal_libraries[@]}."

source_snapshot="${repo_root}/apps/macos/Sources/AudioMonster/Resources/Extraction/Snapshot.js"
require_file "${source_snapshot}"
cmp -s "${source_snapshot}" "${snapshot_scripts[1]}" \
  || fail "the bundled extraction Snapshot.js differs from its source."
[[ -s "${metal_libraries[1]}" ]] \
  || fail "the bundled MLX default.metallib is empty."

source_script="${source_readability_dir}/Readability.js"
source_license="${source_readability_dir}/LICENSE.md"
source_metadata="${source_readability_dir}/UPSTREAM.md"
require_file "${source_script}"
require_file "${source_license}"
require_file "${source_metadata}"

metadata_sha="$(sed -nE 's/^- Source SHA-256: `([0-9a-f]{64})`$/\1/p' "${source_metadata}")"
swift_sha="$(sed -nE 's/^[[:space:]]*"([0-9a-f]{64})"$/\1/p' "${readability_swift}")"
source_sha="$(shasum -a 256 "${source_script}" | awk '{ print $1 }')"
packaged_sha="$(shasum -a 256 "${readability_scripts[1]}" | awk '{ print $1 }')"
print -r -- "${metadata_sha}" | grep -Eq '^[0-9a-f]{64}$' \
  || fail "UPSTREAM.md does not contain exactly one valid SHA-256."
[[ "${swift_sha}" == "${metadata_sha}" ]] \
  || fail "the Swift Readability pin does not match UPSTREAM.md."
[[ "${source_sha}" == "${metadata_sha}" ]] \
  || fail "the vendored Readability source does not match UPSTREAM.md."
[[ "${packaged_sha}" == "${metadata_sha}" ]] \
  || fail "the bundled Readability source does not match UPSTREAM.md."
cmp -s "${source_license}" "${readability_licenses[1]}" \
  || fail "the bundled Readability license differs from the vendored license."
cmp -s "${source_metadata}" "${readability_metadata_files[1]}" \
  || fail "the bundled Readability metadata differs from its source."
grep -Fq "Apache License" "${readability_licenses[1]}" \
  || fail "the bundled Readability license is not the expected Apache license."

forbidden_payloads=()
while IFS= read -r -d '' payload; do
  forbidden_payloads+=("${payload}")
done < <(
  find "${contents_dir}" \
    \( -iname '*.py' \
       -o -iname '*.pyc' \
       -o -iname 'python' \
       -o -iname 'python[0-9]*' \
       -o -iname 'node' \
       -o -iname 'node_modules' \
       -o -iname 'package.json' \
       -o -iname 'uv' \
       -o -iname 'uvicorn*' \
       -o -iname 'fastapi*' \
       -o -iname 'ffmpeg*' \) \
    -print0
)
if (( ${#forbidden_payloads[@]} > 0 )); then
  print -u2 "${(F)forbidden_payloads}"
  fail "the app contains a Python, Node, server, or external encoder payload."
fi
if otool -L "${binary}" | grep -Eqi 'libpython|Python\.framework'; then
  fail "the app binary links a Python runtime."
fi
personal_path_pattern='/''Users/[^/]+'
if LC_ALL=C grep -aR -Eq "${personal_path_pattern}/" "${contents_dir}"; then
  fail "the app contains a personal absolute build path."
fi

print "Verified ${app_dir}."
