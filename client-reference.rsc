# ============================================================
# MikroTik hAP lite - REFERENCE CONFIGURATION: CLIENT (client site)
# ============================================================
# Standard client site: devices at this location connect over
# WiFi/LAN and reach the internet through the WireGuard tunnel to
# the server, so the exit service sees them coming from the exit
# site's IP.
#
# Replace every <PLACEHOLDER> with a real value before importing.
# Never reuse keys or passwords from another router - every site
# needs its own WireGuard keypair.
# ============================================================

/interface bridge
add name=bridge port-cost-mode=short

/interface wireguard
add listen-port=13231 mtu=1420 name=wireguard

/interface wireless security-profiles
set [find default=yes] supplicant-identity=MikroTik
add authentication-types=wpa2-psk mode=dynamic-keys name=wlan_passwd \
    supplicant-identity="" wpa2-pre-shared-key="<UNIQUE_WIFI_PASSWORD_PER_SITE>"
# WPA2-PSK only (no WPA-PSK) - the hAP lite doesn't support WPA3, so
# WPA2 with AES is the best this hardware can do.

/interface wireless
set [find default-name=wlan1] band=2ghz-b/g/n country=<YOUR_COUNTRY> disabled=no \
    mode=ap-bridge name=wlan security-profile=wlan_passwd \
    ssid="<NEUTRAL_SSID_NOT_GIVING_AWAY_THE_PURPOSE>"

/ip pool
add name=wlan_dhcp_pool ranges=192.168.88.2-192.168.88.254

/ip dhcp-server
add address-pool=wlan_dhcp_pool interface=bridge lease-time=10m name=wlan_dhcp

/interface bridge port
add bridge=bridge interface=wlan internal-path-cost=10 path-cost=10
add bridge=bridge interface=ether2 internal-path-cost=10 path-cost=10
add bridge=bridge interface=ether3 internal-path-cost=10 path-cost=10
add bridge=bridge interface=ether4 internal-path-cost=10 path-cost=10

/ip firewall connection tracking
set udp-timeout=10s

# ------------------------------------------------------------
# A single peer: the server. allowed-address=0.0.0.0/0 because we
# want full-tunnel (all of this site's traffic through the VPN).
# persistent-keepalive is essential: this router sits behind your
# ISP router's NAT, and without this the NAT mapping expires and
# the tunnel keeps dropping and reconnecting.
# ------------------------------------------------------------
/interface wireguard peers
add allowed-address=0.0.0.0/0 endpoint-address=<SERVER_DDNS_HOSTNAME> \
    endpoint-port=13231 interface=wireguard persistent-keepalive=25s \
    public-key="<SERVER_PUBLIC_KEY>"

/ip address
add address=192.168.88.1/24 interface=bridge network=192.168.88.0
add address=172.16.0.<N>/24 interface=wireguard network=172.16.0.0

/ip dhcp-client
add default-route-distance=2 interface=ether1

/ip dhcp-server network
add address=192.168.88.0/24 dns-server=8.8.8.8 gateway=192.168.88.1

/ip dns
set servers=8.8.8.8

/ip firewall nat
add action=masquerade chain=srcnat src-address=192.168.88.0/24

/ip firewall filter
add chain=input action=accept connection-state=established,related \
    comment="Replies to connections this router itself started"
add chain=input action=accept in-interface=bridge \
    comment="Allow management from the local network"
add chain=input action=accept in-interface=wireguard \
    comment="Allow management over the VPN tunnel"
add chain=input action=accept protocol=udp dst-port=13231 in-interface=ether1 \
    comment="Allow the raw WireGuard handshake, which arrives on ether1"
add chain=input action=accept protocol=udp src-port=67 dst-port=68 \
    in-interface=ether1 comment="Allow DHCP replies from the ISP"
add chain=input action=accept protocol=icmp comment="Allow ping"
add chain=input action=drop in-interface=ether1 \
    comment="Drop anything else arriving from the internet"

