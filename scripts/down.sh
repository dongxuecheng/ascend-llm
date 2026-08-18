#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

require_root
load_env
detect_compose

compose down --remove-orphans
