# Manual PIA VPN Connections

### This is a FreeBSD/FreeNAS fork of the original Linux scripts at https://github.com/pia-foss/manual-connections.
Fork Notes:
1. **All settings live in one config file.** Copy `pia.conf.example` to `/pia-info/pia.conf`, `chmod 600` it, and edit. It holds the PIA credentials (`PIA_USER`/`PIA_PASS`), connection method (`PIA_AUTOCONNECT`: `wireguard`, `openvpn_udp_strong`, or `openvpn_tcp_strong`), port forwarding (`PIA_PF`), DNS (`PIA_DNS`), latency limit (`MAX_LATENCY`), an optional fixed region (`PREFERRED_REGION`), the OpenVPN tunnel device (`tunX`), and the Transmission settings (`TRANSMISSION_NOTIFY`, `transUser`, `transPass`). The old `/pia-info/pia_creds.txt` file is no longer used. You can point the scripts at a different config location with the `PIA_CONFIG` environment variable.
2. `run_setup.sh` is the script you call to start the whole process; it is fully non-interactive so it can run from cron. It calls `get_token.sh`, then `get_region.sh`, which hands off to the right connect script, which (with `PIA_PF=true`) hands off to `port_forwarding.sh` and finally `refresh_pia_port.sh`.
3. The forwarded port needs to be refreshed about every 15 minutes or PIA deletes it, so run `refresh_pia_port.sh` from cron (as `root`) inside the jail: `*/15 * * * * /pia/refresh_pia_port.sh > /pia-info/refresh.log 2>&1`. No tmux session needed; output lands in `/pia-info/refresh.log`.
4. `refresh_pia_port.sh` sends the forwarded port number to Transmission via `transmission-remote`. Set `TRANSMISSION_NOTIFY=false` in the config to disable this. It only notifies when the port actually changes (state is kept in `/pia-info/pf/transmission_port`); a failed notify is retried on the next refresh. Transmission should be running before you start the scripts. (OpenVPN should NOT be running, as the scripts configure and start it: `service openvpn stop`.)
5. If you have trouble, carefully read the output to see where it failed. Each script prints a header when it starts so you can see where you are (not `openvpn_up.sh` because it is run by OpenVPN). Should OpenVPN fail to start, the script prints `/pia-info/debug_info` to screen so you can see what went wrong. The scripts store all state in `/pia-info`.
6. For OpenVPN, the network interface is pinned to the `tunX` device from the config (default `tun0`). If that device already exists, the connect script kills the openvpn process that owns it (it asks first when run interactively) instead of silently creating another tun# — which would report success while your forwarded port goes nowhere.
7. I start `run_setup.sh` with an @reboot cron job inside the jail so it starts when the jail starts: `@reboot cd /pia && /pia/run_setup.sh > /pia-info/startup.log 2>&1`. This puts all the output in a log in `/pia-info`. If the jail just started, there shouldn't be any openvpn process or tun device, so that shouldn't be a problem.
8. Synced with upstream (Feb 2026): tokens now come from PIA's simple `v2/token` API endpoint (no more meta-server certificate dance), the server list moved to `v6`, and OpenVPN moved to ports 8080 (udp) / 8443 (tcp) with standard encryption removed — `strong.ovpn` is the only profile now. WireGuard configs are written to `/usr/local/etc/wireguard` on FreeBSD (`/etc/wireguard` on Linux).

End of Fork Notes

This repository contains documentation on how to create native WireGuard and OpenVPN connections to Private Internet Access' (PIA) __NextGen network__, and also on how to enable Port Forwarding in case you require this feature. You will find a lot of information below. However if you prefer quick test, here is the __TL/DR__:

```
git clone https://github.com/diamondpete/manual-connections.git pia
cd pia
mkdir -p /pia-info && cp pia.conf.example /pia-info/pia.conf
chmod 600 /pia-info/pia.conf   # then edit it with your settings
./run_setup.sh
```

### Dependencies

In order for the scripts to work (probably even if you do a manual setup), you will need the following packages:
 * `bash`
 * `curl`
 * `jq`
 * (only for WireGuard) `wireguard` kernel module
 * (only for OpenVPN) `openvpn`
 * (only for port forwarding) `base64`

### Disclaimers

 * Port Forwarding is disabled on server-side in the United States.
 * These scripts do not enforce IPv6 or DNS settings, so that you have the freedom to configure your setup the way you desire it to work. This means you should have good understanding of VPN and cybersecurity in order to properly configure your setup.
 * For battle-tested security, please use the official PIA App, as it was designed to protect you in all scenarios.
 * This repo is really fresh at this moment, so please take into consideration the fact that you will probably be one of the first users that use the scripts.

## PIA Port Forwarding

The PIA Port Forwarding service (a.k.a. PF) allows you run services on your own devices, and expose them to the internet by using the PIA VPN Network. The easiest way to set this up is by using a native PIA aplication. In case you require port forwarding on native clients, please follow this documentation in order to enable port forwarding for your VPN connection.

