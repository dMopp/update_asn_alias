# update_asn_alias for OPNsense (ASN/IP/Network Routing)

This setup allows you to route traffic for specific Autonomous Systems (ASNs), specific IPs **or networks** through a (WireGuard) tunnel on OPNsense.

---

## 📋 Prerequisites

Before starting, make sure you have:

- Gateways for **IPv4** and **IPv6** configured (we will use them later).
- An **interface assigned** for the WireGuard tunnel  
  (⚠️ no IP configuration required on the tunnel interface).
- Shell/SSH access to your OPNsense firewall.

---

## ⚙️ Step 1: Create Firewall Aliases

1. Go to **Firewall → Aliases**.  
2. Create two aliases:
   - **ASN_TO_TUNNEL_V4** (type: *Networks*, leave empty for now)
   - **ASN_TO_TUNNEL_V6** (type: *Networks*, leave empty for now)

These will be filled dynamically by the script later.

---

## 🔑 Step 2: Create API Key

1. Go to **System → Access → Users**.  
2. Select your `root` user (or create a dedicated automation user).  
3. Generate an **API key/secret** pair.  
   - Save them securely — you’ll need them in the script.

---

## 🚦 Step 3: Create Floating Rules

1. Go to **Firewall → Rules → Floating**.  
2. Create **two rules** (one for IPv4, one for IPv6):

   - **General**
     - **Disabled**: *Checked* (recommended for testing — once aliases are filled, you can enable the rules)
     - **Action**: Pass
     - **Quick**: Checked
     - **Interface**: All (or limit to where routing should apply)
     - **Direction**: In

   - **Network**
     - **TCP/IP Version**: IPv4 (second rule IPv6)
     - **Protocol**: TCP/UDP (or any you need)
     - **Source**: Any
     - **Destination**: `ASN_TO_TUNNEL_V4` (or `ASN_TO_TUNNEL_V6`)
     - **Destination Port Range**: (optional, e.g. 80–443)

   - **Advanced**
     - **Gateway**: Select the WireGuard gateway (IPv4 or IPv6 accordingly)

⚠️ These rules must be placed **before other routing rules**.

---

## 🔄 Step 4: Configure Outbound NAT

1. Go to **Firewall → NAT → Outbound**.  
2. Ensure mode is set to **Hybrid**.  
3. Create **two rules per LAN interface** (one IPv4, one IPv6):

   - **Interface**: Tunnel interface (always the same one)
   - **TCP/IP Version**: IPv4 (second rule IPv6)
   - **Protocol**: Any
   - **Source Address**: The LAN/subnet you want to route
   - **Destination Address**: Any
   - **Translation / Target**: Interface address

⚠️ Without these NAT rules, return traffic may not be routed correctly through the tunnel.

---

## 📂 Step 5: Install the Script

Copy the following files to your OPNsense box:

```bash
scp update_asn_alias.sh root@OPNsense:/root/
scp asn.list root@OPNsense:/root/
scp actions_asnaliasupdate.conf root@OPNsense:/usr/local/opnsense/service/conf/actions.d/
```

Then restart the service framework:

```bash
service configd restart
```

---

## 🛠 Step 6: Adjust the Script

Edit `/root/update_asn_alias.sh` and add your:

- OPNsense API URL
- Port
- API key
- API secret

---

## ⏰ Step 7: Schedule with Cron

1. Go to **System → Settings → Cron**.  
2. Add a new entry:
   - **Minutes**: `30`
   - **Hours**: `3`
   - **Days/Months/Weekdays**: `*`
   - **Command**: `Update ASN aliases`

---

## ✅ Final Check

Run the script manually once:

```bash
/root/update_asn_alias.sh
```

Then verify in **Firewall → Aliases** that:

- `ASN_TO_TUNNEL_V4`
- `ASN_TO_TUNNEL_V6`

contain networks as expected.  
You can also check the **last update timestamp** in the alias list to confirm successful runs.

---

## 📎 Files in this Repository

- [`update_asn_alias.sh`](./update_asn_alias.sh) – main update script  
- [`asn.list`](./asn.list) – list of ASNs/IPs/Networks to be routed  
- [`actions_asnaliasupdate.conf`](./actions_asnaliasupdate.conf) – configd integration  

---

## 🎉 Done!

Traffic matching the configured ASNs, IPs or networks will now be routed through your WireGuard tunnel.
