#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color
CWD=$PWD
export DOCKER_BUILDKIT=0
export COMPOSE_DOCKER_CLI_BUILD=0

# Detect whether this Docker install uses the modern "docker compose" plugin
# or the legacy standalone "docker-compose" binary, and use whichever works.
if docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker-compose"
else
  echo -e "${RED}Error: Docker Compose not found. Install either the 'docker compose' plugin or the standalone 'docker-compose' binary.${NC}"
  exit 1
fi


function ctrl_c() {
        docker stop bootstrap_external-virtuoso-1
        $DOCKER_COMPOSE -f "$CWD/config/docker-compose-${P}.yml" down
        $DOCKER_COMPOSE -f "$CWD/bootstrap_external/docker-compose-${P}.yml" down
        $DOCKER_COMPOSE rm -f "$CWD/config/docker-compose-${P}.yml" -s
        $DOCKER_COMPOSE rm -f "$CWD/bootstrap_external/docker-compose-${P}.yml" -s
        docker network rm bootstrap_external_default bootstrap_external_virtuoso_net
        docker rm bootstrap_external-virtuoso-1

        rm "${CWD}/config/docker-compose-${P}.yml"
        rm "${CWD}/bootstrap_external/docker-compose-${P}.yml"
        rm "${CWD}/config/fdp/application-${P}.yml"

        exit 2
}

trap ctrl_c 2


# List of ports commonly restricted in web browsers (e.g., Firefox, Chrome) for security reasons
# This is based on historical and current browser implementations to prevent access to legacy/insecure services
banned_ports=(
  1 7 9 11 13 15 17 19 20 21 22 23 25 37 42 43 53 69 77 79 87 95
  101 102 103 104 109 110 111 113 115 117 119 123 135 137 139 143 161 179
  389 427 465 512 514 515 526 530 531 532 540 548 554 556 563 587 601 636
  989 990 993 995 1719 1720 1723 2049 3659 4045 4190 5060 5061 6000 6566
  6665 6666 6667 6668 6669 6679 6697 10080
)

# Helper function to check if a port is banned
is_banned_port() {
  local port="$1"
  for banned in "${banned_ports[@]}"; do
    if [ "$banned" = "$port" ]; then
      return 0  # banned
    fi
  done
  return 1  # not banned
}

production="true"


echo "R2F External Installation in Demilitarized Zone"
echo ""


echo "The first question asks for an installation prefix."
echo "The prefix is used to distinguish this installation from other R2F External installations running on the same host."
echo ""
echo "All Docker containers, networks, and volumes created by this installation will use this prefix."
echo ""
echo "Warning: existing resources with the same prefix may be removed."

if [ -z $P ]; then
  read -p "Installation prefix (e.g. euronmd): " P
  if [ -z $P ]; then
    echo "invalid..."
    exit 1
  fi
fi


echo ""
echo "Enter the Base URL for this installation."
echo ""
echo "Production example:"
echo "  https://w3id.org/my-organization"
echo ""
echo "If you are using a proxy or reverse proxy, enter the public URL through which users will access this installation."
echo ""
echo "For local testing, use:"
echo "  http://localhost:<PORT>"
echo ""
echo "Note: localhost installations cannot be registered in public registries."
echo ""
echo "In the next step, you will be asked for the External Server port. If you use the recommended port (7070), enter:"
echo "  http://localhost:7070"

read -p "Base URL: " uri

echo ""
echo ""
echo ""
# FDP_PORT handling
if [ -z "$FDP_PORT" ]; then
echo ""
echo "Choose the port on which the R2F External Server will listen."
echo ""
echo "If you are using a reverse proxy, this is the internal port to which the proxy forwards requests."
echo ""

read -p "R2F External Server port [recommended: 7070]: " FDP_PORT
fi

if [ -z "$FDP_PORT" ]; then
  echo "Error: No port specified for External Server."
  exit 1
fi

if ! [[ "$FDP_PORT" =~ ^[0-9]+$ ]] || (( FDP_PORT < 1 || FDP_PORT > 65535 )); then
  echo "Error: Invalid port '$FDP_PORT' – must be a number between 1 and 65535."
  exit 1
