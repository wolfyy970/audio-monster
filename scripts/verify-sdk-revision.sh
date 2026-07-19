#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"

fail() {
  print -u2 "SDK revision verification failed: $1"
  exit 1
}

single_match() {
  local label="$1"
  local value="$2"
  local -a matches
  matches=("${(@f)value}")
  matches=("${matches[@]:#}")
  if (( ${#matches[@]} != 1 )); then
    fail "expected one ${label}, found ${#matches[@]}."
  fi
  print -r -- "${matches[1]}"
}

manifest_revision() {
  local file="$1"
  single_match "mlx-audio-swift revision in ${file}" "$(
    sed -nE 's/.*revision: "([0-9a-f]{40})".*/\1/p' "${file}"
  )"
}

resolved_revision() {
  local file="$1"
  single_match "resolved mlx-audio-swift revision in ${file}" "$(
    awk '
      /"identity" : "mlx-audio-swift"/ { found = 1; next }
      found && /"revision"/ {
        revision = $0
        sub(/^.*"revision" : "/, "", revision)
        sub(/".*$/, "", revision)
        print revision
        exit
      }
    ' "${file}"
  )"
}

app_manifest="${repo_root}/apps/macos/Package.swift"
benchmark_manifest="${repo_root}/benchmarks/swift-tts/Package.swift"
app_resolved="${repo_root}/apps/macos/Package.resolved"
benchmark_resolved="${repo_root}/benchmarks/swift-tts/Package.resolved"
benchmark_source="${repo_root}/benchmarks/swift-tts/Sources/SwiftTTSBench/App.swift"
benchmark_readme="${repo_root}/benchmarks/swift-tts/README.md"
benchmark_results="${repo_root}/benchmarks/swift-tts/RESULTS-2026-07-18.md"

expected_revision="$(manifest_revision "${app_manifest}")"
revisions=(
  "$(manifest_revision "${benchmark_manifest}")"
  "$(resolved_revision "${app_resolved}")"
  "$(resolved_revision "${benchmark_resolved}")"
  "$(single_match "benchmark source SDK revision" "$(
    sed -nE 's/.*sdkRevision = "([0-9a-f]{40})".*/\1/p' "${benchmark_source}"
  )")"
  "$(single_match "benchmark README SDK revision" "$(
    grep -Eo '[0-9a-f]{40}' "${benchmark_readme}" | sort -u
  )")"
  "$(single_match "benchmark results SDK revision" "$(
    grep -Eo '[0-9a-f]{40}' "${benchmark_results}" | sort -u
  )")"
)

for revision in "${revisions[@]}"; do
  if [[ "${revision}" != "${expected_revision}" ]]; then
    fail "${revision} does not match ${expected_revision}."
  fi
done

# Generated benchmark results are optional and ignored, but when present they
# must still describe the SDK revision selected by both package manifests.
generated_results="${repo_root}/benchmarks/swift-tts/results"
if [[ -d "${generated_results}" ]]; then
  while IFS= read -r -d '' result_file; do
    result_revision="$(single_match "SDK revision in ${result_file}" "$(
      sed -nE 's/.*"sdkRevision"[[:space:]]*:[[:space:]]*"([0-9a-f]{40})".*/\1/p' "${result_file}"
    )")"
    if [[ "${result_revision}" != "${expected_revision}" ]]; then
      fail "${result_file} records ${result_revision}, expected ${expected_revision}."
    fi
  done < <(find "${generated_results}" -type f -name result.json -print0)
fi

print "Verified mlx-audio-swift revision ${expected_revision}."
