#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
package_manifest="${repo_root}/apps/macos/Package.swift"
core_dir="${repo_root}/apps/macos/Sources/AudioMonsterCore"

fail() {
  print -u2 "Core boundary verification failed: $1"
  exit 1
}

[[ -d "${core_dir}" ]] || fail "missing AudioMonsterCore source directory."

core_sources=("${core_dir}"/*.swift(N))
(( ${#core_sources[@]} > 0 )) || fail "AudioMonsterCore has no Swift sources."

for source in "${core_sources[@]}"; do
  imports=("${(@f)$(sed -nE 's/^[[:space:]]*(.*import[[:space:]]+[^[:space:]]+).*$/\1/p' "${source}")}")
  for import_line in "${imports[@]}"; do
    [[ "${import_line}" == "import Foundation" ]] \
      || fail "${source} has a non-Foundation import: ${import_line}"
  done
done

grep -Fq '.library(name: "AudioMonsterCore", targets: ["AudioMonsterCore"])' \
  "${package_manifest}" \
  || fail "the AudioMonsterCore library product is missing."

if find "${repo_root}" \
  \( -path '*/.build/*' -o -path '*/.xcode-derived/*' -o -path '*/.ruff_cache/*' -o -path '*/dist/*' \) -prune \
  -o -type f \( -name '*.py' -o -name '*.pyc' \) -print -quit | grep -q .; then
  fail "legacy Python source or bytecode remains in the repository."
fi

print "Verified the Foundation-only AudioMonsterCore boundary and native-only source tree."
