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

banner get_region.sh
check_tool curl
check_tool jq

export MAX_LATENCY
latencyList="$PIA_INFO_DIR/latencyList"
export latencyList
mkdir -p "$PIA_INFO_DIR"
rm -f "$latencyList"
touch "$latencyList"

serverlist_url='https://serverlist.piaservers.net/vpninfo/servers/v6'

# This function checks the latency you have to a specific region.
# It will print a human-readable message to stderr,
# and it will print the variables to stdout
printServerLatency() {
  serverIP=$1
  regionID=$2
  regionName="$(echo "${@:3}" |
    sed 's/ false//' | sed 's/true/(geo)/')"
  time=$(LC_NUMERIC=en_US.utf8 curl -o /dev/null -s \
    --connect-timeout "$MAX_LATENCY" \
    --write-out "%{time_connect}" \
    "http://$serverIP:443")
  if [[ $? -eq 0 ]]; then
    >&2 echo "Got latency ${time}s for region: $regionName"
    echo "$time $regionID $serverIP"
    # Keep a list of every server with acceptable latency for reference.
    echo -e "$time" "$regionID"'\t'"$serverIP"'\t'"$regionName" >> "$latencyList"
  fi
  sort -no "$latencyList" "$latencyList"
}
export -f printServerLatency

echo -n "Getting the server list... "
# Get all region data since we will need this on multiple occasions
all_region_data=$(curl -s "$serverlist_url" | head -1)