fi

if is_banned_port "$FDP_PORT"; then
  echo "Error: Port $FDP_PORT is restricted in many web browsers (including Firefox and Chrome) for security reasons."
  echo "This will prevent users from connecting to your server through those browsers."
  echo "Please choose a different port. Safe common options include 3000, 4000, 5000, 7070, 8080, 8000, or 9000."
  exit 1
fi


echo ""
echo ""
echo ""

# VIRTUOSO_PORT handling (GDB_PORT is the pre-rename name, still honoured if set)
VIRTUOSO_PORT="${VIRTUOSO_PORT:-$GDB_PORT}"
if [ -z "$VIRTUOSO_PORT" ]; then
echo "Choose the port for the Virtuoso metadata database."
echo ""
echo "By default, Virtuoso is not exposed outside Docker. This port is stored so that database access can be enabled later for maintenance or troubleshooting."
echo ""

read -p "Virtuoso database port [recommended: 8890]: " VIRTUOSO_PORT
fi

if [ -z "$VIRTUOSO_PORT" ]; then
  echo "Error: No port specified for Virtuoso."
  exit 1
fi

if ! [[ "$VIRTUOSO_PORT" =~ ^[0-9]+$ ]] || (( VIRTUOSO_PORT < 1 || VIRTUOSO_PORT > 65535 )); then
  echo "Error: Invalid port '$VIRTUOSO_PORT' – must be a number between 1 and 65535."
  exit 1
fi

if is_banned_port "$VIRTUOSO_PORT"; then
  echo "Error: Port $VIRTUOSO_PORT is restricted in many web browsers (including Firefox and Chrome) for security reasons."
  echo "This will prevent users from connecting to your server through those browsers."
  echo "Please choose a different port. Safe common options include 3000, 4000, 5000, 7200, 8080, 8000, or 9000."
  exit 1
fi


echo ""
echo ""
echo ""
# Virtuoso DBA password handling
# Virtuoso's `dba` superuser password is set directly from this value via the
# image's own DBA_PASSWORD environment variable at container start -- no
# separate admin-API call needed (unlike GraphDB's REST-based security model).
# GRAPHDB_PASSWORD is the pre-rename name, still honoured if set
VIRTUOSO_PASSWORD="${VIRTUOSO_PASSWORD:-$GRAPHDB_PASSWORD}"
if [ -z "$VIRTUOSO_PASSWORD" ]; then
  echo "Choose a password for Virtuoso's 'dba' superuser account."
  read -s -p "Enter a Virtuoso dba password (min 12 characters): " VIRTUOSO_PASSWORD
  echo ""
fi

if [ -z "$VIRTUOSO_PASSWORD" ] || [ "${#VIRTUOSO_PASSWORD}" -lt 12 ] || [ "$VIRTUOSO_PASSWORD" = "root" ] || [ "$VIRTUOSO_PASSWORD" = "admin" ] || [ "$VIRTUOSO_PASSWORD" = "dba" ]; then
  echo "Error: Virtuoso dba password must be at least 12 characters and not a common default such as 'root', 'admin', or 'dba'."
  exit 1
fi

# JWT signing secret used by the FDP server -- generated fresh for this install, never a
# fixed shared value baked into the repo.
JWT_SECRET=$(openssl rand -hex 64)

# MongoDB root password -- generated fresh for this install, same reasoning as JWT_SECRET
# above.
MONGO_PASSWORD=$(openssl rand -hex 32)

mkdir -p $HOME/tmp
export TMPDIR=$HOME/tmp
# PREFIX needed by the main.py script and docker composes
export FDP_PREFIX=$P

# The next few lines clean up any previous installation with this prefix. On a
# fresh, first-ever install there is nothing to clean up, so each of these is
# expected to be a harmless no-op -- silenced rather than left to print scary
# but meaningless "not found"/"requires at least 1 argument" errors.
docker network rm bootstrap_external_default 2>/dev/null || true
docker ps -a | egrep -oh "${P}-R2F.*" | xargs -r docker rm
docker rm -f bootstrap_external-virtuoso-1 config_fdp_1 config_fdp_client_1 2>/dev/null || true
docker volume rm -f "${P}-virtuoso" "${P}-mongo-data" "${P}-mongo-init" 2>/dev/null || true

