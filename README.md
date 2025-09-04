


# update_asn_alias for OPNsense (ASN/IP/Network Routing)

This setup allows you to route traffic for specific Autonomous Systems (ASNs), specific IPs **or networks** through a (WireGuard) tunnel on OPNsense.

---

## 📋 Prerequisites

Before starting, make sure you have:

- Gateways for **IPv4** and **IPv6** configured (we will use them later).
- An **interface assigned** for the WireGuard tunnel  
  (⚠️ no IP configuration required on the tunnel interface).
- Shell/SSH access to your OPNsense firewall.
- Valid SSL certificate (OR HTTP access)

---

## ⚙️ Step 1: Create Firewall Aliases

1. Go to **Firewall → Aliases**.  
2. Create two aliases:
   - **ASN_TO_TUNNEL_V4** 
      type: *URL Table (IPs)*
      Refresh Frequency: *Empty / 1*
      content: *file:///conf/_aliases/ASN_TO_TUNNEL_V4.txt*
   - **ASN_TO_TUNNEL_V6** 
     type: *URL Table (IPs)*
     Refresh Frequency: *Empty / 1*
     content: *file:///conf/_aliases/ASN_TO_TUNNEL_V6.txt*

These will be filled dynamically by the script later.

---

## 🚦 Step 2: Create Floating Rules

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

## 🔄 Step 3: Configure Outbound NAT

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

## 📂 Step 4: Install the Scripts

Copy the following files to your OPNsense box:

```bash
scp update_asn_alias.sh root@OPNsense:/root/
scp asn.list root@OPNsense:/root/
scp actions_asnaliasupdate.conf root@OPNsense:/usr/local/opnsense/service/conf/actions.d/
scp actions_updateawsurltable.conf root@OPNsense:/usr/local/opnsense/service/conf/actions.d/
```

Then restart the service framework:

```bash
service configd restart
```

---

## ⏰ Step 5: Schedule with Cron

1. Go to **System → Settings → Cron**.  
2. Add a new entry:
   - **Minutes**: `30`
   - **Hours**: `3`
   - **Days/Months/Weekdays**: `*`
   - **Command**: `Update ASN aliases`
3. Add a new entry:
   - **Minutes**: `30`
   - **Hours**: `2`
   - **Days/Months/Weekdays**: `*`
   - **Command**: `Update AWS URL Table`

---

## 🔧 Step 6: Check Configuration

Before running the final check, verify the configuration inside your
update_asn_alias.sh script:

- `OPNSENSE_URL="https://firewall.fqdn"   # FQDN with a valid SSL certificate OR http`
- `OPNSENSE_PORT="4443"                   # Typically 443 or 4443 depending on your setup (OR 80)`

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
- [`update_aws_urltable.sh`](./update_aws_urltable.sh) – aws update script
- [`asn.list`](./asn.list) – list of ASNs/IPs/Networks to be routed  
- [`actions_asnaliasupdate.conf`](./actions_asnaliasupdate.conf) – configd integration
- [`actions_updateawsurltable.conf`](./actions_updateawsurltable.conf) – configd integration  

---

## 🎉 Done!

Traffic matching the configured ASNs, IPs or networks will now be routed through your WireGuard tunnel.


---

# AWS IP Range Updater for OPNsense

This script fetches the official AWS IP ranges from  
[`https://ip-ranges.amazonaws.com/ip-ranges.json`](https://ip-ranges.amazonaws.com/ip-ranges.json)  
and writes selected networks (Amazon EC2 and/or CloudFront) into a target file.  

The target file can be used in **OPNsense URL tables** to automatically maintain  
a list of AWS networks for firewall rules.

## Features
- Supports both **IPv4** and **IPv6** ranges
- Region filtering (e.g., `us-west-2`, `eu-central-1`)
- Optional inclusion of:
  - `AMAZON` (general AWS ranges, often EC2)
  - `CLOUDFRONT` (content delivery edges)
  - Global CloudFront-only mode
- Inserts/updates a **managed block** between  
  `# BEGIN AWS-AUTO` and `# END AWS-AUTO`  
  without touching manual entries in the file
- Generates deduplicated and sorted lists

## Usage
1. Adjust configuration variables at the top of the script:
   - `REGIONS` → AWS regions to include
   - `INCLUDE_AMAZON` / `INCLUDE_CLOUDFRONT`
   - `CLOUDFRONT_GLOBAL_ONLY`
   - `TARGET_FILE` → destination file for OPNsense

2. Run the script manually or via **cron**:
   ```sh
   sh update_aws_ipranges.sh
   ```

3. Point an OPNsense **URL table alias** to the generated file.

## Example
A generated block inside `asn.list` looks like:

```
# BEGIN AWS-AUTO (managed; do not edit inside)
# generated: 2025-09-04T21:00:00Z
# regions: us-west-2 | amazon=1 | cloudfront=1 | cf_global_only=1
13.34.32.0/24
13.35.0.0/16
...
2600:9000::/28
# END AWS-AUTO
```

## Requirements
- `curl`, `jq`, `sort`, `sed`, `awk`, `mkdir`

---

**Note:** Only the lines inside the managed block are updated.  
Manual entries outside this block remain untouched.
