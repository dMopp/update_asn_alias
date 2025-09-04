#!/bin/sh
set -eu

# ---- Config ----
ALIAS_V4="ASN_TO_TUNNEL_V4"
ALIAS_V6="ASN_TO_TUNNEL_V6"

ASN_FILE="/root/asn.list"
WHOIS_HOST="whois.radb.net"
WHOIS_TIMEOUT=15        # in seconds
SLEEP_BETWEEN=0.3       # radb rate-limit freundlich

OPNSENSE_URL=https://gateway.quolke.net    # Valid certificate required
OPNSENSE_PORT=4443

# Veröffentlichung für URL Table (IPs)
WWWROOT="/usr/local/www"
LOCAL_DIR="/_aliases"
WEBSERVER_DIR="$WWWROOT/$LOCAL_DIR"
V4_FILE="$WEBSERVER_DIR/$ALIAS_V4.txt"
V6_FILE="$WEBSERVER_DIR/$ALIAS_V6.txt"

# Binaries
PFCTL="$(command -v pfctl || echo /sbin/pfctl)"
CONFIGCTL="$(command -v configctl || echo /usr/local/sbin/configctl)"

# ===================

TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
ASN_TMP="$TMPDIR/asn.txt"
IP4_TMP="$TMPDIR/ip4.txt"
IP6_TMP="$TMPDIR/ip6.txt"
CIDR4_TMP="$TMPDIR/cidr4.txt"
CIDR6_TMP="$TMPDIR/cidr6.txt"
RAW_TMP="$TMPDIR/raw.txt"
V4_TMP="$TMPDIR/v4.txt"
V6_TMP="$TMPDIR/v6.txt"

have(){ command -v "$1" >/dev/null 2>&1; }

# --- ASN_FILE Zeilenenden normalisieren (nur CRLF->LF) ---
ASN_FILE_LF="$TMPDIR/asn_lf.list"
if [ -f "$ASN_FILE" ]; then
  tr -d '\r' < "$ASN_FILE" > "$ASN_FILE_LF"
else
  echo "ASN-Datei fehlt: $ASN_FILE" >&2
  exit 1
fi

# --- 1) Einträge aus Datei ziehen ---
grep -i -oE 'AS[0-9]+' "$ASN_FILE_LF" | sort -u > "$ASN_TMP" || true
grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' "$ASN_FILE_LF" | grep -v '/' | sort -u > "$IP4_TMP" || true
grep -iEo '([0-9a-f:]+)' "$ASN_FILE_LF" | grep ':' | grep -v '/' | sort -u > "$IP6_TMP" || true
grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' "$ASN_FILE_LF" | sort -u > "$CIDR4_TMP" || true
grep -iEo '([0-9a-f:]+)/[0-9]{1,3}' "$ASN_FILE_LF" | grep ':' | sort -u > "$CIDR6_TMP" || true

if [ ! -s "$ASN_TMP" ] && [ ! -s "$IP4_TMP" ] && [ ! -s "$IP6_TMP" ] && [ ! -s "$CIDR4_TMP" ] && [ ! -s "$CIDR6_TMP" ]; then
  echo "Keine ASNs/IPs/CIDRs in $ASN_FILE gefunden." >&2
  exit 1
fi

# --- 2) Prefixes via RADb (nur wenn ASNs vorhanden) ---
: > "$RAW_TMP"

if [ -s "$ASN_TMP" ]; then
  while IFS= read -r ASN; do
    if ! timeout "$WHOIS_TIMEOUT" whois -h "$WHOIS_HOST" -- "-i origin $ASN" 2>/dev/null >> "$RAW_TMP"; then
      echo "ERROR: whois lookup for $ASN failed or timed out after ${WHOIS_TIMEOUT}s." >&2
      exit 1
    fi
    sleep "$SLEEP_BETWEEN"
  done < "$ASN_TMP"
fi

# --- 3) v4/v6 sammeln ---
grep -E '^route:'  "$RAW_TMP" | sed -E 's/^route:[[:space:]]+//'  | sort -u > "$V4_TMP" || true
grep -E '^route6:' "$RAW_TMP" | sed -E 's/^route6:[[:space:]]+//' | sort -u > "$V6_TMP" || true

# direkte IPv4-IPs als /32
if [ -s "$IP4_TMP" ]; then
  while IFS= read -r ip; do [ -n "$ip" ] && printf '%s/32\n' "$ip"; done < "$IP4_TMP" >> "$V4_TMP"
fi
# direkte IPv6-IPs als /128 (später Sanitizer)
if [ -s "$IP6_TMP" ]; then
  while IFS= read -r ip; do [ -n "$ip" ] && printf '%s/128\n' "$ip"; done < "$IP6_TMP" >> "$V6_TMP"
fi

# direkte CIDRs (grobe Masken-Validierung)
validate_v4_cidr(){ m="${1##*/}"; case "$m" in ''|*[!0-9]*) return 1;; esac; [ "$m" -ge 0 ] && [ "$m" -le 32 ]; }
validate_v6_cidr(){ m="${1##*/}"; case "$m" in ''|*[!0-9]*) return 1;; esac; [ "$m" -ge 0 ] && [ "$m" -le 128 ]; }

