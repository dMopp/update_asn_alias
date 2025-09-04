#!/bin/sh
set -eu

# ======= Konfiguration =======
# Welche AWS-Regionen aufnehmen? (Leerzeichen-getrennt)
REGIONS="us-west-2"             # z.B.: "us-west-2 eu-central-1"

# Dienste wählen
INCLUDE_AMAZON="1"              # 1/0 – EC2/AMAZON-Netze (häufig Hauptursache)
INCLUDE_CLOUDFRONT="1"          # 1/0 – CloudFront-Edges hinzufügen
CLOUDFRONT_GLOBAL_ONLY="1"      # 1: nur region=="GLOBAL" (empfohlen), 0: region-basiert

# Ziel-Datei, die OPNsense als URL-Table lädt:
TARGET_DIR="/root"
TARGET_FILE="${TARGET_DIR}/asn.list"

# Marker für den Auto-Block:
BEGIN_MARKER="# BEGIN AWS-AUTO (managed; do not edit inside)"
END_MARKER="# END AWS-AUTO"

# Tools
CURL_OPTS="-fsS"
AWS_RANGES_URL="https://ip-ranges.amazonaws.com/ip-ranges.json"

# ======= Vorbedingungen =======
need() { command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1"; exit 1; }; }
need curl
need jq
need sort
need sed
need awk
need mkdir

# ======= Temp-Dateien =======
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
JSON="$TMPDIR/ip-ranges.json"
V4_TMP="$TMPDIR/v4.txt"
V6_TMP="$TMPDIR/v6.txt"
BLOCK_TMP="$TMPDIR/block.txt"
NEWFILE_TMP="$TMPDIR/newfile.txt"

# ======= Daten holen =======
curl $CURL_OPTS -o "$JSON" "$AWS_RANGES_URL"

# ======= Netze sammeln =======
: >"$V4_TMP"
: >"$V6_TMP"

if [ "$INCLUDE_AMAZON" = "1" ]; then
  for R in $REGIONS; do
    # IPv4 AMAZON für Region R
    jq -r --arg R "$R" '
      .prefixes[]
      | select(.service=="AMAZON" and .region==$R)
      | .ip_prefix
    ' "$JSON" >>"$V4_TMP"

    # IPv6 AMAZON für Region R
    jq -r --arg R "$R" '
      .ipv6_prefixes[]
      | select(.service=="AMAZON" and .region==$R)
      | .ipv6_prefix
    ' "$JSON" >>"$V6_TMP"
  done
fi

if [ "$INCLUDE_CLOUDFRONT" = "1" ]; then
  if [ "$CLOUDFRONT_GLOBAL_ONLY" = "1" ]; then
    # IPv4 CF GLOBAL
    jq -r '
      .prefixes[]
      | select(.service=="CLOUDFRONT" and .region=="GLOBAL")
      | .ip_prefix
    ' "$JSON" >>"$V4_TMP"

    # IPv6 CF GLOBAL
    jq -r '
      .ipv6_prefixes[]
      | select(.service=="CLOUDFRONT" and .region=="GLOBAL")
      | .ipv6_prefix
    ' "$JSON" >>"$V6_TMP"
  else
    for R in $REGIONS; do
      jq -r --arg R "$R" '
        .prefixes[]
        | select(.service=="CLOUDFRONT" and .region==$R)
        | .ip_prefix
      ' "$JSON" >>"$V4_TMP"

      jq -r --arg R "$R" '
        .ipv6_prefixes[]
        | select(.service=="CLOUDFRONT" and .region==$R)
        | .ipv6_prefix
      ' "$JSON" >>"$V6_TMP"
    done
  fi
fi

# Deduplizieren & sortieren
sort -u -o "$V4_TMP" "$V4_TMP"
sort -u -o "$V6_TMP" "$V6_TMP"

# ======= Auto-Block aufbereiten (v4 + v6 gemischt) =======
{
  echo "$BEGIN_MARKER"
  printf "# generated: %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf "# regions: %s | amazon=%s | cloudfront=%s | cf_global_only=%s\n" \
    "$REGIONS" "$INCLUDE_AMAZON" "$INCLUDE_CLOUDFRONT" "$CLOUDFRONT_GLOBAL_ONLY"

  # Ausgabe: erst v4, dann v6 – beide sind von OPNsense als IP-/Netzlisten akzeptiert
  awk 'NF' "$V4_TMP"
  awk 'NF' "$V6_TMP"

  echo "$END_MARKER"
} >"$BLOCK_TMP"

# ======= Zielverzeichnis/File vorbereiten =======
umask 022
mkdir -p "$TARGET_DIR"
touch "$TARGET_FILE"

# ======= Alten Auto-Block entfernen, neuen einsetzen =======
# 1) Inhalt ohne alten Block (Zeilen zwischen BEGIN..END) extrahieren
sed "/^$(printf '%s' "$BEGIN_MARKER" | sed 's/[^^]/[&]/g; s/\^/\\^/g')$/,/^$(printf '%s' "$END_MARKER" | sed 's/[^^]/[&]/g; s/\^/\\^/g')$/d" \
  "$TARGET_FILE" >"$NEWFILE_TMP"

# 2) Falls die Datei nicht mit Newline endet, fügen wir eine ein
tail -c1 "$NEWFILE_TMP" | read -r _ || echo >>"$NEWFILE_TMP"

# 3) Neu generierten Block anhängen
cat "$BLOCK_TMP" >>"$NEWFILE_TMP"

# 4) Atomar ersetzen
mv "$NEWFILE_TMP" "$TARGET_FILE"

echo "OK: Aktualisiert ${TARGET_FILE} (AWS-Netze in Auto-Block)."
