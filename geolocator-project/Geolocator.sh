 #!/bin/bash
# Geolocator v3.0 - Enhanced OSINT Geolocation Tool
# Dependencies: whois, dig, host, curl, jq, theHarvester (optional)
# Usage: ./geolocator.sh -t "Target Name" [-p phone] [-e email]

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if ! command -v jq &> /dev/null; then
  echo -e "${RED}[-] jq is required but not installed. Install with: sudo apt install jq${NC}"
  exit 1
fi

echo -e "${BLUE}"
echo "██╗  ██╗ █████╗ ███╗   ███╗██████╗"
echo "GEOLOCATOR v3.0 - Enhanced OSINT Geolocation${NC}\n"

# Parse args
TARGET=""
PHONE=""
EMAIL=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--target) TARGET="$2"; shift 2 ;;
        -p|--phone) PHONE="$2"; shift 2 ;;
        -e|--email) EMAIL="$2"; shift 2 ;;
        *) echo "Usage: $0 -t 'John Doe' [-p 5551234567] [-e email@domain.com]"; exit 1 ;;
    esac
done

[ -z "$TARGET" ] && { echo -e "${RED}[-] Target is required${NC}"; exit 1; }

OUTPUT="geoloc_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTPUT" && cd "$OUTPUT"

echo -e "${GREEN}[+] Saving output in: $PWD${NC}\n"

# 1. WHOIS + DNS Recon
echo -e "${BLUE}[*] WHOIS and DNS Recon${NC}"
if [[ "$TARGET" == *"."* ]]; then
    whois "$TARGET" > whois.txt 2>/dev/null || echo "[!] whois failed"
    dig +short "$TARGET" > dns.txt 2>/dev/null
    host "$TARGET" >> dns.txt 2>/dev/null
else
    echo "[*] Target not domain, skipping whois/dns"
fi

# Optional: TheHarvester
if command -v theHarvester &> /dev/null && [[ "$TARGET" != *"."* ]]; then
    echo -e "${BLUE}[*] Running theHarvester${NC}"
    theHarvester -d "$TARGET" -l 100 -b google,bing -f harvester.html || echo "[!] theHarvester failed"
fi

# 2. Google dorking for address keywords
echo -e "${BLUE}[*] Google Dorking for addresses (limited by scraping)${NC}"
SEARCH_QUERY=$(echo "\"$TARGET\"+\"address\"+OR+\"$TARGET\"+\"street\"+OR+\"$TARGET\"+\"lives+at\"" | sed 's/ /%20/g')
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0 Safari/537.36"

curl -s -A "$USER_AGENT" "https://www.google.com/search?q=${SEARCH_QUERY}" | \
    grep -Ei "(street|road|avenue|drive|lane|blvd|apt|apartment|city|state)" | \
    head -40 > google_dorks.txt

# 3. Phone lookup if provided
if [ -n "$PHONE" ]; then
    echo -e "${BLUE}[*] Phone Lookup${NC}"
    PHONE_CLEAN=$(echo "$PHONE" | tr -cd '[:digit:]')
    curl -s -A "$USER_AGENT" "https://www.numbertracking.com/phone-lookup/$PHONE_CLEAN" > phone.html
    grep -i "city\|state\|location\|address" phone.html > phone_data.txt || echo "[!] Phone lookup parsing failed"
fi

# 4. Extract addresses from gathered data
echo -e "${BLUE}[*] Extracting raw addresses${NC}"
cat google_dorks.txt whois.txt 2>/dev/null | \
grep -Ei "(street|road|ave|dr|ln|blvd|apt|apartment|city|state)" | \
sed 's/[^a-zA-Z0-9 ,.-]//g' | sort -u > raw_addresses.txt

# 5. Geocode addresses with Nominatim using jq to parse JSON
echo -e "${BLUE}[*] Geocoding addresses with OpenStreetMap Nominatim${NC}"
> coordinates.txt
while IFS= read -r addr; do
    [ -z "$addr" ] && continue
    echo -e "${YELLOW}[+] Geocoding: $addr${NC}"
    # Respect Nominatim usage policy: max 1 req/sec
    sleep 1
    json=$(curl -s -A "$USER_AGENT" "https://nominatim.openstreetmap.org/search?format=json&limit=1&q=$(echo "$addr" | sed 's/ /%20/g')")
    lat=$(echo "$json" | jq -r '.[0].lat // empty')
    lon=$(echo "$json" | jq -r '.[0].lon // empty')
    if [[ -n "$lat" && -n "$lon" ]]; then
        echo "$addr | $lat,$lon" >> coordinates.txt
        echo -e "${GREEN}[+] Found: $lat,$lon${NC}"
    else
        echo -e "${RED}[-] No result for: $addr${NC}"
    fi
done < raw_addresses.txt

# 6. Generate Google Maps links and KML
if [ -s coordinates.txt ]; then
    echo -e "${BLUE}[*] Generating Google Maps URLs and KML file${NC}"
    > maps_links.txt

    # Google Maps links
    while IFS= read -r line; do
        coords=$(echo "$line" | grep -oE '[0-9.-]+,[0-9.-]+')
        if [ -n "$coords" ]; then
            echo "https://www.google.com/maps?q=$coords" >> maps_links.txt
        fi
    done < coordinates.txt

    # KML file
    cat > pinpoint.kml << EOF
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
<Document>
<name>$TARGET Locations</name>
EOF

    while IFS= read -r line; do
        coords=$(echo "$line" | grep -oE '[0-9.-]+,[0-9.-]+')
        addr=$(echo "$line" | cut -d'|' -f1 | xargs)
        if [ -n "$coords" ]; then
            lat=$(echo "$coords" | cut -d, -f1)
            lon=$(echo "$coords" | cut -d, -f2)
            cat >> pinpoint.kml << EOF
  <Placemark>
    <name>$addr</name>
    <Point><coordinates>$lat,$lon,0</coordinates></Point>
  </Placemark>
EOF
        fi
    done < coordinates.txt

    echo "</Document></kml>" >> pinpoint.kml
    echo -e "${GREEN}[+] KML file created: pinpoint.kml${NC}"
else
    echo -e "${RED}[-] No coordinates found, skipping map generation${NC}"
fi

# 7. Summary report
echo -e "\n${GREEN}========== RESULTS SUMMARY ==========${NC}"
echo "Target: $TARGET"
echo "Output folder: $PWD"
echo ""
if [ -s coordinates.txt ]; then
    echo "✅ Coordinates found: $(wc -l < coordinates.txt)"
else
    echo "❌ No coordinates found"
fi

if [ -s maps_links.txt ]; then
    echo "✅ Google Maps links file: maps_links.txt"
    echo "First link: $(head -1 maps_links.txt)"
else
    echo "❌ No map links generated"
fi

echo "Files generated:"
echo "  coordinates.txt  - Addresses with lat,long"
echo "  maps_links.txt   - Google Maps URLs"
echo "  pinpoint.kml     - KML file for Google Earth"
echo "  google_dorks.txt - Google Scraped addresses"
echo ""

echo -e "${YELLOW}[+] You can copy any lat,long coordinate to Google Maps:${NC}"
echo "https://www.google.com/maps?q=LAT,LON"

# Optionally open first Google Maps link
if [ -s maps_links.txt ]; then
    if command -v xdg-open &> /dev/null; then
        xdg-open "$(head -1 maps_links.txt)" 2>/dev/null
    fi
fi

echo -e "${GREEN}[+] Geolocation OSINT completed. Check directory: $PWD${NC}"
