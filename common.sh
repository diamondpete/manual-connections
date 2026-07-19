#!/usr/bin/env bash
# Shared helpers sourced by every script:
#   . "$(dirname "$0")/common.sh"
# Loads the single configuration file, applies defaults, defines colors
# and small utility functions.

# Run from the repo directory so relative paths (ca.rsa.4096.crt,
# openvpn_config/...) resolve no matter where we were called from (cron!).
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

PIA_INFO_DIR="/pia-info"

# Every user setting lives in ONE file (see pia.conf.example).
# Override the location with the PIA_CONFIG environment variable.
PIA_CONFIG="${PIA_CONFIG:-$PIA_INFO_DIR/pia.conf}"
if [[ -f $PIA_CONFIG ]]; then
  # shellcheck source=pia.conf.example
  source "$PIA_CONFIG"
fi

# Defaults for anything the config file leaves unset.
tunX="${tunX:-tun0}"
PIA_AUTOCONNECT="${PIA_AUTOCONNECT:-wireguard}"
PIA_PF="${PIA_PF:-true}"
PIA_DNS="${PIA_DNS:-false}"
MAX_LATENCY="${MAX_LATENCY:-0.05}"
PREFERRED_REGION="${PREFERRED_REGION:-}"
TRANSMISSION_NOTIFY="${TRANSMISSION_NOTIFY:-true}"
transUser="${transUser:-}"
transPass="${transPass:-}"

# Define colors for output if the terminal supports them.
if [[ -t 1 ]]; then
  ncolors=$(tput colors 2>/dev/null)
  if [[ -n $ncolors && $ncolors -ge 8 ]]; then
    red=$(tput setaf 1)
    green=$(tput setaf 2)
    nc=$(tput sgr0)
  fi
fi
red="${red:-}"
green="${green:-}"
nc="${nc:-}"

# Check that a required tool is installed, with the pkg to install if not.
check_tool() {
  local cmd=$1 pkg=${2:-$1}
  if ! command -v "$cmd" >/dev/null; then
    echo "$cmd could not be found"
    echo "Please run 'pkg install $pkg'"
    exit 1
  fi
}

require_root() {
  if (( EUID != 0 )); then
    echo -e "${red}This script needs to be run as root. Try again with 'sudo $0'${nc}"
    exit 1
  fi
}

banner() {
  echo "
################################
    $1
################################
Started at $(date)
"
}
