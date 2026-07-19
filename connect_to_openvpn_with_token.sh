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

banner connect_to_openvpn_with_token.sh
check_tool curl
check_tool jq
check_tool openvpn

# Check if a manual PIA OpenVPN connection is already initialized on the
# tunnel device from the config ($tunX). Multi-hop is out of scope.
pid_filepath="$PIA_INFO_DIR/pia_pid"
if ifconfig "$tunX" >/dev/null 2>&1; then
  echo -e "${red}The $tunX adapter already exists; that interface is required"
  echo -e "for this configuration.${nc}"
  if [[ -f $pid_filepath ]]; then
    old_pid=$(cat "$pid_filepath")
    old_pid_name=$(ps -p "$old_pid" -o comm=)
    if [[ $old_pid_name == "openvpn" ]]; then
      echo
      echo "It seems likely that process $old_pid is an OpenVPN connection"
      echo "that was established by using this script. Unless it is closed"
      echo "you would not be able to get a new connection."
      if [[ -t 0 ]]; then
        echo -n "Do you want to run $ kill $old_pid (Y/n): "
        read -r close_connection
      else
        # Unattended (cron): kill the stale connection and reconnect.
        echo "Not running interactively; killing it automatically."
        close_connection="y"
      fi
      if echo "${close_connection:0:1}" | grep -iq n; then
        echo -e "${red}Closing script. Resolve the $tunX adapter conflict and run the script again.${nc}"
        exit 1
      fi
      echo -e "${green}Killing the existing OpenVPN process and waiting 5 seconds...${nc}"
      kill "$old_pid"
      sleep 5
    fi
  fi
fi

# PIA currently does not support IPv6. On FreeBSD there are no
# net.ipv6.conf.* sysctls to flip; IPv6 is instead kept out of the
# tunnel via the pull-filter lines in openvpn_config/strong.ovpn.

# Check if the mandatory environment variables are set.
if [[ -z $OVPN_SERVER_IP ||
      -z $OVPN_HOSTNAME ||
      -z $PIA_TOKEN ||
      -z $CONNECTION_SETTINGS ]]; then
  echo -e "${red}This script requires 4 env vars:"
  echo "PIA_TOKEN           - the token used for authentication"
  echo "OVPN_SERVER_IP      - IP that you want to connect to"
  echo "OVPN_HOSTNAME       - name of the server, required for ssl"
  echo "CONNECTION_SETTINGS - the protocol and encryption specification"
  echo "                    - available options for CONNECTION_SETTINGS are:"
  echo "                        * openvpn_udp_strong"
  echo "                        * openvpn_tcp_strong"
  echo
  echo "You can also specify optional env vars:"
  echo "PIA_PF                - enable port forwarding"
  echo "PAYLOAD_AND_SIGNATURE - In case you already have a port."
  echo
  echo "An easy solution is to just run ./run_setup.sh, which reads"
  echo -e "everything from $PIA_CONFIG and guides the full process.${nc}"
  exit 1
fi

# Create a credentials file with the login token
echo -n "Trying to write $PIA_INFO_DIR/pia.ovpn... "
mkdir -p "$PIA_INFO_DIR"
rm -f "$PIA_INFO_DIR/credentials" "$PIA_INFO_DIR/route_info"
echo "${PIA_TOKEN:0:62}
${PIA_TOKEN:62}" > "$PIA_INFO_DIR/credentials" || exit 1
chmod 600 "$PIA_INFO_DIR/credentials"

# Translate connection settings variable
IFS='_' read -ra connection_settings <<< "$CONNECTION_SETTINGS"
protocol=${connection_settings[1]}

# PIA moved OpenVPN to these ports and removed standard encryption,
# so strong.ovpn is the only profile.
if [[ $protocol == "udp" ]]; then
  port=8080
else
  port=8443
fi

