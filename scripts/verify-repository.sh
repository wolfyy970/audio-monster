#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
mode="${1:-all}"

run_app_tests() {
  (
    cd "${repo_root}/apps/macos"
    xcodebuild \
      -scheme AudioMonster \
      -destination 'platform=macOS,arch=arm64' \
      -configuration Debug \
      -derivedDataPath .build/xcode-derived \
      -clonedSourcePackagesDirPath .build \
      -skipPackagePluginValidation \
      -onlyUsePackageVersionsFromResolvedFile \
      test \
      CODE_SIGNING_ALLOWED=NO \
      -test-timeouts-enabled YES \
      -default-test-execution-time-allowance 30 \
      -maximum-test-execution-time-allowance 60
    zsh "${script_dir}/tests/verify-macos-app-tests.sh"
  )
}

run_benchmark_tests() {
  (
    cd "${repo_root}/benchmarks/swift-tts"
    swift test --only-use-versions-from-resolved-file -c release
  )
}

verify_repository_metadata() {
  local required_file
  for required_file in \
    "${repo_root}/LICENSE" \
    "${repo_root}/README.md" \
    "${repo_root}/CHANGELOG.md" \
    "${repo_root}/CODE_OF_CONDUCT.md" \
    "${repo_root}/CONTRIBUTING.md" \
    "${repo_root}/Gemfile" \
    "${repo_root}/Gemfile.lock" \
    "${repo_root}/SECURITY.md" \
    "${repo_root}/THIRD_PARTY_NOTICES.md" \
    "${repo_root}/apps/macos/Resources/AudioMonster.icns" \
    "${repo_root}/docs/images/audio-monster-app-icon.svg" \
    "${repo_root}/scripts/generate-app-icon.swift" \
    "${repo_root}/.github/dependabot.yml" \
    "${repo_root}/.github/workflows/ci.yml" \
    "${repo_root}/docs/releasing.md" \
    "${repo_root}/fastlane/Fastfile"; do
    [[ -s "${required_file}" ]] || {
      print -u2 "Missing public repository file: ${required_file}"
      exit 1
    }
  done

  grep -Fq 'MIT License' "${repo_root}/LICENSE" \
    || {
      print -u2 "The root license is not MIT."
      exit 1
    }
  grep -Fq 'Audio Monster contributors' "${repo_root}/LICENSE" \
    || {
      print -u2 "The root license has an unexpected copyright holder."
      exit 1
    }
  grep -Fq 'fastlane (= 2.237.0)' "${repo_root}/Gemfile.lock" \
    || {
      print -u2 "Gemfile.lock does not contain the pinned Fastlane version."
      exit 1
    }
  grep -Fq '$(TeamIdentifierPrefix)iCloud.org.audiomonster.AudioMonster' \
    "${repo_root}/apps/macos/Resources/AudioMonster.entitlements" \
    || {
      print -u2 "The entitlement template must remain portable across Apple Developer teams."
      exit 1
    }

  plutil -lint \
    "${repo_root}/apps/macos/Resources/Info.plist" \
    "${repo_root}/apps/macos/Resources/AudioMonster.entitlements" \
    >/dev/null

  local app_version expected_user_agent
  app_version="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :CFBundleShortVersionString' \
      "${repo_root}/apps/macos/Resources/Info.plist"
  )"
  expected_user_agent="applicationNameForUserAgent: String = \"AudioMonster/${app_version}\""
  grep -Fq \
    "${expected_user_agent}" \
    "${repo_root}/apps/macos/Sources/AudioMonsterCore/BrowserExtractionPolicy.swift" \
    || {
      print -u2 "The browser user-agent version does not match Info.plist ${app_version}."
      exit 1
    }

  ruby -c "${repo_root}/fastlane/Fastfile" >/dev/null
  zsh -n "${repo_root}"/scripts/*.sh "${repo_root}"/scripts/tests/*.sh

  local personal_path_pattern='/''Users/[^/]+'
  if rg -n "${personal_path_pattern}" \
    "${repo_root}/apps" \
    "${repo_root}/benchmarks" \
    "${repo_root}/README.md" \
    "${repo_root}/CODE_OF_CONDUCT.md" \
    "${repo_root}/CONTRIBUTING.md" \
    "${repo_root}/SECURITY.md" \
    "${repo_root}/THIRD_PARTY_NOTICES.md" \
    "${repo_root}/docs" \
    "${repo_root}/fastlane/Fastfile" \
    "${repo_root}/scripts"; then
    print -u2 "Public source or documentation contains a personal absolute path."
    exit 1
  fi

  if rg -l --hidden \
    --glob '!.git/**' \
    --glob '!vendor/**' \
    --glob '!dist/**' \
    --glob '!artifacts/**' \
    --glob '!**/.build/**' \
    -e '-----BEGIN (RSA |EC |OPENSSH |)?PRIVATE KEY-----' \
    -e 'github_pat_[A-Za-z0-9_]+' \
    -e 'gh[pousr]_[A-Za-z0-9]{20,}' \
    -e 'AKIA[0-9A-Z]{16}' \
    -e 'xox[baprs]-[0-9A-Za-z-]+' \
    -e 'sk-[A-Za-z0-9_-]{20,}' \
    "${repo_root}"; then
    print -u2 "Public repository content contains a credential-like value."
    exit 1
  fi
}

verify_app_icon() (
  local icon_work_dir generated_icon
  icon_work_dir="$(mktemp -d /private/tmp/audio-monster-icon-verify.XXXXXX)"
  generated_icon="${icon_work_dir}/AudioMonster.icns"
  trap 'rm -rf -- "${icon_work_dir}"' EXIT

  xcrun swift \
    -module-cache-path "${icon_work_dir}/module-cache" \
    "${repo_root}/scripts/generate-app-icon.swift" \
    "${repo_root}/docs/images/audio-monster-app-icon.svg" \
    "${generated_icon}"
  cmp -s \
    "${repo_root}/apps/macos/Resources/AudioMonster.icns" \
    "${generated_icon}" \
    || {
      print -u2 "AudioMonster.icns does not match its reproducible SVG source."
      exit 1
    }
)

verify_static_metadata() {
  verify_repository_metadata
  verify_app_icon
  zsh "${script_dir}/verify-sdk-revision.sh"
  zsh "${script_dir}/tests/verify-sdk-revision-tests.sh"
  zsh "${script_dir}/verify-core-boundary.sh"
  xcrun swift-format lint \
    --recursive \
    --configuration "${repo_root}/.swift-format" \
    "${repo_root}/apps/macos/Sources" \
    "${repo_root}/apps/macos/Tests" \
    "${repo_root}/benchmarks/swift-tts/Sources" \
    "${repo_root}/benchmarks/swift-tts/Tests"
}

case "${mode}" in
  app-tests)
    run_app_tests
    ;;
  benchmark-tests)
    run_benchmark_tests
    ;;
  static)
    verify_static_metadata
    ;;
  all)
    print "==> Verifying pinned metadata"
    verify_static_metadata
    print "==> Running Audio Monster tests"
    run_app_tests
    print "==> Running native TTS benchmark tests"
    run_benchmark_tests
    print "==> Building a clean release app"
    zsh "${script_dir}/build-macos-app.sh" release
    print "==> Verifying the packaged app"
    zsh "${script_dir}/verify-macos-app.sh"
    print "Repository verification passed."
    ;;
  *)
    print -u2 "Usage: $0 [all|app-tests|benchmark-tests|static]"
    exit 2
    ;;
esac
