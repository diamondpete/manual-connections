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

banner connect_to_wireguard_with_token.sh
check_tool wg-quick wireguard-tools
check_tool curl
check_tool jq

# PIA currently does not support IPv6. On FreeBSD there are no
# net.ipv6.conf.* sysctls to flip; IPv6 leaking is prevented in the
# OpenVPN configs via pull-filter, and for WireGuard AllowedIPs
# only routes IPv4 (0.0.0.0/0).

# Check if the mandatory environment variables are set.
if [[ -z $WG_SERVER_IP || -z $WG_HOSTNAME || -z $PIA_TOKEN ]]; then
  echo -e "${red}This script requires 3 env vars:"
  echo "WG_SERVER_IP - IP that you want to connect to"
  echo "WG_HOSTNAME  - name of the server, required for ssl"
  echo "PIA_TOKEN    - your authentication token"
  echo
  echo "You can also specify optional env vars:"
  echo "PIA_PF                - enable port forwarding"
  echo "PAYLOAD_AND_SIGNATURE - In case you already have a port."
  echo
  echo "An easy solution is to just run ./run_setup.sh, which reads"
  echo -e "everything from $PIA_CONFIG and guides the full process.${nc}"
  exit 1
fi

# FreeBSD's wg-quick (wireguard-tools pkg) reads configs from
# /usr/local/etc/wireguard; Linux uses /etc/wireguard.
if [[ $(uname) == "FreeBSD" ]]; then
  wg_conf_dir="/usr/local/etc/wireguard"
else
  wg_conf_dir="/etc/wireguard"
fi

# Create ephemeral wireguard keys, that we don't need to save to disk.
privKey=$(wg genkey)
pubKey=$(echo "$privKey" | wg pubkey)

# Authenticate via the PIA WireGuard RESTful API.
# This will return a JSON with data required for authentication.
# The certificate is required to verify the identity of the VPN server.
# In case you want to troubleshoot the script, replace -s with -v.
echo "Trying to connect to the PIA WireGuard API on $WG_SERVER_IP..."
wireguard_json="$(curl -s -G \
  --connect-to "$WG_HOSTNAME::$WG_SERVER_IP:" \
  --cacert "ca.rsa.4096.crt" \
  --data-urlencode "pt=${PIA_TOKEN}" \
  --data-urlencode "pubkey=$pubKey" \
  "https://${WG_HOSTNAME}:1337/addKey")"
export wireguard_json

# Check if the API returned OK and stop this script if it didn't.
if [[ $(echo "$wireguard_json" | jq -r '.status') != "OK" ]]; then
  >&2 echo -e "${red}Server did not return OK. Stopping now.${nc}"
  exit 1
fi

# Multi-hop is out of the scope of this repo, but you should be able to
# get multi-hop running with both WireGuard and OpenVPN by playing with
# these scripts. Feel free to fork the project and test it out.
echo
echo "Trying to disable a PIA WG connection in case it exists..."
wg-quick down pia && echo -e "${green}PIA WG connection disabled!${nc}"
echo

# Create the WireGuard config based on the JSON received from the API.
# This uses a PersistentKeepalive of 25 seconds to keep the NAT active
# on firewalls. You can remove that line if your network does not
# require it.
if [[ $PIA_DNS == "true" ]]; then
  dnsServer=$(echo "$wireguard_json" | jq -r '.dns_servers[0]')
  echo "Trying to set up DNS to $dnsServer. In case you do not have resolvconf,"
  echo "this operation will fail and you will not get a VPN. If you have issues,"
  echo "set PIA_DNS=false in $PIA_CONFIG."
  echo
  dnsSettingForVPN="DNS = $dnsServer"
fi
echo -n "Trying to write $wg_conf_dir/pia.conf... "
mkdir -p "$wg_conf_dir"
echo "
[Interface]
Address = $(echo "$wireguard_json" | jq -r '.peer_ip')
PrivateKey = $privKey
$dnsSettingForVPN
[Peer]
PersistentKeepalive = 25
PublicKey = $(echo "$wireguard_json" | jq -r '.server_key')
AllowedIPs = 0.0.0.0/0
Endpoint = ${WG_SERVER_IP}:$(echo "$wireguard_json" | jq -r '.server_port')
" > "$wg_conf_dir/pia.conf" || exit 1
chmod 600 "$wg_conf_dir/pia.conf"
echo -e "${green}OK!${nc}"

# Start the WireGuard interface.
# If something failed, stop this script.
# If you get DNS errors because you miss some packages,
# just hardcode /etc/resolv.conf to "nameserver 10.0.0.242".
echo
echo "Trying to create the wireguard interface..."
wg-quick up pia || exit 1
echo -e "${green}The WireGuard interface got created.${nc}

At this point, internet should work via VPN.

To disconnect the VPN, run:

--> ${green}wg-quick down pia${nc} <--
"

# This section will stop the script if PIA_PF is not set to "true".
if [[ $PIA_PF != "true" ]]; then
  echo "If you want to also enable port forwarding, set PIA_PF=true"
  echo "in $PIA_CONFIG, or run:"
  echo -e "$ ${green}PIA_TOKEN=xxx PF_GATEWAY=$WG_SERVER_IP" \
    "PF_HOSTNAME=$WG_HOSTNAME ./port_forwarding.sh${nc}"
  echo
  echo "The location used must be port forwarding enabled, or this will fail."
  exit 0
fi

echo -n "This script got started with PIA_PF=true.
Allowing WireGuard to fully initialize, then starting port forwarding in "
for i in {5..1}; do
  echo -n "$i... "
  sleep 1
done
echo
echo

PIA_TOKEN=$PIA_TOKEN \
  PF_GATEWAY="$(echo "$wireguard_json" | jq -r '.server_vip')" \
  PF_HOSTNAME="$WG_HOSTNAME" \
  ./port_forwarding.sh
