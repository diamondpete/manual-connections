#!/usr/bin/env bash
# Binds/refreshes the forwarded port and (optionally) tells Transmission
# about it. PIA deletes the forward if it isn't refreshed roughly every
# 15 minutes, so run this from cron:
#   */15 * * * * /pia/refresh_pia_port.sh > /pia-info/refresh.log 2>&1

export PATH="/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:/root/bin"

. "$(dirname "$0")/common.sh"

banner refresh_pia_port.sh
check_tool curl
check_tool jq

# Retrieve the connection details saved by port_forwarding.sh
pf_filepath="$PIA_INFO_DIR/pf"
if [[ ! -f $pf_filepath/port ]]; then
  echo -e "${red}No port forwarding details in $pf_filepath/."
  echo -e "Run ./run_setup.sh (with PIA_PF=true) first.${nc}"
  exit 1
fi
PF_HOSTNAME=$(cat "$pf_filepath/PF_HOSTNAME")
PF_GATEWAY=$(cat "$pf_filepath/PF_GATEWAY")
payload=$(cat "$pf_filepath/payload")
signature=$(cat "$pf_filepath/signature")
port=$(cat "$pf_filepath/port")
expires_at=$(cat "$pf_filepath/expires_at")

echo "PF_HOSTNAME: $PF_HOSTNAME"
echo "PF_GATEWAY:  $PF_GATEWAY"
echo "port:        $port"
echo "expires_at:  $expires_at"
echo

# Now we have all required data to create a request to bind the port.
# The servers have no mechanism to track your activity, so they will
# just delete the port forwarding if you don't send keepalives.
echo -n "Trying to bind the port... "
bind_port_response="$(curl -Gs -m 5 \
  --connect-to "$PF_HOSTNAME::$PF_GATEWAY:" \
  --cacert "ca.rsa.4096.crt" \
  --data-urlencode "payload=${payload}" \
  --data-urlencode "signature=${signature}" \
  "https://${PF_HOSTNAME}:19999/bindPort")"

# If the port did not bind, just exit the script.
# This script will start failing in 2 months, when the port expires.
if [[ $(echo "$bind_port_response" | jq -r '.status') != "OK" ]]; then
  echo
  echo "$bind_port_response"
  echo -e "${red}The API did not return OK when trying to bind the port."
  echo -e "Ports expire after two months; maybe that's why. Exiting.${nc}"
  exit 1
fi
echo -e "${green}OK!${nc}"
echo "Port $port refreshed on $(date). This port will expire on $expires_at."

# Tell Transmission about the port. Controlled by the config file:
# TRANSMISSION_NOTIFY enables/disables it, transUser/transPass authenticate.
# Only notify when the port actually changed; a failed notify is retried
# on the next refresh.
if [[ $TRANSMISSION_NOTIFY != "true" ]]; then
  echo "Transmission notification is disabled (TRANSMISSION_NOTIFY=$TRANSMISSION_NOTIFY)."
  exit 0
fi
if [[ -f $pf_filepath/transmission_port &&
      $(cat "$pf_filepath/transmission_port") == "$port" ]]; then
  echo "Transmission already has port $port."
  exit 0
fi

check_tool transmission-remote transmission-utils
auth_args=()
if [[ -n $transUser || -n $transPass ]]; then
  auth_args=(--auth "$transUser:$transPass")
fi
echo "Sending port $port to Transmission..."
if transmission-remote "${auth_args[@]}" -p "$port"; then
  echo "$port" > "$pf_filepath/transmission_port"
  echo -e "${green}Transmission peer port updated to $port.${nc}"
else
  echo -e "${red}Could not update Transmission; will retry on the next refresh.${nc}"
fi
