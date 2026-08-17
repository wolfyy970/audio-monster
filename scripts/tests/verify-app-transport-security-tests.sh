#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h:h}"
verifier="${repo_root}/scripts/verify-app-transport-security.sh"
source_plist="${repo_root}/apps/macos/Resources/Info.plist"

fail() {
  print -u2 "App Transport Security verifier test failed: $1"
  exit 1
}

zsh "${verifier}" "${source_plist}" "Info.plist" \
  || fail "the production Info.plist must allow insecure article loads."

work_dir="$(mktemp -d)"
trap 'rm -rf -- "${work_dir}"' EXIT
missing_plist="${work_dir}/Info.plist"
cp "${source_plist}" "${missing_plist}"
/usr/libexec/PlistBuddy -c 'Delete :NSAppTransportSecurity' "${missing_plist}"

if output="$(zsh "${verifier}" "${missing_plist}" "the fixture" 2>&1)"; then
  fail "a plist without App Transport Security exceptions was accepted."
fi
print -r -- "${output}" | grep -Fq "NSAllowsArbitraryLoads" \
  || fail "the missing-exception failure did not name NSAllowsArbitraryLoads: ${output}"

web_content_only="${work_dir}/WebContentOnly.plist"
cp "${source_plist}" "${web_content_only}"
/usr/libexec/PlistBuddy -c 'Delete :NSAppTransportSecurity:NSAllowsArbitraryLoads' \
  "${web_content_only}"
if output="$(zsh "${verifier}" "${web_content_only}" "the fixture" 2>&1)"; then
  fail "a plist that only allows insecure web content was accepted."
fi
print -r -- "${output}" | grep -Fq "NSAllowsArbitraryLoads" \
  || fail "a missing NSAllowsArbitraryLoads key was not diagnosed: ${output}"

print "App Transport Security verifier tests passed."
