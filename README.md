## auto_create_vmbr_cf_routing.sh: 
Purpose: Creates an isolated PVE Linux Bridge and attaches an interface to LXC
Idea: to have an fixed/direct bridge and static ip connection between cloudflared and Proxmox. Thus the proxmox ip can change while the connection between cloudflared and proxmox remains intact and can be used in cloudflare for tunnel routing
## enable_mDNS_in_cloudflared.sh
Purpose: resolve local domains to their local IP in order to configure for tunnel routing by specifying the hostname instead of the IP. Thus IPs can change an the cloudflared container can still resolve domain names
LXC Containers in Proxmox (or at least the Cloudflared container) is persistend agains mDNS.
## add_mDNS_to_proxmox.sh
Purpose: make proxmox advertise its own local domain name to the lan, thus it can be found locally without specifying the IP
