#!/bin/sh
set -eu

# ---- Config ----
OPNSENSE_HOST="https://WWW:XXX"
API_KEY="YYY"
API_SECRET="ZZZ"
ALIAS_V4="ASN_TO_TUNNEL_V4"
ALIAS_V6="ASN_TO_TUNNEL_V6"
ASN_FILE="/root/asn.list"
WHOIS_HOST="whois.radb.net"
SLEEP_BETWEEN=0.3   # radb rate-limit freundlich
CURL_OPTS="-sk"              # -k erlaubt self-signed Zert. Mit gültigem Zert: nur "-s"
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

# --- helpers ---
have(){ command -v "$1" >/dev/null 2>&1; }

# ASN_FILE ggf. CRLF -> LF (ohne Inhalte zu verändern)
ASN_FILE_LF="$TMPDIR/asn_lf.list"
if [ -f "$ASN_FILE" ]; then
  # Nur Zeilenenden bereinigen, keine ':'-Manipulation!
  tr -d '\r' < "$ASN_FILE" > "$ASN_FILE_LF"
else
  echo "ASN-Datei fehlt: $ASN_FILE" >&2
  exit 1
fi

# --- API helpers ---
api_get(){ curl $CURL_OPTS -u "$API_KEY:$API_SECRET" "$OPNSENSE_HOST$1"; }
api_post_body(){ curl $CURL_OPTS -u "$API_KEY:$API_SECRET" -H "Content-Type: application/json" -X POST -d @"$2" "$OPNSENSE_HOST$1"; }
api_post_nobody(){ curl $CURL_OPTS -u "$API_KEY:$API_SECRET" -X POST "$OPNSENSE_HOST$1"; }

ensure_alias(){ # $1=name -> prints UUID
  NAME="$1"
  UUID="$(api_get "/api/firewall/alias/getAliasUUID/$NAME" 2>/dev/null | sed -n 's/.*\"uuid\":\"\([^\"]*\)\".*/\1/p')"
  if [ -n "$UUID" ]; then echo "$UUID"; return 0; fi
  BODY="$TMPDIR/add_$NAME.json"
  { printf '{'; printf '"alias":{"enabled":"1","type":"network","name":"%s","content":""}' "$NAME"; printf '}'; } > "$BODY"
  api_post_body "/api/firewall/alias/addItem" "$BODY" >/dev/null 2>&1 || true
  UUID="$(api_get "/api/firewall/alias/getAliasUUID/$NAME" 2>/dev/null | sed -n 's/.*\"uuid\":\"\([^\"]*\)\".*/\1/p')"
  [ -n "$UUID" ] || { echo "Alias $NAME konnte nicht angelegt werden." >&2; exit 1; }
  echo "$UUID"
}

# --- 1) Einträge aus Datei ziehen ---
# ASNs (case-insensitiv)
grep -i -oE 'AS[0-9]+' "$ASN_FILE_LF" | sort -u > "$ASN_TMP" || true
# IPv4 single IPs
grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' "$ASN_FILE_LF" \
  | grep -v '/' | sort -u > "$IP4_TMP" || true
# IPv6 single IPs (rudimentär; Zeilen mit ':' & Hex, ohne Slash)
# Hinweis: Diese Liste wird später durch einen strikten Sanitizer validiert.
grep -iEo '([0-9a-f:]+)' "$ASN_FILE_LF" | grep ':' | grep -v '/' | sort -u > "$IP6_TMP" || true
# IPv4 CIDRs
grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' "$ASN_FILE_LF" | sort -u > "$CIDR4_TMP" || true
# IPv6 CIDRs
grep -iEo '([0-9a-f:]+)/[0-9]{1,3}' "$ASN_FILE_LF" | grep ':' | sort -u > "$CIDR6_TMP" || true

if [ ! -s "$ASN_TMP" ] && [ ! -s "$IP4_TMP" ] && [ ! -s "$IP6_TMP" ] && [ ! -s "$CIDR4_TMP" ] && [ ! -s "$CIDR6_TMP" ]; then
  echo "Keine ASNs/IPs/CIDRs in $ASN_FILE gefunden." >&2; exit 1
fi

# --- 2) Prefixes via RADb (nur wenn ASNs vorhanden) ---
: > "$RAW_TMP"
if [ -s "$ASN_TMP" ]; then
  while IFS= read -r ASN; do
    whois -h "$WHOIS_HOST" -- "-i origin $ASN" 2>/dev/null >> "$RAW_TMP" || true
    sleep "$SLEEP_BETWEEN"
  done < "$ASN_TMP"
