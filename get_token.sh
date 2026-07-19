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

banner get_token.sh
check_tool curl
check_tool jq
require_root

mkdir -p "$PIA_INFO_DIR"

if [[ -z $PIA_USER || -z $PIA_PASS ]]; then
  echo "PIA_USER and PIA_PASS must be set (in $PIA_CONFIG or the environment)."
  exit 1
fi

echo -n "Checking login credentials... "
generateTokenResponse=$(curl -s --location --request POST \
  'https://www.privateinternetaccess.com/api/client/v2/token' \
  --form "username=$PIA_USER" \
  --form "password=$PIA_PASS")

token=$(echo "$generateTokenResponse" | jq -r '.token // empty')
if [[ -z $token ]]; then
  echo
  echo -e "${red}Could not authenticate with the login credentials provided!${nc}"
  exit 1
fi
echo -e "${green}OK!${nc}"

# Tokens are valid for 24 hours. BSD date first, GNU date as fallback.
tokenExpiration=$(date -v+1d 2>/dev/null || date --date='1 day')
tokenLocation="$PIA_INFO_DIR/token"
{ echo "$token"; echo "$tokenExpiration"; } > "$tokenLocation" || exit 1
chmod 600 "$tokenLocation"
echo "Token saved to $tokenLocation"
echo "This token will expire in 24 hours, on $tokenExpiration."
echo
