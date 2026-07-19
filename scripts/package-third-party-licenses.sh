#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
package_dir="${repo_root}/apps/macos"
resolved_file="${package_dir}/Package.resolved"
checkouts_dir="${package_dir}/.build/checkouts"
mode="${1:-}"
destination="${2:-}"

fail() {
  print -u2 "Third-party license packaging failed: $1"
  exit 1
}

require_file() {
  [[ -s "$1" ]] || fail "missing or empty $1"
}

resolved_pins() {
  awk '
    /"identity" : "/ {
      identity = $0
      sub(/^.*"identity" : "/, "", identity)
      sub(/".*$/, "", identity)
      next
    }
    identity != "" && /"revision" : "/ {
      revision = $0
      sub(/^.*"revision" : "/, "", revision)
      sub(/".*$/, "", revision)
      print identity "\t" revision
      identity = ""
    }
  ' "${resolved_file}"
}

checkout_for_identity() {
  local identity="$1"
  local checkout
  local -a matches
  matches=()
  for checkout in "${checkouts_dir}"/*(/N); do
    if [[ "${checkout:t:l}" == "${identity:l}" ]]; then
      matches+=("${checkout}")
    fi
  done
  (( ${#matches[@]} == 1 )) \
    || fail "expected one checkout for ${identity}, found ${#matches[@]}."
  print -r -- "${matches[1]}"
}

collect_licenses() {
  local output_dir="$1"
  [[ ! -e "${output_dir}" ]] \
    || fail "destination already exists: ${output_dir}"
  require_file "${resolved_file}"
  [[ -d "${checkouts_dir}" ]] || fail "missing ${checkouts_dir}"

  local -a pins
  pins=("${(@f)$(resolved_pins)}")
  pins=("${pins[@]:#}")
  local resolved_identity_count
  resolved_identity_count="$(grep -Ec '"identity" : "' "${resolved_file}")"
  (( ${#pins[@]} > 0 )) || fail "Package.resolved does not contain any source-control pins."
  (( ${#pins[@]} == resolved_identity_count )) \
    || fail "every resolved package must include an immutable Git revision."

  mkdir -p "${output_dir}"

  local pin identity revision checkout checkout_revision legal_file relative_path packaged_file
  local -a legal_files
  for pin in "${pins[@]}"; do
    identity="${pin%%$'\t'*}"
    revision="${pin#*$'\t'}"
    print -r -- "${identity}" | grep -Eq '^[A-Za-z0-9._-]+$' \
      || fail "unsafe package identity in Package.resolved."
    print -r -- "${revision}" | grep -Eq '^[0-9a-f]{40}$' \
      || fail "invalid resolved revision for ${identity}."

    checkout="$(checkout_for_identity "${identity}")"
    checkout_revision="$(git -C "${checkout}" rev-parse --verify 'HEAD^{commit}')"
    [[ "${checkout_revision}" == "${revision}" ]] \
      || fail "${checkout:t} is at ${checkout_revision}; Package.resolved requires ${revision}."
    [[ -z "$(git -C "${checkout}" status --porcelain --untracked-files=all)" ]] \
      || fail "checkout ${checkout:t} contains local changes."

    legal_files=(
      "${(@f)$(
        {
          find "${checkout}" -maxdepth 1 -type f \
            \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \)
          if [[ -d "${checkout}/LICENSES" ]]; then
            find "${checkout}/LICENSES" -type f
          fi
        } | LC_ALL=C sort -u
      )}"
    )
    legal_files=("${legal_files[@]:#}")
    (( ${#legal_files[@]} > 0 )) \
      || fail "checkout ${checkout:t} does not expose a distributable license or notice."

    for legal_file in "${legal_files[@]}"; do
      require_file "${legal_file}"
      relative_path="${legal_file#${checkout}/}"
      packaged_file="${output_dir}/${checkout:t}/${relative_path}"
      mkdir -p "${packaged_file:h}"
      cp "${legal_file}" "${packaged_file}"
    done
  done

  require_file "${output_dir}/swift-readability/LICENSE"
  require_file "${output_dir}/swift-readability/LICENSES/Apache-2.0.txt"
  require_file "${output_dir}/swift-url/LICENSE"
  require_file "${output_dir}/swift-url/NOTICE"
  require_file "${output_dir}/SwiftSoup/LICENSE"
  require_file "${output_dir}/mlx-audio-swift/LICENSE"
}

case "${mode}" in
  collect)
    [[ -n "${destination}" ]] || fail "collect requires a destination."
    collect_licenses "${destination}"
    print "Packaged resolved dependency licenses."
    ;;
  verify)
    [[ -d "${destination}" ]] || fail "verify requires a packaged license directory."
    expected_root="$(mktemp -d)"
    cleanup() {
      rm -rf -- "${expected_root}"
    }
    trap cleanup EXIT
    collect_licenses "${expected_root}/ThirdPartyLicenses"
    diff -qr "${expected_root}/ThirdPartyLicenses" "${destination}" >/dev/null \
      || fail "packaged dependency licenses differ from the resolved checkout tree."
    print "Verified packaged dependency licenses."
    ;;
  *)
    print -u2 "Usage: $0 collect|verify /path/to/ThirdPartyLicenses"
    exit 2
    ;;
esac