fi

# --- 3) v4/v6 sammeln ---
# aus RADb:
grep -E '^route:'  "$RAW_TMP" | sed -E 's/^route:[[:space:]]+//'  | sort -u > "$V4_TMP" || true
grep -E '^route6:' "$RAW_TMP" | sed -E 's/^route6:[[:space:]]+//' | sort -u > "$V6_TMP" || true

# direkte IPv4-IPs als /32
if [ -s "$IP4_TMP" ]; then
  while IFS= read -r ip; do [ -n "$ip" ] && printf '%s/32\n' "$ip"; done < "$IP4_TMP" >> "$V4_TMP"
fi
# direkte IPv6-IPs als /128 (später durch Sanitizer geprüft)
if [ -s "$IP6_TMP" ]; then
  while IFS= read -r ip; do [ -n "$ip" ] && printf '%s/128\n' "$ip"; done < "$IP6_TMP" >> "$V6_TMP"
fi

# direkte CIDRs (mit grober Masken-Validierung)
validate_v4_cidr(){
  m="${1##*/}"; case "$m" in ''|*[!0-9]*) return 1;; esac
  [ "$m" -ge 0 ] && [ "$m" -le 32 ]
}
validate_v6_cidr(){
  m="${1##*/}"; case "$m" in ''|*[!0-9]*) return 1;; esac
  [ "$m" -ge 0 ] && [ "$m" -le 128 ]
}

if [ -s "$CIDR4_TMP" ]; then
  while IFS= read -r c; do
    [ -n "$c" ] && validate_v4_cidr "$c" && printf '%s\n' "$c"
  done < "$CIDR4_TMP" >> "$V4_TMP"
fi
if [ -s "$CIDR6_TMP" ]; then
  while IFS= read -r c; do
    [ -n "$c" ] && validate_v6_cidr "$c" && printf '%s\n' "$c"
  done < "$CIDR6_TMP" >> "$V6_TMP"
fi

# deduplizieren
sort -u -o "$V4_TMP" "$V4_TMP" || true
sort -u -o "$V6_TMP" "$V6_TMP" || true

# --- 3.5) FINALER SANITIZER: Nur gültige Netze/IPs (konvertiert Einzel-IPs) ---
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
            net = ipaddress.ip_network(s, strict=False)  # CIDR
        except ValueError:
            ip  = ipaddress.ip_address(s)                # Einzel-IP
            net = ipaddress.ip_network(f"{ip}/{32 if ip.version==4 else 128}", strict=False)
        (v4 if net.version==4 else v6).add(str(net))
    except Exception:
        pass
v4=set(); v6=set()
for s in items(sys.argv[1]):
    add(s, v4, v6)
# geordneter Output (stabil):
def k(n):
    net = ipaddress.ip_network(n, strict=False)
    return (net.version, int(net.network_address._ip), net.prefixlen)
for n in sorted(v4, key=k): print(n)
for n in sorted(v6, key=k): print(n)
PY
  else
    # Fallback: akzeptiert nur "offensichtliche" CIDRs; verwirft kaputte a:/128-Fälle sicher
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

# --- 4) Aliase sicherstellen ---
UUID_V4="$(ensure_alias "$ALIAS_V4")"
UUID_V6="$(ensure_alias "$ALIAS_V6")"

# --- 5) JSON mit Zeilenliste bauen (BSD-sed kompatibel) ---
make_body(){ # $1=name $2=filein $3=outfile
  NAME="$1"; IN="$2"; OUT="$3"
  CONTENT_ESCAPED="$(
    sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g' "$IN"
  )"
  { printf '{';
    printf '"alias":{"enabled":"1","type":"network","name":"%s","content":"%s"}' "$NAME" "$CONTENT_ESCAPED";
    printf '}'; } > "$OUT"
}

V4_BODY="$TMPDIR/set_$ALIAS_V4.json"
V6_BODY="$TMPDIR/set_$ALIAS_V6.json"
make_body "$ALIAS_V4" "$V4_TMP" "$V4_BODY"
make_body "$ALIAS_V6" "$V6_TMP" "$V6_BODY"

# --- 6) Aliase setzen & reconfigure ---
echo "API($ALIAS_V4): $(api_post_body "/api/firewall/alias/setItem/$UUID_V4" "$V4_BODY")"
echo "API($ALIAS_V6): $(api_post_body "/api/firewall/alias/setItem/$UUID_V6" "$V6_BODY")"
api_post_nobody "/api/firewall/alias/reconfigure" >/dev/null || true
echo "Alias-Reconfigure ausgelöst. Fertig."
