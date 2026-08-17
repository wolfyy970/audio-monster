#!/bin/zsh
set -euo pipefail

plist="${1:?}"
label="${2:-Info.plist}"

plutil -lint "${plist}" >/dev/null

for key in NSAllowsArbitraryLoads NSAllowsArbitraryLoadsInWebContent; do
  value="$(
    /usr/libexec/PlistBuddy \
      -c "Print :NSAppTransportSecurity:${key}" \
      "${plist}" \
      2>/dev/null || true
  )"
  [[ "${value}" == "true" ]] \
    || {
      print -u2 "${label} must set NSAppTransportSecurity:${key} so http:// article URLs can open."
      exit 1
    }
done
