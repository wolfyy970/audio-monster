#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h:h}"
fixture_root="$(mktemp -d)"
fixture_app="${fixture_root}/Audio Monster.app"
contents_dir="${fixture_app}/Contents"
resources_dir="${contents_dir}/Resources"
binary="${contents_dir}/MacOS/AudioMonster"

cleanup() {
  rm -rf -- "${fixture_root}"
}
trap cleanup EXIT

fail() {
  print -u2 "Packaged-app verifier test failed: $1"
  exit 1
}

resign_fixture() {
  codesign --force --deep --sign - "${fixture_app}" >/dev/null 2>&1
}

expect_failure() {
  local description="$1"
  local expected_message="$2"
  local output
  if output="$(zsh "${repo_root}/scripts/verify-macos-app.sh" "${fixture_app}" 2>&1)"; then
    fail "${description} was accepted."
  fi
  print -r -- "${output}" | grep -Fq "${expected_message}" \
    || fail "${description} failed without the expected diagnostic: ${output}"
}

mkdir -p \
  "${contents_dir}/MacOS" \
  "${resources_dir}/Fixture.bundle/Contents/Resources"
cp /usr/bin/true "${binary}"
cp "${repo_root}/apps/macos/Resources/Info.plist" "${contents_dir}/Info.plist"
cp \
  "${repo_root}/apps/macos/Resources/AudioMonster.icns" \
  "${repo_root}/apps/macos/Resources/AudioMonsterMenuBarTemplate.png" \
  "${repo_root}/apps/macos/Resources/AudioMonsterMenuBarTemplate@2x.png" \
  "${repo_root}/LICENSE" \
  "${repo_root}/THIRD_PARTY_NOTICES.md" \
  "${resources_dir}/"
zsh "${repo_root}/scripts/package-third-party-licenses.sh" \
  collect \
  "${resources_dir}/ThirdPartyLicenses" \
  >/dev/null
print -rn -- 'fixture-metal-library' \
  > "${resources_dir}/Fixture.bundle/Contents/Resources/default.metallib"

resign_fixture
valid_output="$(zsh "${repo_root}/scripts/verify-macos-app.sh" "${fixture_app}")" \
  || fail "a valid native-only fixture should pass."
print -r -- "${valid_output}" | grep -Fq "${repo_root}/apps/macos/.build/checkouts" \
  && fail "a valid verification leaked dependency checkout paths."

mv "${resources_dir}/AudioMonster.icns" "${resources_dir}/AudioMonster.icns.missing"
resign_fixture
expect_failure "a missing application icon" \
  "the app is missing its AudioMonster.icns application icon"
mv "${resources_dir}/AudioMonster.icns.missing" "${resources_dir}/AudioMonster.icns"
resign_fixture

debug_app_binary="${repo_root}/apps/macos/.build/xcode-derived/Build/Products/Debug/AudioMonster"
[[ -x "${debug_app_binary}" ]] \
  || fail "the preceding Xcode test build did not produce ${debug_app_binary}."
cp "${debug_app_binary}" "${binary}"
resign_fixture
expect_failure "a missing Swift compatibility runtime" \
  "missing required Swift compatibility runtime"
cp /usr/bin/true "${binary}"
resign_fixture

mkdir -p "${resources_dir}/Legacy.bundle/Contents/Resources/Readability"
print -rn -- 'legacy JavaScript' \
  > "${resources_dir}/Legacy.bundle/Contents/Resources/Readability/Readability.min.js"
resign_fixture
expect_failure "a legacy extraction script" \
  "the app contains a legacy JavaScript extraction payload"

rm -f -- "${resources_dir}/Legacy.bundle/Contents/Resources/Readability/Readability.min.js"
altered_dependency_license="${resources_dir}/ThirdPartyLicenses/swift-readability/LICENSE"
chmod u+w "${altered_dependency_license}"
print -rn -- 'altered dependency license' > "${altered_dependency_license}"
resign_fixture
expect_failure "an altered packaged dependency license" \
  "the packaged dependency license tree is invalid"
cp "${repo_root}/apps/macos/.build/checkouts/swift-readability/LICENSE" \
  "${altered_dependency_license}"

print -rn -- 'altered license' > "${resources_dir}/LICENSE"
resign_fixture
expect_failure "an altered packaged license" \
  "packaged LICENSE differs from the repository copy"

print "Packaged-app verifier tests passed."
