#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"

fail() {
  print -u2 "Dependency pin verification failed: $1"
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

manifest_value() {
  local file="$1"
  local dependency_fragment="$2"
  local field="$3"
  single_match "${field} for ${dependency_fragment} in ${file}" "$(
    awk -v dependency_fragment="${dependency_fragment}" -v field="${field}" '
      index($0, dependency_fragment) { in_dependency = 1 }
      in_dependency && index($0, field ":") {
        value = $0
        sub("^.*" field ":[[:space:]]*\"", "", value)
        sub("\".*$", "", value)
        print value
      }
      in_dependency && /^[[:space:]]*\),?[[:space:]]*$/ { in_dependency = 0 }
    ' "${file}"
  )"
}

resolved_value() {
  local file="$1"
  local identity="$2"
  local field="$3"
  single_match "resolved ${field} for ${identity} in ${file}" "$(
    awk -v identity="${identity}" -v field="${field}" '
      index($0, "\"identity\" : \"" identity "\"") { found = 1; next }
      found && index($0, "\"" field "\"") {
        value = $0
        sub("^.*\"" field "\" : \"", "", value)
        sub("\".*$", "", value)
        print value
        found = 0
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
expected_readability_revision="5c81783fb9c73ec853f678223f955058df4a0d01"
expected_readability_url="https://github.com/wolfyy970/swift-readability.git"
expected_swiftsoup_version="2.13.6"
expected_swiftsoup_revision="ead56133a693d0184d8c2db1a6d6394410cacfd6"
expected_swiftsoup_url="https://github.com/scinfu/SwiftSoup.git"
expected_weburl_version="0.4.2"
expected_weburl_revision="9306a962396a50d7d88e924afcd7ec67226763db"
expected_weburl_url="https://github.com/karwa/swift-url.git"

for required_file in \
  "${app_manifest}" \
  "${benchmark_manifest}" \
  "${app_resolved}" \
  "${benchmark_resolved}" \
  "${benchmark_source}" \
  "${benchmark_readme}" \
  "${benchmark_results}"; do
  [[ -s "${required_file}" ]] || fail "missing ${required_file}."
done

expected_mlx_revision="$(
  manifest_value "${app_manifest}" "mlx-audio-swift.git" "revision"
)"
mlx_revisions=(
  "$(manifest_value "${benchmark_manifest}" "mlx-audio-swift.git" "revision")"
  "$(resolved_value "${app_resolved}" "mlx-audio-swift" "revision")"
  "$(resolved_value "${benchmark_resolved}" "mlx-audio-swift" "revision")"
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

for revision in "${mlx_revisions[@]}"; do
  if [[ "${revision}" != "${expected_mlx_revision}" ]]; then
    fail "${revision} does not match ${expected_mlx_revision}."
  fi
done

manifest_readability_revision="$(
  manifest_value "${app_manifest}" "swift-readability.git" "revision"
)"
manifest_readability_url="$(
  manifest_value "${app_manifest}" "swift-readability.git" "url"
)"
resolved_readability_revision="$(
  resolved_value "${app_resolved}" "swift-readability" "revision"
)"
resolved_readability_url="$(
  resolved_value "${app_resolved}" "swift-readability" "location"
)"
if [[ "${manifest_readability_url}" != "${expected_readability_url}" ]]; then
  fail "Package.swift selects SwiftReadability from ${manifest_readability_url}; expected ${expected_readability_url}."
fi
if [[ "${resolved_readability_url}" != "${expected_readability_url}" ]]; then
  fail "Package.resolved selects SwiftReadability from ${resolved_readability_url}; expected ${expected_readability_url}."
fi
if [[ "${manifest_readability_revision}" != "${expected_readability_revision}" ]]; then
  fail "Package.swift selects SwiftReadability ${manifest_readability_revision}; expected ${expected_readability_revision}."
fi
if [[ "${resolved_readability_revision}" != "${expected_readability_revision}" ]]; then
  fail "Package.resolved selects SwiftReadability ${resolved_readability_revision}; expected ${expected_readability_revision}."