# Create the OpenVPN config based on the settings specified,
# pinning the tunnel device to $tunX from the config.
sed "s/^dev tun$/dev $tunX/" openvpn_config/strong.ovpn > "$PIA_INFO_DIR/pia.ovpn" || exit 1
echo "remote $OVPN_SERVER_IP $port $protocol" >> "$PIA_INFO_DIR/pia.ovpn"
echo -e "${green}OK!${nc}"

# Copy the up/down scripts to $PIA_INFO_DIR
# based upon use of PIA DNS
if [[ $PIA_DNS != "true" ]]; then
  cp openvpn_config/openvpn_up.sh "$PIA_INFO_DIR/"
  cp openvpn_config/openvpn_down.sh "$PIA_INFO_DIR/"
  echo "This configuration will not use PIA DNS."
  echo "If you want to enable PIA DNS, set PIA_DNS=true in $PIA_CONFIG."
else
  cp openvpn_config/openvpn_up_dnsoverwrite.sh "$PIA_INFO_DIR/openvpn_up.sh"
  cp openvpn_config/openvpn_down_dnsoverwrite.sh "$PIA_INFO_DIR/openvpn_down.sh"
fi
chmod +x "$PIA_INFO_DIR/openvpn_up.sh" "$PIA_INFO_DIR/openvpn_down.sh"

# Start the OpenVPN interface.
# If something failed, stop this script.
# If you get DNS errors because you miss some packages,
# just hardcode /etc/resolv.conf to "nameserver 10.0.0.242".
echo "
Trying to start the OpenVPN connection..."
openvpn --daemon \
  --config "$PIA_INFO_DIR/pia.ovpn" \
  --writepid "$pid_filepath" \
  --log "$PIA_INFO_DIR/debug_info" || exit 1

echo -n "
The OpenVPN connect command was issued.

Confirming OpenVPN connection state... "

# Check if manual PIA OpenVPN connection is initialized.
# Manually adjust the connection_wait_time if needed
connection_wait_time=10
confirmation="Initialization Sequence Complete"
for (( timeout=0; timeout <= connection_wait_time; timeout++ )); do
  sleep 1
  if grep -q "$confirmation" "$PIA_INFO_DIR/debug_info"; then
    connected=true
    break
  fi
done

ovpn_pid=$(cat "$pid_filepath")

# Report and exit if connection was not initialized within 10 seconds.
if [[ $connected != "true" ]]; then
  echo -e "${red}The VPN connection was not established within 10 seconds.${nc}"
  kill "$ovpn_pid"
  echo
  echo "OpenVPN debug info from $PIA_INFO_DIR/debug_info:"
  cat "$PIA_INFO_DIR/debug_info"
  exit 1
fi

gateway_ip=$(cat "$PIA_INFO_DIR/route_info")

echo -e "${green}Initialization Sequence Complete!${nc}

At this point, internet should work via VPN.
"
echo -e "OpenVPN Process ID: ${green}$ovpn_pid${nc}
VPN route IP: ${green}$gateway_ip${nc}

To disconnect the VPN, run:

--> ${green}sudo kill $ovpn_pid${nc} <--
"

# This section will stop the script if PIA_PF is not set to "true".
if [[ $PIA_PF != "true" ]]; then
  echo "If you want to also enable port forwarding, set PIA_PF=true"
  echo "in $PIA_CONFIG, or run:"
  echo -e "$ ${green}PIA_TOKEN=xxx PF_GATEWAY=$gateway_ip" \
    "PF_HOSTNAME=$OVPN_HOSTNAME ./port_forwarding.sh${nc}"
  echo
  echo "The location used must be port forwarding enabled, or this will fail."
  exit 0
fi

echo -n "This script got started with PIA_PF=true.
Starting port forwarding in "
for i in {5..1}; do
  echo -n "$i... "
  sleep 1
done
echo
echo

PIA_TOKEN=$PIA_TOKEN \
  PF_GATEWAY=$gateway_ip \
  PF_HOSTNAME=$OVPN_HOSTNAME \
  ./port_forwarding.sh
