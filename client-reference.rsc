# ============================================================
# MikroTik hAP lite - REFERENCE CONFIGURATION: CLIENT (client site)
# ============================================================
# Standard client site: devices at this location connect over WiFi/LAN
# and reach the internet through the WireGuard tunnel to the server, so
# the streaming service sees them coming from the exit site's IP.
#
# A client site has no input firewall (see below), so there is nothing
# here that needs an interface list to abstract the uplink. Exactly two
# places name it: the DHCP client, and the wanIf variable inside the
# CheckWanLink script. Switching from a wired to a wireless uplink means
# changing those two - see "ALTERNATIVE: UPLINK OVER WIFI" at the end.
#
# Replace every <PLACEHOLDER> with a real value before importing.
# Never reuse keys or passwords from another router - every site needs
# its own WireGuard keypair and its own WiFi credentials.
#
# Do NOT hardcode MAC addresses. If you build a site by restoring
# another site's backup you will end up with duplicate MACs across
# houses, which is a latent conflict waiting to happen.
# ============================================================

# ---- Uplink definition (wired by default; see alternative at the end) ----
/ip dhcp-client
add default-route-distance=2 interface=ether1

# ---- LAN ----
/interface bridge
add name=bridge port-cost-mode=short

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

/ip dhcp-server network
add address=192.168.88.0/24 dns-server=8.8.8.8 gateway=192.168.88.1

/ip address
add address=192.168.88.1/24 interface=bridge network=192.168.88.0
add address=172.16.0.<N>/24 interface=wireguard network=172.16.0.0

/ip dns
set servers=8.8.8.8

# ---- WireGuard ----
/interface wireguard
add listen-port=13231 mtu=1420 name=wireguard

# A single peer: the server. allowed-address=0.0.0.0/0 because we want
# full-tunnel (all of this site's traffic through the VPN).
#
# persistent-keepalive is essential HERE, on the client: this router
# sits behind the ISP router's NAT, and without it the NAT mapping
# expires and the tunnel keeps dropping and reconnecting. Do not set it
# on the server side - there it only produces futile handshake retries.
/interface wireguard peers
add allowed-address=0.0.0.0/0 name="VPN Server" endpoint-address=<SERVER_DDNS_HOSTNAME> \
    endpoint-port=13231 interface=wireguard persistent-keepalive=25s \
    public-key="<SERVER_PUBLIC_KEY>"

/ip firewall nat
add action=masquerade chain=srcnat src-address=192.168.88.0/24

/ip firewall mangle
add chain=forward protocol=tcp tcp-flags=syn action=change-mss \
    new-mss=clamp-to-pmtu passthrough=yes comment="MSS clamp WG"

# ---- No /ip firewall filter here, on purpose ----
# This router sits behind the ISP-provided router, which NATs and
# forwards nothing to it, so its management services are not reachable
# from the internet in the first place. A "drop everything from the
# uplink" ruleset would therefore protect against an exposure that
# doesn't exist, while carrying a real risk of locking you out of a
# device in someone else's house. Disabling the services you don't use
# (below) gets you the same practical benefit with no such risk.
/ip service
# telnet and ftp are cleartext; the API isn't used here. www is WebFig,
# the router's web interface - only disable it if you never administer
# the box from a browser.
set telnet disabled=yes
set ftp disabled=yes
set api disabled=yes
set api-ssl disabled=yes

# ---- Routing ----
# Route to the server over the REAL path (not the tunnel, or there would
# be a routing loop) and a default route through the tunnel unless it's
# down (see the CheckWireGuard script below).
/ip route
add comment=vpn disabled=no distance=1 dst-address=<SERVER_CURRENT_PUBLIC_IP> \
    gateway=<THIS_SITE_LOCAL_GATEWAY> pref-src="" routing-table=main \
    suppress-hw-offload=no
add disabled=no distance=1 dst-address=0.0.0.0/0 gateway=172.16.0.1 \
    pref-src="" routing-table=main scope=30 suppress-hw-offload=no \
    target-scope=10

/tool bandwidth-server
set enabled=no
# Disabled: unused, and it has caused real damage here. A failed UDP test
# left the btest process burning CPU on hardware with none to spare, and
# the tool itself crashed two routers with out-of-memory reboots.

/system clock
set time-zone-name=<YOUR_TIMEZONE>

/system identity
set name="MikroTik <SiteName>"

