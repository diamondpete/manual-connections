#!/usr/bin/env bash
# Copyright (C) 2020 Private Internet Access, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

. "$(dirname "$0")/common.sh"

banner run_setup.sh
require_root

# Everything is driven by the single config file - no interactive prompts,
# so this can run unattended from an @reboot cron job.
if [[ ! -f $PIA_CONFIG ]]; then
  echo -e "${red}No config file found at $PIA_CONFIG.${nc}"
  echo "Copy the example into place and fill in your settings:"
  echo "  mkdir -p $PIA_INFO_DIR && cp pia.conf.example $PIA_CONFIG"
  echo "  chmod 600 $PIA_CONFIG"
  exit 1
fi
echo "Loaded configuration from $PIA_CONFIG"

if [[ -z $PIA_USER || -z $PIA_PASS ]]; then
  echo -e "${red}PIA_USER and PIA_PASS must be set in $PIA_CONFIG.${nc}"
  exit 1
fi

# Tear down any active session left over from a previous run so we always
# start clean - covers both connection methods, since the config may have
# switched between OpenVPN and WireGuard since the last run.
echo "Checking for active sessions from a previous run..."

# OpenVPN: prefer the pid file, fall back to matching our config path.
old_pids=""
if [[ -f $PIA_INFO_DIR/pia_pid ]]; then
  old_pids=$(cat "$PIA_INFO_DIR/pia_pid")
fi
old_pids="$old_pids $(pgrep -f "$PIA_INFO_DIR/pia.ovpn" 2>/dev/null)"
for pid in $old_pids; do
  if [[ $(ps -p "$pid" -o comm= 2>/dev/null) == "openvpn" ]]; then
    echo "Killing OpenVPN process $pid from a previous run..."
    kill "$pid"
    for _ in {1..5}; do
      ps -p "$pid" >/dev/null 2>&1 || break
      sleep 1
    done
  fi
done
rm -f "$PIA_INFO_DIR/pia_pid" "$PIA_INFO_DIR/route_info"

# WireGuard: bring the pia interface down if it is up.
if command -v wg >/dev/null && wg show pia >/dev/null 2>&1; then
  echo "Bringing down the WireGuard 'pia' interface from a previous run..."
  wg-quick down pia
fi
echo

export PIA_USER PIA_PASS PIA_AUTOCONNECT PIA_PF PIA_DNS \
  MAX_LATENCY PREFERRED_REGION tunX

./get_token.sh || exit 1
PIA_TOKEN=$(head -1 "$PIA_INFO_DIR/token")
export PIA_TOKEN

./get_region.sh
