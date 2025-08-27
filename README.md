
# update_asn_alias for OPNsense
I used that script (+ config) to route traffic for specific ASN trough my wireguard tunnel


**Preconditions:**
You have done setup Gateways for IPv4 and IPv6 in opnsense we could use later on.
You have assigned an Interface for the Tunnel (no IP config required there)

**HowTo:**
 1. In OPNsense under Firewall/Aliases Create two aliases (As networks, should be leave empty):
		 3. ASN_TO_TUNNEL_V4
		 4. ASN_TO_TUNNEL_V6
 2. In OPNsense under Firewall/Rules/Floating create Two Rules
	 3. Disabled: Checked
	 4. Action: Pass
	 5. Quick: Checked
	 6. Interface: (All where the routing should be applied to)
	 7. Direction: In
	 8. TCP/IP Version IPv4 (2nd rule IPv6)
	 9. Protocol TCP/UDP (Or whatever, up to you)
	 10. Source: Any
	 11. Destination: ASN_TO_TUNNEL_V4 (Or V6) Alias
	 12. Destination Port Range: Up to you (Iam using 80/443 only)
	 13. Gateway: The Gateway you want to Use (V4 for V4 and V6 for V6)
Note: This rule should be run before other routing rules
	
 3. In OPNsense under Firewall/NAT/Outbound (Make sure Hybrid is active)
	 4. Create Two (!) rules for every Interface
			 6. Interface: TUNNELINTERFACE (always the same)
			 7. TCP/IP Version V4 (2nd Rule V6)
			 8. Protocol: Any
			 9. Source address: The Interface you want to route (eG LAN)
			 10. Destination Address: any 
			 11. Translation / Target: Interface address
 4. copy files
	 5. Copy [update_asn_alias.sh](https://github.com/dMopp/update_asn_alias/blob/main/update_asn_alias.sh "update_asn_alias.sh") to OPNsense:/root/
	 6. Copy [asn.list](https://github.com/dMopp/update_asn_alias/blob/main/asn.list "asn.list") to OPNsense:/root/
	 7. Copy [actions_asnaliasupdate.conf](https://github.com/dMopp/update_asn_alias/blob/main/actions_asnaliasupdate.conf "actions_asnaliasupdate.conf") to /usr/local/opnsense/service/conf/actions.d/
	 8. Run service configd restart on OPNsense
 5. In OPNsense under System/Settings/Cron create a new entry:
	 6. Minutes: 30
	 7. Hours: 3
	 8. Day/Month/Days: *
	 9. Command: Update ASN aliases
