#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"

"${script_dir}/build-macos-app.sh" debug
open -n -W "${repo_root}/dist/Audio Monster.app"