docker volume create "${P}-virtuoso"
docker volume create "${P}-mongo-data"
docker volume create "${P}-mongo-init"


echo ""
echo ""
echo -e "${GREEN}Creating Virtuoso and bootstrapping it - this will take about a minute"
echo -e "${NC}"
echo ""

cd bootstrap_external
cp docker-compose-template.yml "docker-compose-${P}.yml"
sed -i'' -e "s/{PREFIX}/${P}/" "docker-compose-${P}.yml"
sed -i'' -e "s/{VIRTUOSO_PORT}/${VIRTUOSO_PORT}/" "docker-compose-${P}.yml"
sed -i'' -e "s%{VIRTUOSO_PASS}%${VIRTUOSO_PASSWORD}%" "docker-compose-${P}.yml"
$DOCKER_COMPOSE -f "docker-compose-${P}.yml" down
sleep 10

$DOCKER_COMPOSE -f "docker-compose-${P}.yml" up --build -d
sleep 120
# Do NOT delete docker-compose-${P}.yml here -- the post-install clean-up
# below still needs it to tear down this bootstrap Virtuoso container/network.
# Deleting it this early made that teardown silently fail ("no such file or
# directory"), leaving the bootstrap container and network orphaned on every
# install (found and fixed in R2F Internal's own install script first).

echo ""
echo -e "${GREEN}Setting up R2F External client and server${NC}"
echo ""




cd ../config

cp docker-compose-template.yml "docker-compose-${P}.yml"
cp ./fdp/application-template.yml "./fdp/application-${P}.yml"
echo "A"
sed -i'' -e "s/{PREFIX}/$P/" "docker-compose-${P}.yml"
echo "B"
sed -i'' -e "s/{FDP_PORT}/$FDP_PORT/" "docker-compose-${P}.yml"
echo "C"
sed -i'' -e "s/{PREFIX}/$P/" "./fdp/application-${P}.yml"
echo "D"
sed -i'' -e "s/{FDP_PORT}/$FDP_PORT/" "./fdp/application-${P}.yml"
echo "E"
sed -i'' -e "s%{GUID}%$uri%" "./fdp/application-${P}.yml"
echo "F"
sed -i'' -e "s%{VIRTUOSO_PASS}%${VIRTUOSO_PASSWORD}%" "./fdp/application-${P}.yml"
sed -i'' -e "s%{JWT_SECRET}%${JWT_SECRET}%" "./fdp/application-${P}.yml"
sed -i'' -e "s%{MONGO_PASS}%${MONGO_PASSWORD}%" "docker-compose-${P}.yml"
sed -i'' -e "s%{MONGO_PASS}%${MONGO_PASSWORD}%" "./fdp/application-${P}.yml"
# NOTE: this file is bind-mounted into the fdp container and read by that
# container's own user (uid 100, not the host user), so it must stay
# world-readable -- chmod 600 would make FDP startup fail with a
# "Permission denied" reading application.yml (confirmed by testing).
chmod 644 "./fdp/application-${P}.yml"


$DOCKER_COMPOSE -f "docker-compose-${P}.yml" up --build -d
#$DOCKER_COMPOSE -f "docker-compose-${P}.yml" up --build


sleep 120

echo ""
echo -e "${GREEN}Creating a production server folder in ${NC} ./${P}-R2F-external/"
echo ""

cd ..