if [ -s "$CIDR4_TMP" ]; then
  while IFS= read -r c; do [ -n "$c" ] && validate_v4_cidr "$c" && printf '%s\n' "$c"; done < "$CIDR4_TMP" >> "$V4_TMP"
fi
if [ -s "$CIDR6_TMP" ]; then
  while IFS= read -r c; do [ -n "$c" ] && validate_v6_cidr "$c" && printf '%s\n' "$c"; done < "$CIDR6_TMP" >> "$V6_TMP"
fi

sort -u -o "$V4_TMP" "$V4_TMP" || true
sort -u -o "$V6_TMP" "$V6_TMP" || true

# --- 3.5) FINALER SANITIZER ---
sanitize_file(){
  in="$1"; out="$2"
  if [ ! -s "$in" ]; then : > "$out"; return 0; fi
  if have python3; then
    python3 - "$in" > "$out" << 'PY'
import sys, ipaddress
def items(path):
    with open(path, 'r', encoding='utf-8', errors='ignore') as f:
        for raw in f:
            s = raw.strip()
            if not s or s.startswith('#'):
                continue
            s = s.split('#',1)[0].strip()
            if s:
                yield s
def add(s, v4, v6):
    try:
        try:
            net = ipaddress.ip_network(s, strict=False)
        except ValueError:
            ip  = ipaddress.ip_address(s)
            net = ipaddress.ip_network(f"{ip}/{32 if ip.version==4 else 128}", strict=False)
        (v4 if net.version==4 else v6).add(str(net))
    except Exception:
        pass
v4=set(); v6=set()
for s in items(sys.argv[1]): add(s, v4, v6)
def k(n):
    net = ipaddress.ip_network(n, strict=False)
    return (net.version, int(net.network_address._ip), net.prefixlen)
for n in sorted(v4, key=k): print(n)
for n in sorted(v6, key=k): print(n)
PY
  else
    grep -E '(^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$)|(^[0-9A-Fa-f:]+/[0-9]{1,3}$)' "$in" \
      | awk -F/ '$2<=128' | sort -u > "$out" || true
  fi
}
V4_CLEAN="$TMPDIR/v4.clean"
V6_CLEAN="$TMPDIR/v6.clean"
sanitize_file "$V4_TMP" "$V4_CLEAN"
sanitize_file "$V6_TMP" "$V6_CLEAN"
mv "$V4_CLEAN" "$V4_TMP"
mv "$V6_CLEAN" "$V6_TMP"

V4N=$(wc -l < "$V4_TMP" | tr -d ' ')
V6N=$(wc -l < "$V6_TMP" | tr -d ' ')
ASNN=$( [ -s "$ASN_TMP" ] && wc -l < "$ASN_TMP" | tr -d ' ' || echo 0 )
echo "Parsed: $V4N v4-Netze, $V6N v6-Netze aus $ASNN ASNs (+ direkte IPs/CIDRs)."

# --- 4) Persistenz-Dateien unter $LOCAL_DIR ---
if [ ! -d "$LOCAL_DIR" ]; then
  mkdir -p "$LOCAL_DIR"
fi
# atomare Writes
copy_atomic(){
  src="$1"; dst="$2"
  umask 022
  tmp="$dst.tmp.$$"
  cp "$src" "$tmp"
  mv -f "$tmp" "$dst"
}
copy_atomic "$V4_TMP" "$V4_FILE"
copy_atomic "$V6_TMP" "$V6_FILE"

# --- 5) Sofort aktiv: pfctl Tabellen ersetzen ---
ensure_table(){
  name="$1"
  if ! "$PFCTL" -t "$name" -T show >/dev/null 2>&1; then
    "$PFCTL" -t "$name" -T add 127.255.255.255 >/dev/null 2>&1 || true
    "$PFCTL" -t "$name" -T delete 127.255.255.255 >/dev/null 2>&1 || true
  fi
}

apply_pf(){
  name="$1"; file="$2"
  if [ -s "$file" ]; then
    ensure_table "$name"
    "$PFCTL" -t "$name" -T replace -f "$file"
  else
    # leer -> flush (falls Tabelle existiert)
    if "$PFCTL" -t "$name" -T show >/dev/null 2>&1; then
      "$PFCTL" -t "$name" -T flush >/dev/null 2>&1 || true
    fi
  fi
}

apply_pf "$ALIAS_V4" "$V4_FILE"
apply_pf "$ALIAS_V6" "$V6_FILE"

# --- 6) Alias-Engine sanft „anstubsen“ (optional) ---
if [ -x "$CONFIGCTL" ]; then
  "$CONFIGCTL" filter refresh_aliases >/dev/null 2>&1 || true
fi

echo "Persistiert nach:"
echo "  $V4_FILE"
echo "  $V6_FILE"
echo "Lokale URLs für URL Table (IPs):"
echo "  $OPNSENSE_URL:$OPNSENSE_PORT/$LOCAL_DIR/$ALIAS_V4.txt"
echo "  $OPNSENSE_URL:$OPNSENSE_PORT/$LOCAL_DIR/$ALIAS_V6.txt"
echo "pfctl-Tabellen '$ALIAS_V4' und '$ALIAS_V6' wurden ersetzt."