/system routerboard settings
set auto-upgrade=no
# Keep this off so a RouterBOOT flash never happens during an unplanned
# reboot in a house you can't reach. Do it deliberately instead.

/system scheduler
add interval=5m name=CheckServerIP on-event=CheckServerIP start-time=startup \
    policy=ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon
add interval=30s name=CheckWireGuard on-event=CheckWireGuard start-time=startup \
    policy=ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon
add interval=1m name=CheckWanLink on-event=CheckWanLink start-time=startup \
    policy=ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon

/system script
# CheckServerIP: keeps the "vpn" route pointed at the server's current
# public IP (it's behind DDNS) and at the right local gateway.
# Every find is checked before the get, and DNS resolution is wrapped in
# :do/on-error. Without those guards this script throws on every run
# exactly when the uplink is down - i.e. when you most need it to work.
add name=CheckServerIP owner=admin dont-require-permissions=no \
    policy=ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon \
    source={
        :local vpnHost "<SERVER_DDNS_HOSTNAME>";
        :local routeID [/ip route find comment="vpn"];
        :if ([:len $routeID] = 0) do={
            :log warning "CheckServerIP: no route with comment=vpn";
        } else={
            :local resolvedIP "";
            :do { :set resolvedIP [:resolve $vpnHost]; } on-error={ :log warning "CheckServerIP: DNS resolution failed" };
            :if ([:typeof $resolvedIP] = "ip") do={
                :local ipaddress [/ip route get ($routeID->0) dst-address];
                :local currentIP [:pick $ipaddress 0 [:find $ipaddress "/"]];
                :if ($resolvedIP != $currentIP) do={
                    /ip route set $routeID dst-address=$resolvedIP;
                    :log info "CheckServerIP: vpn route dst-address updated to $resolvedIP";
                }
                :local dhcpRoute [/ip route find where dst-address=0.0.0.0/0 and distance=2];
                :if ([:len $dhcpRoute] = 0) do={
                    :log warning "CheckServerIP: no DHCP default route, uplink may be down";
                } else={
                    :local dhcpGW [/ip route get ($dhcpRoute->0) gateway];
                    :local gwIP [/ip route get ($routeID->0) gateway];
                    :if ($dhcpGW != $gwIP) do={
                        /ip route set $routeID gateway=$dhcpGW;
                        :log info "CheckServerIP: vpn route gateway updated to $dhcpGW";
                    }
                }
            }
        }
    }

# CheckWireGuard: adjusts the default route's distance depending on
# whether the tunnel responds, so the site falls back to its direct
# connection when the tunnel is down and prefers the tunnel again once
# it's back. It only writes and logs when the state actually changes:
# logging every run buries real events under thousands of identical lines
# a day, which is exactly how a broken automation went unnoticed here.
# Deliberately has no concurrency lock: the find-before-get
# guard already makes overlapping runs harmless, and a boolean lock with
# no expiry is worse than the race it prevents - if the run holding it
# dies, the lock stays set and the failover is silently disabled forever.
add name=CheckWireGuard owner=admin dont-require-permissions=no \
    policy=ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon \
    source={
        :local routeGW "172.16.0.1";
        :local vpnConnectedDistance 1;
        :local vpnDisconnectedDistance 3;
        :local pingResult [/ping $routeGW count=3];
        :local routeId [/ip route find where gateway=$routeGW];
        :if ([:len $routeId] > 0) do={
            :local want $vpnDisconnectedDistance;
            :if ($pingResult > 0) do={ :set want $vpnConnectedDistance };
            :local cur [/ip route get ($routeId->0) distance];
            :if ($cur != $want) do={
                /ip route set $routeId distance=$want;
                :if ($want = $vpnConnectedDistance) do={
                    :log info "CheckWireGuard: tunnel up, default route via VPN";
                } else={
                    :log warning "CheckWireGuard: tunnel DOWN, falling back to local ISP";
                }
            }
        } else={
            :log warning "CheckWireGuard: no route found with gateway $routeGW";
        }
    }