rm -rf ./${P}-R2F-external
cp -r ./R2F-external ./${P}-R2F-external
cp ./docker-compose-template.yml "./${P}-R2F-external/docker-compose-${P}.yml"
cp ./${P}-R2F-external/fdp/application-template.yml "./${P}-R2F-external/fdp/application-${P}.yml"
rm ./${P}-R2F-external/fdp/application-template.yml
cp ./${P}-R2F-external/.env_template "./${P}-R2F-external/.env"
echo "1"
sed -i'' -e "s/{PREFIX}/${P}/" "./${P}-R2F-external/docker-compose-${P}.yml"
echo "2"
sed -i'' -e "s/{FDP_PORT}/${FDP_PORT}/" "./${P}-R2F-external/docker-compose-${P}.yml"
echo "3"
sed -i'' -e "s/{VIRTUOSO_PORT}/${VIRTUOSO_PORT}/" "./${P}-R2F-external/docker-compose-${P}.yml"
echo "4"
sed -i'' -e "s/{PREFIX}/${P}/" "./${P}-R2F-external/fdp/application-${P}.yml"
echo "5"
sed -i'' -e "s/{FDP_PORT}/${FDP_PORT}/" "./${P}-R2F-external/fdp/application-${P}.yml"
echo "6"
sed -i'' -e 's|{GUID}|'"${uri}"'|g' "./${P}-R2F-external/fdp/application-${P}.yml"
echo "7"
sed -i'' -e 's|{GUID}|'"${uri}"'|g' "./${P}-R2F-external/.env"
sed -i'' -e "s%{VIRTUOSO_PASS}%${VIRTUOSO_PASSWORD}%" "./${P}-R2F-external/.env"
sed -i'' -e "s%{VIRTUOSO_PASS}%${VIRTUOSO_PASSWORD}%" "./${P}-R2F-external/fdp/application-${P}.yml"
sed -i'' -e "s%{JWT_SECRET}%${JWT_SECRET}%" "./${P}-R2F-external/fdp/application-${P}.yml"
sed -i'' -e "s%{MONGO_PASS}%${MONGO_PASSWORD}%" "./${P}-R2F-external/.env"
sed -i'' -e "s%{MONGO_PASS}%${MONGO_PASSWORD}%" "./${P}-R2F-external/fdp/application-${P}.yml"
# NOTE: bind-mounted into the fdp container and read by that container's own
# user (uid 100, not the host user) -- must stay world-readable, see note above.
chmod 644 "./${P}-R2F-external/fdp/application-${P}.yml"
chmod 600 "./${P}-R2F-external/.env"

echo -e "${GREEN}Installation Complete!"
echo -e "${GREEN}Now doing post-install clean-up..."

$DOCKER_COMPOSE -f "${CWD}/config/docker-compose-${P}.yml" down
$DOCKER_COMPOSE -f "${CWD}/bootstrap_external/docker-compose-${P}.yml" down
$DOCKER_COMPOSE -f "${CWD}/config/docker-compose-${P}.yml" rm -s -f
$DOCKER_COMPOSE -f "${CWD}/bootstrap_external/docker-compose-${P}.yml" rm -s -f
# `down` above already removes the bootstrap compose project's own network
# (bootstrap_external_virtuoso_net); bootstrap_external_default never existed for
# this compose file in the first place. Both are harmless no-ops here --
# silenced rather than left to print misleading "not found" errors after a
# clean down.
docker network rm bootstrap_external_default bootstrap_external_virtuoso_net 2>/dev/null || true
docker stop bootstrap_external-virtuoso-1 2>/dev/null || true
docker rm bootstrap_external-virtuoso-1 2>/dev/null || true

rm "${CWD}/config/docker-compose-${P}.yml"
rm "${CWD}/bootstrap_external/docker-compose-${P}.yml"
rm "${CWD}/config/fdp/application-${P}.yml"

echo ""
echo -e "${GREEN}Installation completed successfully.${NC}"
echo ""
echo -e "${GREEN}Deployment files have been created in:${NC}"
echo "  ./${P}-R2F-external/"
echo ""
echo -e "${GREEN}To start R2F External:${NC}"
echo "  cd ${P}-R2F-external"
echo "  $DOCKER_COMPOSE -f docker-compose-${P}.yml up -d"
echo ""
echo ""
echo -e "${GREEN}Security note:${NC}"
echo "A Virtuoso DBA password, MongoDB root password, and JWT signing secret have been generated automatically for this installation."
echo ""
echo "These settings are stored in:"
echo "  ./${P}-R2F-external/fdp/application-${P}.yml"
echo "  ./${P}-R2F-external/.env"
echo ""
echo "No additional changes are required before deployment."
echo ""

