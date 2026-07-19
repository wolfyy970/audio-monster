#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
app_dir="${1:-${repo_root}/dist/Audio Monster.app}"
contents_dir="${app_dir}/Contents"
resources_dir="${contents_dir}/Resources"
binary="${contents_dir}/MacOS/AudioMonster"
swift_runtime_dir="${contents_dir}/lib"
source_info="${repo_root}/apps/macos/Resources/Info.plist"
source_entitlements="${repo_root}/apps/macos/Resources/AudioMonster.entitlements"

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
bundle_icon="$(plutil -extract CFBundleIconFile raw "${contents_dir}/Info.plist")"
[[ "${bundle_icon}" == "AudioMonster.icns" ]] \
  || fail "unexpected application icon ${bundle_icon}."
grep -Fq '<key>iCloud.org.audiomonster.AudioMonster</key>' "${contents_dir}/Info.plist" \
  || fail "the neutral Audio Monster iCloud container is missing."
codesign --verify --deep --strict "${app_dir}" \
  || fail "the app's code signature is invalid."

required_swift_runtime_sources=(
  "${(@f)$(
    xcrun swift-stdlib-tool \
      --print \
      --scan-executable "${binary}" \
      --platform macosx
  )}"
)
required_swift_runtime_sources=("${required_swift_runtime_sources[@]:#}")
required_swift_runtime_names=()

for runtime_source in "${required_swift_runtime_sources[@]}"; do
  runtime_name="${runtime_source:t}"
  print -r -- "${runtime_name}" | grep -Eq '^libswift[A-Za-z0-9_]+\.dylib$' \
    || fail "Swift runtime discovery returned an unsafe filename: ${runtime_name}."
  if (( ${required_swift_runtime_names[(Ie)${runtime_name}]} > 0 )); then
    fail "Swift runtime discovery returned duplicate ${runtime_name}."
  fi
  required_swift_runtime_names+=("${runtime_name}")

  packaged_runtime="${swift_runtime_dir}/${runtime_name}"
  [[ -f "${packaged_runtime}" ]] \
    || fail "missing required Swift compatibility runtime ${runtime_name}."
  runtime_architectures="$(lipo -archs "${packaged_runtime}")" \
    || fail "could not inspect ${runtime_name}."
  [[ "${runtime_architectures}" == "arm64" ]] \
    || fail "${runtime_name} has unexpected architectures: ${runtime_architectures}."
  codesign --verify --strict "${packaged_runtime}" \
    || fail "${runtime_name} has an invalid code signature."
done

packaged_swift_runtime_entries=("${swift_runtime_dir}"/*(N))
if (( ${#packaged_swift_runtime_entries[@]} != ${#required_swift_runtime_names[@]} )); then
  fail "the packaged Swift compatibility runtime set does not match the executable."
fi
for packaged_runtime in "${packaged_swift_runtime_entries[@]}"; do
  runtime_name="${packaged_runtime:t}"
  if (( ${required_swift_runtime_names[(Ie)${runtime_name}]} == 0 )); then
    fail "unexpected Swift compatibility runtime ${runtime_name}."
  fi
done
if (( ${#required_swift_runtime_names[@]} > 0 )) \
  && ! otool -l "${binary}" | grep -Fq '@executable_path/../lib'; then
  fail "the app executable cannot load its packaged Swift compatibility runtimes."
fi

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

verify_app_icon() (
  local source_icon packaged_icon iconset_dir
  source_icon="${repo_root}/apps/macos/Resources/AudioMonster.icns"
  packaged_icon="${resources_dir}/AudioMonster.icns"
  [[ -f "${source_icon}" ]] || fail "the source application icon is missing."
  [[ -f "${packaged_icon}" ]] || fail "the app is missing its AudioMonster.icns application icon."
  cmp -s "${source_icon}" "${packaged_icon}" \
    || fail "packaged AudioMonster.icns differs from its source."

  iconset_dir="$(mktemp -d /private/tmp/audio-monster-iconset.XXXXXX)"
  trap 'rm -rf -- "${iconset_dir}"' EXIT
  iconutil --convert iconset --output "${iconset_dir}/AudioMonster.iconset" \
    "${packaged_icon}" >/dev/null \
    || fail "AudioMonster.icns is not a valid macOS icon archive."
  [[ -f "${iconset_dir}/AudioMonster.iconset/icon_512x512.png" ]] \
    || fail "AudioMonster.icns is missing its 512x512 representation."
  [[ -f "${iconset_dir}/AudioMonster.iconset/icon_512x512@2x.png" ]] \
    || fail "AudioMonster.icns is missing its 1024x1024 representation."
)

verify_app_icon

for legal_file in LICENSE THIRD_PARTY_NOTICES.md; do
  source_legal_file="${repo_root}/${legal_file}"
  packaged_legal_file="${resources_dir}/${legal_file}"
  require_file "${source_legal_file}"
  require_file "${packaged_legal_file}"
  cmp -s "${source_legal_file}" "${packaged_legal_file}" \
    || fail "packaged ${legal_file} differs from the repository copy."
done
zsh "${script_dir}/package-third-party-licenses.sh" \
  verify \
  "${resources_dir}/ThirdPartyLicenses" \
  || fail "the packaged dependency license tree is invalid."

metal_libraries=(
  "${resources_dir}"/*.bundle/Contents/Resources/default.metallib(N)
)
(( ${#metal_libraries[@]} == 1 )) \
  || fail "expected one bundled MLX default.metallib, found ${#metal_libraries[@]}."
[[ -s "${metal_libraries[1]}" ]] \
  || fail "the bundled MLX default.metallib is empty."

legacy_extraction_assets=()
while IFS= read -r -d '' legacy_asset; do
  legacy_extraction_assets+=("${legacy_asset}")
done < <(
  find "${contents_dir}" -type f \
    \( -iname 'Readability*.js' -o -iname 'Snapshot*.js' \) \
    -print0
)
if (( ${#legacy_extraction_assets[@]} > 0 )); then
  print -u2 "${(F)legacy_extraction_assets}"
  fail "the app contains a legacy JavaScript extraction payload."
fi

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
       -o -iname 'nodejs' \
       -o -iname 'node_modules' \
       -o -iname 'npm' \
       -o -iname 'npx' \
       -o -iname 'bun' \
       -o -iname 'deno' \
       -o -iname 'package.json' \
       -o -iname '.venv' \
       -o -iname 'venv' \
       -o -iname 'site-packages' \
       -o -iname 'pip' \
       -o -iname 'pip[0-9]*' \
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
if otool -L "${binary}" | grep -Eqi 'libpython|Python\.framework|libnode|Node\.framework'; then
  fail "the app binary links a Python or Node runtime."
fi
personal_path_pattern='/''Users/[^/]+'
if LC_ALL=C grep -aR -Eq "${personal_path_pattern}/" "${contents_dir}"; then
  fail "the app contains a personal absolute build path."
fi

print "Verified ${app_dir}."