# CheckWanLink: uplink watchdog. If the DHCP client stops being "bound",
# restart it after 3 minutes and reboot the router after 30. This is the
# failure mode that leaves a remote router unreachable: with no address
# on the uplink there is no route, no tunnel and no way back in.
# Change wanIf to wlan1 if you use the WiFi uplink variant below.
add name=CheckWanLink owner=admin dont-require-permissions=no \
    policy=ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon \
    source={
        :local wanIf "ether1";
        :global wanFailCount;
        :if ([:typeof $wanFailCount] = "nothing") do={ :set wanFailCount 0 };
        :local dhcpId [/ip dhcp-client find where interface=$wanIf];
        :if ([:len $dhcpId] = 0) do={
            :log warning "CheckWanLink: no dhcp-client on $wanIf";
        } else={
            :local st [/ip dhcp-client get ($dhcpId->0) status];
            :if ($st = "bound") do={
                :if ($wanFailCount > 0) do={ :log info "CheckWanLink: $wanIf recovered, status=$st" };
                :set wanFailCount 0;
            } else={
                :set wanFailCount ($wanFailCount + 1);
                :log warning "CheckWanLink: $wanIf status=$st, fail count=$wanFailCount";
                :if ($wanFailCount = 3) do={
                    :log warning "CheckWanLink: restarting dhcp-client on $wanIf";
                    /ip dhcp-client disable $dhcpId;
                    :delay 5s;
                    /ip dhcp-client enable $dhcpId;
                }
                :if ($wanFailCount >= 30) do={
                    :log error "CheckWanLink: no lease after 30 checks, rebooting";
                    :set wanFailCount 0;
                    /system reboot;
                }
            }
        }
    }

# ============================================================
# ALTERNATIVE: UPLINK OVER WIFI
# ============================================================
# Use this when the client router reaches the ISP router over WiFi
# instead of a cable. Everything above stays as it is except the uplink
# block: wlan1 becomes a station joining the ISP router's network, and
# it is what goes into the WAN list.
#
# The hAP lite has a SINGLE radio, and in a client site that radio is
# already busy being the access point the TVs connect to. That conflict
# is the whole difficulty here, and there are two ways out.
#
# ---- Option A (recommended): WiFi uplink, wired LAN ----
# wlan1 joins the ISP router; local devices connect by cable. Fully
# supported, no tricks, no throughput penalty. ether1 is freed up and
# can join the bridge, so you get 4 LAN ports instead of 3. For a TV
# that doesn't move, a cable is usually perfectly workable.
#
#   /interface wireless security-profiles
#   add name=isp_uplink mode=dynamic-keys authentication-types=wpa2-psk \
#       wpa2-pre-shared-key="<ISP_WIFI_PASSWORD>"
#
#   /interface wireless
#   set [find default-name=wlan1] mode=station ssid="<ISP_WIFI_SSID>" \
#       security-profile=isp_uplink band=2ghz-b/g/n country=<YOUR_COUNTRY> \
#       disabled=no
#
#   # wlan1 is the uplink now, so it must NOT be a bridge port:
#   /interface bridge port
#   remove [find interface=wlan1]
#   add bridge=bridge interface=ether1 internal-path-cost=10 path-cost=10
#
#   /ip dhcp-client
#   remove [find interface=ether1]
#   add default-route-distance=2 interface=wlan1
#
#   # and in CheckWanLink, set: :local wanIf "wlan1";
#
# ---- Option B: repeater mode (keeps WiFi for the TVs) ----
# Keeps a local WiFi network by running a virtual AP on the same radio
# that is acting as a station. RouterOS supports this (see also
# /interface wireless setup-repeater). Accept the trade-offs:
#   - The radio time-shares between uplink and downlink, so usable
#     throughput roughly halves.
#   - The local AP is locked to whatever channel the ISP router uses.
#   - Extra CPU load on hardware that already has little to spare.
#   - The station-bridge mode used in most repeater examples is a
#     MikroTik-proprietary extension and only works when the upstream AP
#     is also a MikroTik. Against a generic ISP router you must use plain
#     station mode - which is fine here because this router NATs rather
#     than bridges, but the combination of plain station + virtual AP
#     NEEDS VERIFYING ON REAL HARDWARE before you rely on it.
#
#   /interface wireless
#   set [find default-name=wlan1] mode=station ssid="<ISP_WIFI_SSID>" \
#       security-profile=isp_uplink disabled=no
#   add master-interface=wlan1 mode=ap-bridge name=wlan-ap \
#       ssid="<NEUTRAL_SSID>" security-profile=wlan_passwd disabled=no
#
#   /interface bridge port
#   remove [find interface=wlan1]
#   add bridge=bridge interface=wlan-ap internal-path-cost=10 path-cost=10
#
#   # WAN list, dhcp-client and CheckWanLink: same changes as option A.
