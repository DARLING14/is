#!/bin/bash
# Geolocator.sh - Precision person/address location tracker for Kali Linux
# Usage: ./Geolocator.sh -t target_name [-a address] [-p phone] [-e email] [-u username]

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Banner
echo -e "${BLUE}"
cat << 'EOF'
██╗  ██╗ █████╗ ███╗   ███╗██████╗  ██████╗ ██████╗ 
██║  ██║██╔══██╗████╗ ████║██╔══██╗██╔═══██╗██╔══██╗
███████║███████║██╔████╔██║██████╔╝██║   ██║██████╔╝
██╔══██║██╔══██║██║╚██╔╝██║██╔══██╗██║   ██║██╔══██╗
██║  ██║██║  ██║██║ ╚═╝ ██║██║  ██║╚██████╔╝██║  ██║
╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝
EOF
echo -e "${NC}"

# Check dependencies
dependencies=("curl" "python3" "whois" "dnsenum" "theHarvester" "maltego" "recon-ng")
missing_deps=()

for dep in "${dependencies[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
        missing_deps+=("$dep")
    fi
done

if [ ${#missing_deps[@]} -ne 0 ]; then
    echo -e "${YELLOW}[!] Missing dependencies: ${missing_deps[*]}${NC}"
    echo -e "${GREEN}[+] Installing missing dependencies...${NC}"
    sudo apt update && sudo apt install -y "${missing_deps[@]}"
fi

# Function to show usage
usage() {
    echo "Usage: $0 -t target_name [options]"
    echo "Options:"
    echo "  -t TARGET     Target name (required)"
    echo "  -a ADDRESS    Known address"
    echo "  -p PHONE      Phone number"
    echo "  -e EMAIL      Email address"
    echo "  -u USERNAME   Social media username"
    echo "  -o OUTPUT     Output directory"
    exit 1
}

# Parse arguments
while getopts "t:a:p:e:u:o:h" opt; do
    case $opt in
        t) TARGET="$OPTARG" ;;
        a) ADDRESS="$OPTARG" ;;
        p) PHONE="$OPTARG" ;;
        e) EMAIL="$OPTARG" ;;
        u) USERNAME="$OPTARG" ;;
        o) OUTPUT="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo -e "${RED}[!] Target name is required (-t)${NC}"
    usage
fi

# Create output directory
OUTPUT_DIR="${OUTPUT:-$(date +%Y%m%d_%H%M%S)_${TARGET// /_}}"
mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR" || exit 1

echo -e "${GREEN}[+] Output directory: $OUTPUT_DIR${NC}"

# 1. Person Name -> Address Resolution
echo -e "${BLUE}[*] Phase 1: Name to Address Resolution${NC}"
python3 << 'EOF'
import requests
import json
import re
from bs4 import BeautifulSoup

def whitepages_search(name, state=None):
    print("[+] Searching Whitepages...")
    url = f"https://www.whitepages.com/name/{name.replace(' ', '-')}"
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    }
    try:
        resp = requests.get(url, headers=headers)
        soup = BeautifulSoup(resp.text, 'html.parser')
        addresses = []
        for item in soup.find_all('div', class_='result'):
            addr = item.find('span', class_='address')
            if addr:
                addresses.append(addr.text.strip())
        return addresses
    except:
        return []

def truepeoplesearch(name):
    print("[+] Searching TruePeopleSearch...")
    url = f"https://www.truepeoplesearch.com/results?name={name.replace(' ', '%20')}"
    addresses = whitepages_search(name)  # Fallback
    return addresses

target = "$TARGET".replace('"', '')
addresses = whitepages_search(target) + truepeoplesearch(target)

with open('addresses.txt', 'w') as f:
    for addr in addresses:
        f.write(addr + '\n')
        print(f"[+] Found address: {addr}")

print(f"[+] Addresses saved to addresses.txt")
EOF