fi

manifest_swiftsoup_version="$(
  manifest_value "${app_manifest}" "SwiftSoup.git" "exact"
)"
manifest_swiftsoup_url="$(
  manifest_value "${app_manifest}" "SwiftSoup.git" "url"
)"
resolved_swiftsoup_version="$(
  resolved_value "${app_resolved}" "swiftsoup" "version"
)"
resolved_swiftsoup_revision="$(
  resolved_value "${app_resolved}" "swiftsoup" "revision"
)"
resolved_swiftsoup_url="$(
  resolved_value "${app_resolved}" "swiftsoup" "location"
)"
if [[ "${manifest_swiftsoup_url}" != "${expected_swiftsoup_url}" ]]; then
  fail "Package.swift selects SwiftSoup from ${manifest_swiftsoup_url}; expected ${expected_swiftsoup_url}."
fi
if [[ "${resolved_swiftsoup_url}" != "${expected_swiftsoup_url}" ]]; then
  fail "Package.resolved selects SwiftSoup from ${resolved_swiftsoup_url}; expected ${expected_swiftsoup_url}."
fi
if [[ "${manifest_swiftsoup_version}" != "${expected_swiftsoup_version}" ]]; then
  fail "Package.swift selects SwiftSoup ${manifest_swiftsoup_version}; expected exact ${expected_swiftsoup_version}."
fi
if [[ "${resolved_swiftsoup_version}" != "${expected_swiftsoup_version}" ]]; then
  fail "Package.resolved selects SwiftSoup ${resolved_swiftsoup_version}; expected ${expected_swiftsoup_version}."
fi
if [[ "${resolved_swiftsoup_revision}" != "${expected_swiftsoup_revision}" ]]; then
  fail "Package.resolved selects SwiftSoup revision ${resolved_swiftsoup_revision}; expected ${expected_swiftsoup_revision}."
fi

resolved_weburl_version="$(
  resolved_value "${app_resolved}" "swift-url" "version"
)"
resolved_weburl_revision="$(
  resolved_value "${app_resolved}" "swift-url" "revision"
)"
resolved_weburl_url="$(
  resolved_value "${app_resolved}" "swift-url" "location"
)"
if [[ "${resolved_weburl_url}" != "${expected_weburl_url}" ]]; then
  fail "Package.resolved selects WebURL from ${resolved_weburl_url}; expected ${expected_weburl_url}."
fi
if [[ "${resolved_weburl_version}" != "${expected_weburl_version}" ]]; then
  fail "Package.resolved selects WebURL ${resolved_weburl_version}; expected ${expected_weburl_version}."
fi
if [[ "${resolved_weburl_revision}" != "${expected_weburl_revision}" ]]; then
  fail "Package.resolved selects WebURL revision ${resolved_weburl_revision}; expected ${expected_weburl_revision}."
fi

# Generated benchmark results are optional and ignored, but when present they
# must still describe the SDK revision selected by both package manifests.
generated_results="${repo_root}/benchmarks/swift-tts/results"
if [[ -d "${generated_results}" ]]; then
  while IFS= read -r -d '' result_file; do
    result_revision="$(single_match "SDK revision in ${result_file}" "$(
      sed -nE 's/.*"sdkRevision"[[:space:]]*:[[:space:]]*"([0-9a-f]{40})".*/\1/p' "${result_file}"
    )")"
    if [[ "${result_revision}" != "${expected_mlx_revision}" ]]; then
      fail "${result_file} records ${result_revision}, expected ${expected_mlx_revision}."
    fi
  done < <(find "${generated_results}" -type f -name result.json -print0)
fi

print "Verified immutable dependency pins:"
print "  mlx-audio-swift ${expected_mlx_revision}"
print "  SwiftReadability ${expected_readability_revision}"
print "  SwiftSoup ${expected_swiftsoup_version} (${expected_swiftsoup_revision})"
print "  WebURL ${expected_weburl_version} (${expected_weburl_revision})"
