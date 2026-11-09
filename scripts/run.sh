#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-debug}"

"$project_root/scripts/build-app.sh" "$configuration"
open "$project_root/dist/$configuration/Tietiezhi Tools.app"