# 2. Reverse Address Lookup
echo -e "${BLUE}[*] Phase 2: Reverse Address Lookup${NC}"
if [ -f "addresses.txt" ]; then
    while IFS= read -r addr; do
        if [ -n "$addr" ]; then
            echo -e "${YELLOW}[+] Processing: $addr${NC}"
            
            # Zillow property details
            curl -s "https://www.zillow.com/homes/$(echo $addr | tr ' ' '-' | tr ',' '%2C')" \
                -H "User-Agent: Mozilla/5.0" | grep -oP '(?<=property-details")[^"]*' >> property_data.txt
            
            # Google Maps coordinates
            coords=$(curl -s "https://nominatim.openstreetmap.org/search?q=$(echo $addr | sed 's/ /+/g')&format=json" \
                | grep -o '"lat":[^,}]*' | head -1 | cut -d: -f2 | tr -d ' ')
            if [ -n "$coords" ]; then
                lat=$(echo $coords | cut -d, -f1)
                lon=$(echo $coords | cut -d, -f2)
                echo "$addr | $lat,$lon" >> coordinates.txt
                echo -e "${GREEN}[+] Coordinates: $lat, $lon${NC}"
            fi
        fi
    done < addresses.txt
fi

# 3. Social Media Username Enumeration
if [ -n "$USERNAME" ]; then
    echo -e "${BLUE}[*] Phase 3: Social Media Enumeration${NC}"
    theHarvester -d "$USERNAME" -b linkedin,twitter,facebook -f social_results.html
fi

# 4. Phone Number Geolocation
if [ -n "$PHONE" ]; then
    echo -e "${BLUE}[*] Phase 4: Phone Geolocation${NC}"
    curl -s "https://www.freecarrierlookup.com/index.php?phone=$PHONE" > phone_info.html
    grep -i "location\|city\|state\|address" phone_info.html >> phone_geodata.txt
fi

# 5. Email to Person/Address
if [ -n "$EMAIL" ]; then
    echo -e "${BLUE}[*] Phase 5: Email Recon${NC}"
    recon-ng -r email_to_person.rc --options email="$EMAIL"
fi

# 6. Generate KML for Google Earth
echo -e "${BLUE}[*] Phase 6: KML Generation${NC}"
cat > locations.kml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
<Document>
EOF

if [ -f "coordinates.txt" ]; then
    while IFS='|' read -r addr coords; do
        if [[ $coords =~ ([0-9.-]+),([0-9.-]+) ]]; then
            lat="${BASH_REMATCH[1]}"
            lon="${BASH_REMATCH[2]}"
            cat >> locations.kml << EOF
  <Placemark>
    <name>$(echo "$addr" | sed 's/&/\&amp;/g')</name>
    <Point><coordinates>$lon,$lat,0</coordinates></Point>
  </Placemark>
EOF
        fi
    done < coordinates.txt
fi

cat >> locations.kml << 'EOF'
</Document>
</kml>
EOF

# 7. Generate HTML Report
cat > report.html << EOF
<!DOCTYPE html>
<html>
<head><title>GeoLocator Report: $TARGET</title></head>
<body>
<h1>GeoLocator Results: $TARGET</h1>
<h2>Found Addresses:</h2>
<pre>$(cat addresses.txt 2>/dev/null || echo "None found")</pre>
<h2>Coordinates:</h2>
<pre>$(cat coordinates.txt 2>/dev/null || echo "None found")</pre>
<h2>Phone Data:</h2>
<pre>$(cat phone_geodata.txt 2>/dev/null || echo "None found")</pre>
<p><a href="locations.kml">Download KML for Google Earth</a></p>
</body>
</html>
EOF

echo -e "${GREEN}"
echo "=============================================="
echo "GEOLOCATOR COMPLETE - Results in: $OUTPUT_DIR"
echo "=============================================="
echo "- addresses.txt     : Found addresses"
echo "- coordinates.txt   : GPS coordinates"
echo "- locations.kml     : Google Earth overlay"
echo "- report.html       : Complete HTML report"
echo "- social_results.html : Social media data"
echo "==============================================${NC}"

# Open report in browser
xdg-open "file://$PWD/report.html"