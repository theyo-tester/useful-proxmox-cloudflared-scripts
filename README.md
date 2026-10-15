## auto_create_vmbr_cf_routing.sh: 
Purpose: Creates an isolated PVE Linux Bridge and attaches an interface to LXC
Idea: to have an fixed/direct bridge and static ip connection between cloudflared and Proxmox. Thus the proxmox ip can change while the connection between cloudflared and proxmox remains intact and can be used in cloudflare for tunnel routing
Example how you the prompt experience is:
````
root@px:~/useful-proxmox-cloudflared-scripts# ./auto_create_vmbr_cf_routing.sh 
==========================================
 Proxmox Isolated Bridge & LXC Setup Script
==========================================
[?] Enter Linux Bridge name [Default: vmbr1]: 
[?] Enter Proxmox Host Bridge IP (CIDR /24) [Default: 10.20.30.2/24]: 

[*] Searching for 'cloudflared' container...
[+] Found container 'cloudflared' with ID: 100
[?] Enter target LXC Container ID [Default: 100]: 
[?] Enter interface name inside LXC [Default: eth1]: 
[?] Enter LXC IP for bridge connection [Default: 10.20.30.3/24]: 

=== Summary of Changes ===
 Bridge Name:    vmbr1 (Isolated)
 Host Bridge IP: 10.20.30.2/24
 LXC ID:         100
 LXC Interface:  eth1 (slot net1)
 LXC IP:         10.20.30.3/24
 /etc/hosts:     10.20.30.2 px.local (inside LXC 100)
==========================
Proceed with configuration? [y/N]: y
[*] Adding bridge vmbr1 to /etc/network/interfaces...
[*] Bringing up network interface vmbr1...
[*] Adding net1 (eth1) to LXC 100 config...
[*] Container is running. Hot-attaching interface into active namespace...
[*] Injecting /etc/hosts entry into LXC 100...
[+] Setup completed successfully!
````

As you can see, the script figured everything out by itself, I just had to press enter and confirm with 'y' at the end.
For suggestion, it auto-selects: the next free virtual bridge, the next free Subnet, the possible container (cloudflare) for the connection. the next free interface name on the LXC, the new IP on the LXC

## enable_mDNS_in_cloudflared.sh
Purpose: resolve local domains to their local IP in order to configure for tunnel routing by specifying the hostname instead of the IP. Thus IPs can change an the cloudflared container can still resolve domain names
LXC Containers in Proxmox (or at least the Cloudflared container) is persistend agains mDNS.
## add_mDNS_to_proxmox.sh
Purpose: make proxmox advertise its own local domain name to the lan, thus it can be found locally without specifying the IP. Needed in order for cloudflared to find it
## Hints 
By using `add_mDNS_to_proxmox.sh` and `enable_mDNS_in_cloudflared.sh` in combination, you do NOT require a special bridge connection between Proxmox and the cloudflared LXC (like the one that gets created by `auto_create_vmbr_cf_routing.sh`). 
Thus, either use the two scripts or the other.
