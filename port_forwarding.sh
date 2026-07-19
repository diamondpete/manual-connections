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

banner port_forwarding.sh
check_tool curl
check_tool jq
check_tool base64

# Check if the mandatory environment variables are set.
if [[ -z $PF_GATEWAY || -z $PIA_TOKEN || -z $PF_HOSTNAME ]]; then
  echo -e "${red}This script requires 3 env vars:"
  echo "PF_GATEWAY  - the IP of your gateway"
  echo "PF_HOSTNAME - name of the host used for SSL/TLS certificate verification"
  echo "PIA_TOKEN   - the token you use to connect to the vpn services"
  echo
  echo "An easy solution is to just run ./run_setup.sh, which reads"
  echo -e "everything from $PIA_CONFIG and guides the full process.${nc}"
  exit 1
fi

# The port forwarding system has required two variables:
# PAYLOAD: contains the token, the port and the expiration date
# SIGNATURE: certifies the payload originates from the PIA network.

# Basically PAYLOAD+SIGNATURE=PORT. You can use the same PORT on all servers.
# The system has been designed to be completely decentralized, so that your
# privacy is protected even if you want to host services on your systems.

# Get the payload and the signature from the PF API. This will grant you
# access to a random port, which you can activate on any server you connect to.
# If you already have a signature, and you would like to re-use that port,
# save the payload_and_signature received from your previous request
# in the env var PAYLOAD_AND_SIGNATURE, and that will be used instead.
if [[ -z $PAYLOAD_AND_SIGNATURE ]]; then
  echo -n "Getting new signature... "
  payload_and_signature="$(curl -s -m 5 \
    --connect-to "$PF_HOSTNAME::$PF_GATEWAY:" \
    --cacert "ca.rsa.4096.crt" \
    -G --data-urlencode "token=${PIA_TOKEN}" \
    "https://${PF_HOSTNAME}:19999/getSignature")"
else
  payload_and_signature=$PAYLOAD_AND_SIGNATURE
  echo -n "Checking the payload_and_signature from the env var... "
fi

# Check if the payload and the signature are OK.
# If they are not OK, just stop the script.
if [[ $(echo "$payload_and_signature" | jq -r '.status') != "OK" ]]; then
  echo -e "${red}The payload_and_signature variable does not contain an OK status.${nc}"
  exit 1
fi
echo -e "${green}OK!${nc}"

# We need to get the signature out of the previous response.
# The signature will allow us to bind the port on the server.
signature=$(echo "$payload_and_signature" | jq -r '.signature')

# The payload has a base64 format. We need to extract it from the
# previous response and also get the following information out:
# - port: This is the port you got access to
# - expires_at: this is the date+time when the port expires
payload=$(echo "$payload_and_signature" | jq -r '.payload')
port=$(echo "$payload" | base64 -d | jq -r '.port')

# The port normally expires after 2 months. If you consider
# 2 months is not enough for your setup, please open a ticket.
expires_at=$(echo "$payload" | base64 -d | jq -r '.expires_at')

echo -e "
Signature ${green}$signature${nc}
Payload   ${green}$payload${nc}

--> The port is ${green}$port${nc} and it will expire on ${red}$expires_at${nc}. <--
"

# Save the connection details so refresh_pia_port.sh (run from cron
# every 15 minutes) can keep the port bound without this script staying alive.
pf_filepath="$PIA_INFO_DIR/pf"
mkdir -p "$pf_filepath"
echo "$PF_HOSTNAME" > "$pf_filepath/PF_HOSTNAME"
echo "$PF_GATEWAY" > "$pf_filepath/PF_GATEWAY"
echo "$payload" > "$pf_filepath/payload"
echo "$signature" > "$pf_filepath/signature"
echo "$port" > "$pf_filepath/port"
echo "$expires_at" > "$pf_filepath/expires_at"
echo "Connection details saved to $pf_filepath/."

# Bind the port now; cron keeps it alive from here.
./refresh_pia_port.sh