/ip firewall mangle
add chain=forward protocol=tcp tcp-flags=syn action=change-mss \
    new-mss=clamp-to-pmtu passthrough=yes comment="MSS clamp WG"

# ------------------------------------------------------------
# Route to the server over the REAL path (not the tunnel, or there
# would be a routing loop) and a default route through the tunnel
# unless it's down (see the CheckWireGuard script below).
# ------------------------------------------------------------
/ip route
add comment=vpn disabled=no distance=1 dst-address=<SERVER_CURRENT_PUBLIC_IP> \
    gateway=<THIS_SITE_LOCAL_GATEWAY> pref-src="" routing-table=main \
    suppress-hw-offload=no
add disabled=no distance=1 dst-address=0.0.0.0/0 gateway=172.16.0.1 \
    pref-src="" routing-table=main scope=30 suppress-hw-offload=no \
    target-scope=10

/system clock
set time-zone-name=<YOUR_TIMEZONE>

/system identity
set name="MikroTik <SiteName>"

/system note
set show-at-login=no

/system scheduler
add interval=5m name=CheckServerIP on-event=CheckServerIP start-time=startup \
    policy=ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon
add interval=30s name=CheckWireGuard on-event=CheckWireGuard start-time=startup \
    policy=ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon

# ------------------------------------------------------------
# CheckServerIP: keeps the "vpn" route pointed at the server's
# current public IP (which can change - it's DDNS) and at the
# right local gateway.
# ------------------------------------------------------------
/system script
add name=CheckServerIP owner=admin dont-require-permissions=no \
    policy=ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon \
    source={
        :local resolvedIP [:resolve "<SERVER_DDNS_HOSTNAME>"];
        :local ipaddress [/ip route get [/ip route find where comment=vpn] dst-address];
        :local currentIP [:pick $ipaddress 0 [:find $ipaddress "/"]];
        :local routeID [/ip route find comment="vpn"];
        :if ($resolvedIP != $currentIP) do={
            /ip route set $routeID dst-address=$resolvedIP;
        }
        :local dhcpGW [/ip route get [/ip route find where dst-address=0.0.0.0/0 and distance=2] gateway];
        :local gwIP [/ip route get [/ip route find where comment=vpn] gateway];
        :if ($dhcpGW != $gwIP) do={
            /ip route set $routeID gateway=$dhcpGW;
        }
    }

# ------------------------------------------------------------
# CheckWireGuard: adjusts the default route's distance depending on
# whether the tunnel responds, to fall back to the direct connection
# when the tunnel is down, and prefer the tunnel again once it's back.
#
# Uses a global lock so two overlapping runs can't race each other
# if the ping is slow under an unstable link, and checks the route
# exists before touching it - avoids a "no such item" error under an
# unstable tunnel.
# ------------------------------------------------------------
add name=CheckWireGuard owner=admin dont-require-permissions=no \
    policy=ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon \
    source={
        :local routeGW "172.16.0.1";
        :local vpnConnectedDistance 1;
        :local vpnDisconnectedDistance 3;
        :global checkWgRunning;
        :if ([:typeof $checkWgRunning] = "nothing") do={ :set checkWgRunning false };
        :if ($checkWgRunning = true) do={
            :log warning "CheckWireGuard: previous run still in progress, skipping";
        } else={
            :set checkWgRunning true;
            :local pingResult [/ping $routeGW count=3];
            :local routeId [/ip route find where gateway=$routeGW];
            :if ([:len $routeId] > 0) do={
                :if ($pingResult > 0) do={
                    /ip route set $routeId distance=$vpnConnectedDistance;
                    :log info "VPN connected. Route updated with distance $vpnConnectedDistance";
                } else={
                    /ip route set $routeId distance=$vpnDisconnectedDistance;
                    :log info "VPN disconnected. Route updated with distance $vpnDisconnectedDistance";
                }
            } else={
                :log warning "CheckWireGuard: no route found with gateway $routeGW";
            }
            :set checkWgRunning false;
        }
    }