This service can be used only AFTER establishing a VPN connection.

## Automated setup of VPN and/or PF

In order to help you use VPN services and PF on any device, we have prepared a few bash scripts that should help you through the process of setting everything up. The scripts also contain a lot of comments, just in case you require detailed information regarding how the technology works. The functionality is controlled via environment variables, so that you have an easy time automating your setup.

Here is a list of scripts you could find useful:
 * [Run the whole setup](run_setup.sh): Reads `/pia-info/pia.conf` and drives all the scripts below, non-interactively.
 * [Get a token](get_token.sh): Authenticates with your `PIA_USER`/`PIA_PASS` and saves a 24-hour token to `/pia-info/token`.
 * [Get the best region](get_region.sh): Finds the lowest-latency region (or validates `PREFERRED_REGION`) and, based on `PIA_AUTOCONNECT`, triggers the WireGuard or OpenVPN connect script.
 * [Connect to WireGuard](connect_to_wireguard_with_token.sh): This script allows you to connect to the VPN server via WireGuard.
 * [Connect to OpenVPN](connect_to_openvpn_with_token.sh): This script allows you to connect to the VPN server via OpenVPN.
 * [Enable Port Forwarding](port_forwarding.sh): Enables you to add Port Forwarding to an existing VPN connection. Adding the environment variable `PIA_PF=true` to any of the previous scripts will also trigger this script.
 * [Refresh the forwarded port](refresh_pia_port.sh): Re-binds the port (run it from cron every 15 minutes) and pushes it to Transmission when it changes.

## Manual setup of PF

To use port forwarding on the NextGen network, first of all establish a connection with your favorite protocol. After this, you will need to find the private IP of the gateway you are connected to. In case you are WireGuard, the gateway will be part of the JSON response you get from the server, as you can see in the [bash script](https://github.com/pia-foss/manual-connections/blob/master/wireguard_and_pf.sh#L119). In case you are using OpenVPN, you can find the gateway by checking the routing table with `ip route s t all`.

After connecting and finding out what the gateway is, get your payload and your signature by calling `getSignature` via HTTPS on port 19999. You will have to add your token as a GET var to prove you actually have an active account.

Example:
```bash
bash-5.0# curl -k "https://10.4.128.1:19999/getSignature?token=$TOKEN"
{
    "status": "OK",
    "payload": "eyJ0b2tlbiI6Inh4eHh4eHh4eCIsInBvcnQiOjQ3MDQ3LCJjcmVhdGVkX2F0IjoiMjAyMC0wNC0zMFQyMjozMzo0NC4xMTQzNjk5MDZaIn0=",
    "signature": "a40Tf4OrVECzEpi5kkr1x5vR0DEimjCYJU9QwREDpLM+cdaJMBUcwFoemSuJlxjksncsrvIgRdZc0te4BUL6BA=="
}
```

The payload can be decoded with base64 to see your information:
```bash
$ echo eyJ0b2tlbiI6Inh4eHh4eHh4eCIsInBvcnQiOjQ3MDQ3LCJjcmVhdGVkX2F0IjoiMjAyMC0wNC0zMFQyMjozMzo0NC4xMTQzNjk5MDZaIn0= | base64 -d | jq 
{
  "token": "xxxxxxxxx",
  "port": 47047,
  "expires_at": "2020-06-30T22:33:44.114369906Z"
}
```
This is where you can also see the port you received. Please consider `expires_at` as your request will fail if the token is too old. All ports currently expire after 2 months.

Use the payload and the signature to bind the port on any server you desire. This is also done by curling the gateway of the VPN server you are connected to.
```bash
bash-5.0# curl -sGk --data-urlencode "payload=${payload}" --data-urlencode "signature=${signature}" https://10.4.128.1:19999/bindPort
{
    "status": "OK",
    "message": "port scheduled for add"
}
bash-5.0# 
```

Call __/bindPort__ every 15 minutes, or the port will be deleted!

### Testing your new PF

To test that it works, you can tcpdump on the port you received:

```
bash-5.0# tcpdump -ni any port 47047
```

After that, use curl on the IP of the traffic server and the port specified in the payload which in our case is `47047`:
```bash
$ curl "http://178.162.208.237:47047"
```

and you should see the traffic in your tcpdump:
```
bash-5.0# tcpdump -ni any port 47047
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on any, link-type LINUX_SLL (Linux cooked v1), capture size 262144 bytes
22:44:01.510804 IP 81.180.227.170.33884 > 10.4.143.34.47047: Flags [S], seq 906854496, win 64860, options [mss 1380,sackOK,TS val 2608022390 ecr 0,nop,wscale 7], length 0
22:44:01.510895 IP 10.4.143.34.47047 > 81.180.227.170.33884: Flags [R.], seq 0, ack 906854497, win 0, length 0
```

## License
This project is licensed under the [MIT (Expat) license](https://choosealicense.com/licenses/mit/), which can be found [here](/LICENSE).