# If the server list has less than 1000 characters, it means curl failed.
if [[ ${#all_region_data} -lt 1000 ]]; then
  echo -e "${red}Could not get correct region data. To debug this, run:"
  echo "$ curl -v $serverlist_url"
  echo -e "If it works, you will get a huge JSON as a response.${nc}"
  exit 1
fi
echo -e "${green}OK!${nc}"

# just making sure this variable doesn't contain some strange string
if [[ $PIA_PF != "true" ]]; then
  PIA_PF="false"
fi

if [[ -n $PREFERRED_REGION ]]; then
  # Use the region from the config instead of latency testing.
  selectedRegion=$PREFERRED_REGION
  echo "Using PREFERRED_REGION=$selectedRegion from the config."
else
  # Test one server from each region to get the closest region.
  # If port forwarding is enabled, filter out regions that don't support it.
  if [[ $PIA_PF == "true" ]]; then
    echo "Port Forwarding is enabled, non-PF regions excluded."
    summarized_region_data="$( echo "$all_region_data" |
      jq -r '.regions[] | select(.port_forward==true) |
      .servers.meta[0].ip+" "+.id+" "+.name+" "+(.geo|tostring)' )"
  else
    summarized_region_data="$( echo "$all_region_data" |
      jq -r '.regions[] |
      .servers.meta[0].ip+" "+.id+" "+.name+" "+(.geo|tostring)' )"
  fi
  echo -e "Testing regions that respond faster than ${green}$MAX_LATENCY${nc} seconds:"
  selectedRegion="$(echo "$summarized_region_data" |
    xargs -I{} bash -c 'printServerLatency {}' |
    sort | head -1 | awk '{ print $2 }')"

  if [[ -z $selectedRegion ]]; then
    echo -e "${red}No region responded within ${MAX_LATENCY}s, consider a higher timeout."
    echo "For example, set MAX_LATENCY=1 in $PIA_CONFIG to wait 1 second"
    echo -e "for each region.${nc}"
    exit 1
  fi
  echo
  echo "A list of servers and connection details, ordered by latency,"
  echo -e "can be found at: ${green}$latencyList${nc}"
fi

# Get all data for the selected region
regionData="$( echo "$all_region_data" |
  jq --arg REGION_ID "$selectedRegion" -r \
  '.regions[] | select(.id==$REGION_ID)')"
if [[ -z $regionData ]]; then
  echo -e "${red}The region id '$selectedRegion' is not valid.${nc}"
  echo "Check PREFERRED_REGION in $PIA_CONFIG. List all region ids with:"
  echo "$ curl -s $serverlist_url | head -1 | jq -r '.regions[].id'"
  exit 1
fi

echo -ne "The selected region is ${green}$(echo "$regionData" | jq -r '.name')${nc}"
if echo "$regionData" | jq -r '.geo' | grep true > /dev/null; then
  echo " (geolocated region)."
else
  echo "."
fi
echo

bestServer_meta_IP=$(echo "$regionData" | jq -r '.servers.meta[0].ip')
bestServer_meta_hostname=$(echo "$regionData" | jq -r '.servers.meta[0].cn')
bestServer_WG_IP=$(echo "$regionData" | jq -r '.servers.wg[0].ip')
bestServer_WG_hostname=$(echo "$regionData" | jq -r '.servers.wg[0].cn')
bestServer_OT_IP=$(echo "$regionData" | jq -r '.servers.ovpntcp[0].ip')
bestServer_OT_hostname=$(echo "$regionData" | jq -r '.servers.ovpntcp[0].cn')
bestServer_OU_IP=$(echo "$regionData" | jq -r '.servers.ovpnudp[0].ip')
bestServer_OU_hostname=$(echo "$regionData" | jq -r '.servers.ovpnudp[0].cn')

echo -e "The script found the best servers from the region selected.
When connecting to an IP (no matter which protocol), please verify
the SSL/TLS certificate actually contains the hostname so that you
are sure you are connecting to a secure server, validated by the
PIA authority. Please find below the list of best IPs and matching
hostnames for each protocol:
${green}Meta Services $bestServer_meta_IP\t-     $bestServer_meta_hostname
WireGuard     $bestServer_WG_IP\t-     $bestServer_WG_hostname
OpenVPN TCP   $bestServer_OT_IP\t-     $bestServer_OT_hostname
OpenVPN UDP   $bestServer_OU_IP\t-     $bestServer_OU_hostname
${nc}"

# A token is required to connect; get_token.sh creates one.
if [[ -z $PIA_TOKEN ]]; then
  if [[ -f $PIA_INFO_DIR/token ]]; then
    PIA_TOKEN=$(head -1 "$PIA_INFO_DIR/token")
    export PIA_TOKEN
    echo "Using the token from $PIA_INFO_DIR/token."
  else
    echo -e "${red}No PIA_TOKEN found. Run ./get_token.sh (or ./run_setup.sh) first.${nc}"
    exit 1
  fi
fi

# The old openvpn_*_standard options were removed by PIA; map them to strong.
if [[ $PIA_AUTOCONNECT == *standard ]]; then
  echo -e "${red}PIA removed standard encryption; using ${PIA_AUTOCONNECT%standard}strong instead.${nc}"
  PIA_AUTOCONNECT="${PIA_AUTOCONNECT%standard}strong"
fi

if [[ $PIA_AUTOCONNECT == wireguard ]]; then
  echo "PIA_AUTOCONNECT=wireguard, so we will connect via WireGuard by running:"
  echo -e "$ ${green}PIA_PF=$PIA_PF PIA_TOKEN=xxx \\"
  echo "  WG_SERVER_IP=$bestServer_WG_IP WG_HOSTNAME=$bestServer_WG_hostname \\"
  echo -e "  ./connect_to_wireguard_with_token.sh${nc}"
  echo
  PIA_PF=$PIA_PF PIA_TOKEN=$PIA_TOKEN WG_SERVER_IP=$bestServer_WG_IP \
    WG_HOSTNAME=$bestServer_WG_hostname ./connect_to_wireguard_with_token.sh
  exit 0
fi

if [[ $PIA_AUTOCONNECT == openvpn* ]]; then
  serverIP=$bestServer_OU_IP
  serverHostname=$bestServer_OU_hostname
  if [[ $PIA_AUTOCONNECT == *tcp* ]]; then
    serverIP=$bestServer_OT_IP
    serverHostname=$bestServer_OT_hostname
  fi
  echo "PIA_AUTOCONNECT=$PIA_AUTOCONNECT, so we will connect via OpenVPN by running:"
  echo -e "$ ${green}PIA_PF=$PIA_PF PIA_TOKEN=xxx \\"
  echo "  OVPN_SERVER_IP=$serverIP \\"
  echo "  OVPN_HOSTNAME=$serverHostname \\"
  echo "  CONNECTION_SETTINGS=$PIA_AUTOCONNECT \\"
  echo -e "  ./connect_to_openvpn_with_token.sh${nc}"
  echo
  PIA_PF=$PIA_PF PIA_TOKEN=$PIA_TOKEN \
    OVPN_SERVER_IP=$serverIP \
    OVPN_HOSTNAME=$serverHostname \
    CONNECTION_SETTINGS=$PIA_AUTOCONNECT \
    ./connect_to_openvpn_with_token.sh
  exit 0
fi

echo "If you wish to automatically connect to the VPN after detecting the best"
echo "region, set PIA_AUTOCONNECT in $PIA_CONFIG. The available options are:"
echo " - wireguard"
echo " - openvpn_udp_strong"
echo " - openvpn_tcp_strong"
echo "You can also set PIA_PF=true there to get port forwarding."
echo
echo "You can connect manually now by running:"
echo "$ PIA_TOKEN=xxx WG_SERVER_IP=$bestServer_WG_IP \\"
echo "  WG_HOSTNAME=$bestServer_WG_hostname ./connect_to_wireguard_with_token.sh"
