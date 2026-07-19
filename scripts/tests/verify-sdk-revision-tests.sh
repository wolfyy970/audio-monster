#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h:h}"
fixture_root="$(mktemp -d)"

cleanup() {
  rm -rf -- "${fixture_root}"
}
trap cleanup EXIT

fail() {
  print -u2 "Dependency pin test failed: $1"
  exit 1
}

mkdir -p \
  "${fixture_root}/scripts" \
  "${fixture_root}/apps/macos" \
  "${fixture_root}/benchmarks/swift-tts/Sources/SwiftTTSBench"
cp "${repo_root}/scripts/verify-sdk-revision.sh" "${fixture_root}/scripts/"
cp \
  "${repo_root}/apps/macos/Package.swift" \
  "${repo_root}/apps/macos/Package.resolved" \
  "${fixture_root}/apps/macos/"
cp \
  "${repo_root}/benchmarks/swift-tts/Package.swift" \
  "${repo_root}/benchmarks/swift-tts/Package.resolved" \
  "${repo_root}/benchmarks/swift-tts/README.md" \
  "${repo_root}/benchmarks/swift-tts/RESULTS-2026-07-18.md" \
  "${fixture_root}/benchmarks/swift-tts/"
cp \
  "${repo_root}/benchmarks/swift-tts/Sources/SwiftTTSBench/App.swift" \
  "${fixture_root}/benchmarks/swift-tts/Sources/SwiftTTSBench/"

verifier="${fixture_root}/scripts/verify-sdk-revision.sh"
original_manifest="${repo_root}/apps/macos/Package.swift"
original_resolved="${repo_root}/apps/macos/Package.resolved"
fixture_manifest="${fixture_root}/apps/macos/Package.swift"
fixture_resolved="${fixture_root}/apps/macos/Package.resolved"

expect_failure() {
  local description="$1"
  local expected_message="$2"
  local output
  if output="$(zsh "${verifier}" 2>&1)"; then
    fail "${description} was accepted."
  fi
  print -r -- "${output}" | grep -Fq "${expected_message}" \
    || fail "${description} failed without the expected diagnostic."
}

zsh "${verifier}" >/dev/null \
  || fail "the checked-in dependency graph should pass."

sed -i '' \
  's/ecff27c6939beadc5c95e6c08ef8e744109817a6/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
  "${fixture_manifest}"
expect_failure "a changed SwiftReadability manifest revision" \
  "expected ecff27c6939beadc5c95e6c08ef8e744109817a6"
cp "${original_manifest}" "${fixture_manifest}"

sed -i '' \
  's#https://github.com/wolfyy970/swift-readability.git#https://example.invalid/swift-readability.git#' \
  "${fixture_manifest}"
expect_failure "a changed SwiftReadability source URL" \
  "expected https://github.com/wolfyy970/swift-readability.git"
cp "${original_manifest}" "${fixture_manifest}"

sed -i '' \
  's/ecff27c6939beadc5c95e6c08ef8e744109817a6/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' \
  "${fixture_resolved}"
expect_failure "a changed SwiftReadability resolved revision" \
  "expected ecff27c6939beadc5c95e6c08ef8e744109817a6"
cp "${original_resolved}" "${fixture_resolved}"

sed -i '' 's/exact: "2.13.6"/exact: "2.13.5"/' "${fixture_manifest}"
expect_failure "a changed SwiftSoup manifest version" "expected exact 2.13.6"
cp "${original_manifest}" "${fixture_manifest}"

sed -i '' \
  '/"identity" : "swiftsoup"/,/^[[:space:]]*}/ s/"version" : "2.13.6"/"version" : "2.13.5"/' \
  "${fixture_resolved}"
expect_failure "a changed SwiftSoup resolved version" "expected 2.13.6"
cp "${original_resolved}" "${fixture_resolved}"

sed -i '' \
  '/"identity" : "swiftsoup"/,/^[[:space:]]*}/ s/ead56133a693d0184d8c2db1a6d6394410cacfd6/cccccccccccccccccccccccccccccccccccccccc/' \
  "${fixture_resolved}"
expect_failure "a changed SwiftSoup resolved revision" \
  "expected ead56133a693d0184d8c2db1a6d6394410cacfd6"
cp "${original_resolved}" "${fixture_resolved}"

sed -i '' \
  '/"identity" : "swift-url"/,/^[[:space:]]*}/ s/"version" : "0.4.2"/"version" : "0.4.1"/' \
  "${fixture_resolved}"
expect_failure "a changed WebURL resolved version" "expected 0.4.2"
cp "${original_resolved}" "${fixture_resolved}"

sed -i '' \
  '/"identity" : "swift-url"/,/^[[:space:]]*}/ s/9306a962396a50d7d88e924afcd7ec67226763db/dddddddddddddddddddddddddddddddddddddddd/' \
  "${fixture_resolved}"
expect_failure "a changed WebURL resolved revision" \
  "expected 9306a962396a50d7d88e924afcd7ec67226763db"
cp "${original_resolved}" "${fixture_resolved}"

sed -i '' \
  '/"identity" : "swift-url"/,/^[[:space:]]*}/ s#https://github.com/karwa/swift-url.git#https://example.invalid/swift-url.git#' \
  "${fixture_resolved}"
expect_failure "a changed WebURL source URL" \
  "expected https://github.com/karwa/swift-url.git"

print "Dependency pin tests passed."
