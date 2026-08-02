#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
app_path="${repo_root}/dist/Audio Monster.app"
dmg_path="${repo_root}/dist/Audio Monster.dmg"
volume_name="Audio Monster"
working_root="$(mktemp -d "/tmp/audio-monster-dmg.XXXXXX")"
staging_dir="${working_root}/payload"
read_write_image="${working_root}/Audio Monster-rw.dmg"
device=""
mount_point=""

cleanup() {
  if [[ -n "${mount_point}" ]]; then
    hdiutil detach "${mount_point}" -force >/dev/null 2>&1 || true
  elif [[ -n "${device}" ]]; then
    hdiutil detach "${device}" -force >/dev/null 2>&1 || true
  fi
  rm -rf -- "${working_root}"
}
trap cleanup EXIT INT TERM

if [[ ! -d "${app_path}" ]]; then
  print -u2 "Build ${app_path} before creating the installer."
  exit 1
fi

zsh "${script_dir}/verify-macos-app.sh" "${app_path}"

mkdir -p "${staging_dir}"
ditto "${app_path}" "${staging_dir}/Audio Monster.app"
ln -s /Applications "${staging_dir}/Applications"

rm -f -- "${dmg_path}" "${dmg_path}.sha256"
hdiutil create \
  -quiet \
  -volname "${volume_name}" \
  -srcfolder "${staging_dir}" \
  -ov \
  -format UDRW \
  "${read_write_image}"

attach_output="$(hdiutil attach -readwrite -noverify -noautoopen "${read_write_image}")"
device="$(print -r -- "${attach_output}" | awk -F '\t' '$3 ~ /^\/Volumes\// { print $1; exit }' | sed 's/[[:space:]]*$//')"
mount_point="$(print -r -- "${attach_output}" | awk -F '\t' '$3 ~ /^\/Volumes\// { print $3; exit }')"

if [[ -z "${device}" || -z "${mount_point}" || ! -d "${mount_point}" ]]; then
  print -u2 "Could not locate the mounted installer volume."
  exit 1
fi

if ! osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "Audio Monster"
        open
        delay 1
        set current view of container window to icon view
        set arrangement of icon view options of container window to not arranged
        set icon size of icon view options of container window to 96
        set position of item "Audio Monster.app" of container window to {170, 180}
        set position of item "Applications" of container window to {470, 180}
        set bounds of container window to {100, 100, 700, 500}
        update without registering applications
        close
    end tell
end tell
APPLESCRIPT
then
  print -u2 "Finder layout could not be written; continuing with the functional installer."
fi

sleep 2
test -d "${mount_point}/Audio Monster.app"
test -L "${mount_point}/Applications"
hdiutil detach "${mount_point}" >/dev/null
device=""
mount_point=""

hdiutil convert \
  "${read_write_image}" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "${dmg_path}" \
  >/dev/null

hdiutil verify "${dmg_path}" >/dev/null
checksum="$(shasum -a 256 "${dmg_path}" | awk '{print $1}')"
print -r -- "${checksum}  ${dmg_path:t}" > "${dmg_path}.sha256"

print "Built ${dmg_path}"
print "SHA-256: ${checksum}"
