#!/usr/bin/env bash

# Remove process and route information when connection closes
rm -f /pia-info/pia_pid /pia-info/route_info

# Replace resolv.conf with original stored as backup
cat /pia-info/resolv_conf_backup > /etc/resolv.conf
