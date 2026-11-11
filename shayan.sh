#!/usr/bin/env bash
# Shayan Multi-Tunnel Manager
# TCP, UDP or combined port forwarding over GRE
set -u

BASE="/etc/vatan-gre-manager"
PROFILES="$BASE/profiles"
ACTIVE="$BASE/active"
TAG="vatan-mtm"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf 'Run this manager as root (sudo bash vatan_multi_tunnel_manager.sh).\n' >&2
  exit 1
fi

mkdir -p a"$PROFILES" || exit 1
chmod 700 "$BASE" "$PROFILES" 2>/dev/null || true
umask 077

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_CYAN=$'\033[96m'
  C_BLUE=$'\033[94m'
  C_WHITE=$'\033[97m'
  C_GREEN=$'\033[92m'
  C_YELLOW=$'\033[93m'
  C_RED=$'\033[91m'
  C_DIM=$'\033[2;37m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_CYAN='' C_BLUE='' C_WHITE='' C_GREEN='' C_YELLOW='' C_RED='' C_DIM='' C_BOLD='' C_RESET=''
fi

msg()  { printf '%b•%b %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%b✓%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b!%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%b×%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

section_title() {
  printf '\n  %b%b%s%b\n  %b────────────────────────────────────────%b\n' \
    "$C_BOLD" "$C_CYAN" "$1" "$C_RESET" "$C_DIM" "$C_RESET"
}

menu_item() {
  printf '  %b[%s]%b  %b%s%b\n' "$C_BOLD$C_BLUE" "$1" "$C_RESET" "$C_WHITE" "$2" "$C_RESET"
}

prompt_read() {
  local variable=$1 prompt=$2 status
  if [[ $prompt =~ ^([^()]*)\(([^()]*)\)(.*)$ ]]; then
    printf '%b%s%b(%s)%b%s' "$C_WHITE" "${BASH_REMATCH[1]}" "$C_BLUE" "${BASH_REMATCH[2]}" "$C_WHITE" "${BASH_REMATCH[3]}"
  else
    printf '%b%s' "$C_WHITE" "$prompt"
  fi
  IFS= read -r "$variable"
  status=$?
  printf '%b' "$C_RESET"
  return "$status"
}

confirm_default_yes() {
  local prompt=$1 answer
  prompt_read answer "$prompt [Y/n]: " || return 1
  [[ -z $answer || $answer =~ ^[Yy]([Ee][Ss])?$ ]]
}

goodbye() {
  printf '\nGood Bye :)\n'
  exit 0
}

for cmd in ip iptables iptables-save sysctl grep cksum; do
  command -v "$cmd" >/dev/null 2>&1 || { err "Required command is missing: $cmd"; exit 1; }
done

valid_profile() { [[ $1 =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; }
valid_name()    { [[ $1 =~ ^[a-zA-Z0-9_-]{1,15}$ ]]; }

valid_ipv4() {
  local value=$1 a b c d octet
  [[ $value =~ ^[0-9]{1,3}[.][0-9]{1,3}[.][0-9]{1,3}[.][0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<< "$value"
  for octet in "$a" "$b" "$c" "$d"; do
    (( 10#$octet <= 255 )) || return 1
  done
}

detect_public_ipv4() {
  local candidate=''
  if command -v curl >/dev/null 2>&1; then
    candidate=$(curl -4fsS --connect-timeout 3 --max-time 6 https://api.ipify.org 2>/dev/null || true)
  fi
  if ! valid_ipv4 "${candidate//$'\n'/}" && command -v wget >/dev/null 2>&1; then
    candidate=$(wget -4qO- --timeout=6 https://api.ipify.org 2>/dev/null || true)
  fi
  candidate=${candidate//$'\r'/}
  candidate=${candidate//$'\n'/}
  valid_ipv4 "$candidate" || return 1
  printf '%s' "$candidate"
}

valid_port() {
  [[ $1 =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_port_mode() { [[ $1 == ALL || $1 == CUSTOM ]]; }

valid_key() {
  if [[ $1 =~ ^[0-9]{1,10}$ ]]; then
    (( 10#$1 >= 1 && 10#$1 <= 4294967295 ))
    return
  fi
  [[ $1 =~ ^[A-Za-z0-9]{15}$ && $1 =~ [A-Z] && $1 =~ [a-z] && $1 =~ [0-9] ]]
}

generate_gre_key() {
  local candidate
  while true; do
    candidate=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 15)
    [[ ${#candidate} == 15 ]] || return 1
    if [[ $candidate =~ [A-Z] && $candidate =~ [a-z] && $candidate =~ [0-9] ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
}

gre_key_number() {
  if [[ $KEY =~ ^[0-9]+$ ]]; then
    printf '%s' "$((10#$KEY))"
  else
    local number
    read -r number _ < <(printf '%s' "$KEY" | cksum)
    [[ $number != 0 ]] || number=1
    printf '%s' "$number"
  fi
}

valid_subnet() {
  [[ $1 =~ ^[0-9]{1,3}$ ]] || return 1
  (( 10#$1 >= 1 && 10#$1 <= 254 ))
}

validate_fields() {
  local profile=$1 tunnel=$2 role=$3 iran_ip=$4 foreign_ip=$5 key=$6 port=$7 subnet=$8 mode=${9:-CUSTOM}
  valid_profile "$profile" || { err "Profile name must be 1-32 letters, digits, _ or -."; return 1; }
  valid_name "$tunnel" || { err "Interface name must be 1-15 letters, digits, _ or -."; return 1; }
  [[ $role == 1 || $role == 2 ]] || { err "Choose role 1 (Iran) or 2 (Foreign)."; return 1; }
  valid_ipv4 "$iran_ip" && valid_ipv4 "$foreign_ip" || { err "Enter valid IPv4 addresses."; return 1; }
  [[ $iran_ip != "$foreign_ip" ]] || { err "Iran and Foreign IPs must be different."; return 1; }
  valid_key "$key" || { err "GRE Key must be a 15-character mix of uppercase, lowercase and digits."; return 1; }
  valid_port_mode "$mode" || { err "Choose all ports or a custom port."; return 1; }
  if [[ $mode == CUSTOM ]]; then
    valid_port "$port" || { err "Custom port must be between 1 and 65535."; return 1; }
  fi
  valid_subnet "$subnet" || { err "Subnet ID must be between 1 and 254."; return 1; }
}

unique_settings() {
  local tunnel=$1 subnet=$2 exclude=${3:-} file
  for file in "$PROFILES"/*.conf; do
    [[ -f $file ]] || continue
    [[ -n $exclude && $file == "$PROFILES/$exclude.conf" ]] && continue
    if grep -qxF "TUNNEL=$tunnel" "$file"; then
      err "Interface $tunnel is already assigned to another profile."
      return 1
    fi
    if grep -qxF "SUBNET_ID=$subnet" "$file"; then
      err "Subnet ID $subnet is already used by another profile."
      return 1
    fi
  done
}

save_profile() {
  local file="$PROFILES/$PROFILE.conf"
  {
    printf 'PROFILE=%q\n' "$PROFILE"
    printf 'TUNNEL=%q\n' "$TUNNEL"
    printf 'ROLE=%q\n' "$ROLE"
    printf 'IRAN_IP=%q\n' "$IRAN_IP"
    printf 'FOREIGN_IP=%q\n' "$FOREIGN_IP"
    printf 'KEY=%q\n' "$KEY"
    printf 'PORT_MODE=%q\n' "$PORT_MODE"
    printf 'SERVICE_PORT=%q\n' "$SERVICE_PORT"
    printf 'PROTOCOL=%q\n' "$PROTOCOL"
    printf 'SUBNET_ID=%q\n' "$SUBNET_ID"
  } > "$file" || return 1
  chmod 600 "$file"
}

load_profile() {
  local requested=$1 file old_protocol old_key old_port old_subnet
  valid_profile "$requested" || return 1
  file="$PROFILES/$requested.conf"
  [[ -f $file && -r $file ]] || return 1

  unset PROFILE TUNNEL ROLE IRAN_IP FOREIGN_IP KEY PORT_MODE SERVICE_PORT PROTOCOL SUBNET_ID
  # Root-only profile files are generated by this manager.
  # shellcheck disable=SC1090
  source "$file" || return 1

  [[ ${PROFILE:-} == "$requested" ]] || return 1
  valid_name "${TUNNEL:-}" || return 1
  [[ ${ROLE:-} == 1 || ${ROLE:-} == 2 ]] || return 1
  valid_ipv4 "${IRAN_IP:-}" && valid_ipv4 "${FOREIGN_IP:-}" || return 1
  [[ $IRAN_IP != "$FOREIGN_IP" ]] || return 1
  PORT_MODE=${PORT_MODE:-CUSTOM}
  valid_key "${KEY:-}" && valid_port_mode "$PORT_MODE" && valid_subnet "${SUBNET_ID:-}" || return 1
  if [[ $PORT_MODE == CUSTOM ]]; then
    valid_port "${SERVICE_PORT:-}" || return 1
  else
    SERVICE_PORT=0
  fi

  old_protocol=${PROTOCOL:-TCP}
  [[ $old_protocol == TCP || $old_protocol == UDP || $old_protocol == BOTH ]] || return 1
  old_key=$KEY old_port=$SERVICE_PORT old_subnet=$SUBNET_ID
  SERVICE_PORT=$((10#$SERVICE_PORT))
  SUBNET_ID=$((10#$SUBNET_ID))
  PROTOCOL=$old_protocol
  if [[ $old_key != "$KEY" || $old_port != "$SERVICE_PORT" || $old_subnet != "$SUBNET_ID" ]]; then
    save_profile || return 1
  fi
}

protocol_list() {
  case $PROTOCOL in
    TCP) printf 'tcp\n' ;;
    UDP) printf 'udp\n' ;;
    BOTH) printf 'tcp\nudp\n' ;;
  esac
}

local_ip()          { [[ $ROLE == 1 ]] && printf '%s' "$IRAN_IP" || printf '%s' "$FOREIGN_IP"; }
remote_ip()         { [[ $ROLE == 1 ]] && printf '%s' "$FOREIGN_IP" || printf '%s' "$IRAN_IP"; }
local_tunnel_cidr() { [[ $ROLE == 1 ]] && printf '10.200.%s.2/30' "$SUBNET_ID" || printf '10.200.%s.1/30' "$SUBNET_ID"; }
remote_tunnel_ip()  { [[ $ROLE == 1 ]] && printf '10.200.%s.1' "$SUBNET_ID" || printf '10.200.%s.2' "$SUBNET_ID"; }
port_label()         { [[ ${PORT_MODE:-CUSTOM} == ALL ]] && printf 'ALL EXCEPT 22' || printf '%s' "$SERVICE_PORT"; }

exists() { ip link show dev "$TUNNEL" >/dev/null 2>&1; }

link_state() {
  if ! exists; then printf 'NOT CREATED'; return; fi
  if ip -o link show dev "$TUNNEL" 2>/dev/null | grep -qE '<[^>]*,UP([,>])'; then
    printf 'UP'
  else
    printf 'DOWN'
  fi
}

active_profile() {
  [[ -f $ACTIVE ]] && tr -d '\r\n' < "$ACTIVE"
}

rule_add() {
  local table=$1
  shift
  if [[ $table == filter ]]; then
    iptables -w -C "$@" >/dev/null 2>&1 || iptables -w -A "$@"
  else
    iptables -w -t "$table" -C "$@" >/dev/null 2>&1 || iptables -w -t "$table" -A "$@"
  fi
}

rule_del() {
  local table=$1
  shift
  if [[ $table == filter ]]; then
    while iptables -w -C "$@" >/dev/null 2>&1; do iptables -w -D "$@" || break; done
  else
    while iptables -w -t "$table" -C "$@" >/dev/null 2>&1; do
      iptables -w -t "$table" -D "$@" || break
    done
  fi
}

remove_protocol_rules() {
  local proto=$1 comment="$TAG-$PROFILE" endpoint destination
  local -a port_args
  endpoint=$(remote_tunnel_ip)
  if [[ $PORT_MODE == ALL ]]; then
    port_args=(-m multiport --dports '1:21,23:65535')
    destination=$endpoint
  else
    port_args=(--dport "$SERVICE_PORT")
    destination="$endpoint:$SERVICE_PORT"
  fi
  rule_del nat PREROUTING -p "$proto" "${port_args[@]}" \
    -m comment --comment "$comment" -j DNAT --to-destination "$destination"
  rule_del filter FORWARD -o "$TUNNEL" -d "$endpoint" -p "$proto" "${port_args[@]}" \
    -m comment --comment "$comment" -j ACCEPT
  rule_del nat POSTROUTING -o "$TUNNEL" -d "$endpoint" -p "$proto" "${port_args[@]}" \
    -m comment --comment "$comment" -j MASQUERADE
}

remove_rules() {
  [[ $ROLE == 1 ]] || return 0
  remove_protocol_rules tcp
  remove_protocol_rules udp
  rule_del filter FORWARD -i "$TUNNEL" -m conntrack --ctstate ESTABLISHED,RELATED \
    -m comment --comment "$TAG-$PROFILE" -j ACCEPT
}

apply_rules() {
  [[ $ROLE == 1 ]] || return 0
  local comment="$TAG-$PROFILE" endpoint destination
  local -a port_args
  endpoint=$(remote_tunnel_ip)
  if [[ $PORT_MODE == ALL ]]; then
    port_args=(-m multiport --dports '1:21,23:65535')
    destination=$endpoint
  else
    port_args=(--dport "$SERVICE_PORT")
    destination="$endpoint:$SERVICE_PORT"
  fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null || return 1

  remove_rules || return 1
  local proto
  while IFS= read -r proto; do
    [[ -n $proto ]] || continue
    rule_add nat PREROUTING -p "$proto" "${port_args[@]}" \
      -m comment --comment "$comment" -j DNAT --to-destination "$destination" || return 1
    rule_add filter FORWARD -o "$TUNNEL" -d "$endpoint" -p "$proto" "${port_args[@]}" \
      -m comment --comment "$comment" -j ACCEPT || return 1
    rule_add nat POSTROUTING -o "$TUNNEL" -d "$endpoint" -p "$proto" "${port_args[@]}" \
      -m comment --comment "$comment" -j MASQUERADE || return 1
  done < <(protocol_list)
  rule_add filter FORWARD -i "$TUNNEL" -m conntrack --ctstate ESTABLISHED,RELATED \
    -m comment --comment "$comment" -j ACCEPT
}

with_active() {
  local profile
  profile=$(active_profile)
  [[ -n $profile ]] || { err "Create or select a profile first."; return 1; }
  load_profile "$profile" || { err "Active profile is missing or invalid."; return 1; }
}

pause_screen() {
  printf '\n%bPress Enter to return to the menu...%b' "$C_DIM" "$C_RESET"
  read -r _ || true
}

role_label() { [[ $1 == 1 ]] && printf 'IRAN' || printf 'FOREIGN'; }

draw_header() {
  local profile role state
  [[ -t 1 ]] && clear 2>/dev/null || true
  printf '\n%b%b' "$C_BLUE" "$C_BOLD"
  cat <<'SHAYAN_LOGO'
 ███████╗██╗  ██╗ █████╗ ██╗   ██╗ █████╗ ███╗   ██╗
 ██╔════╝██║  ██║██╔══██╗╚██╗ ██╔╝██╔══██╗████╗  ██║
 ███████╗███████║███████║ ╚████╔╝ ███████║██╔██╗ ██║
 ╚════██║██╔══██║██╔══██║  ╚██╔╝  ██╔══██║██║╚██╗██║
 ███████║██║  ██║██║  ██║   ██║   ██║  ██║██║ ╚████║
 ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═══╝
SHAYAN_LOGO
  printf '%b' "$C_RESET"
  printf '  %bGRE TUNNEL MANAGER%b\n' "$C_WHITE" "$C_RESET"

  profile=$(active_profile)
  if [[ -n $profile ]] && load_profile "$profile"; then
    role=$(role_label "$ROLE")
    state=$(link_state)
    printf '  %bPROFILE%b  %b%-16s%b  %bROLE%b  %b%-8s%b\n' "$C_CYAN" "$C_RESET" "$C_WHITE" "$PROFILE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_WHITE" "$role" "$C_RESET"
    printf '  %bTUNNEL%b   %b%-16s%b  %bLINK%b  ' "$C_CYAN" "$C_RESET" "$C_WHITE" "$TUNNEL" "$C_RESET" "$C_CYAN" "$C_RESET"
    case $state in
      UP) printf '%b%s%b\n' "$C_GREEN" "$state" "$C_RESET" ;;
      DOWN) printf '%b%s%b\n' "$C_YELLOW" "$state" "$C_RESET" ;;
      *) printf '%b%s%b\n' "$C_DIM" "$state" "$C_RESET" ;;
    esac
    printf '  %bSERVICE%b  %b%s / %s%b  %bPEER%b  %b%s%b\n' "$C_CYAN" "$C_RESET" "$C_WHITE" "$PROTOCOL" "$(port_label)" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_WHITE" "$(remote_ip)" "$C_RESET"
    printf '  %bTUNNEL IP%b %b%s%b  →  %b%s%b\n\n' "$C_CYAN" "$C_RESET" "$C_WHITE" "$(local_tunnel_cidr)" "$C_RESET" "$C_WHITE" "$(remote_tunnel_ip)" "$C_RESET"
  else
    printf '  %bNo active profile%b\n\n' "$C_YELLOW" "$C_RESET"
  fi
}

show_profiles() {
  local file name old_profile
  old_profile=$(active_profile)
  printf '\n%bSAVED PROFILES%b\n' "$C_BOLD" "$C_RESET"
  for file in "$PROFILES"/*.conf; do
    [[ -f $file ]] || continue
    name=${file##*/}
    name=${name%.conf}
    if load_profile "$name"; then
      printf '  %-16s  %-8s  %-5s/%-14s  subnet %s\n' "$PROFILE" "$(role_label "$ROLE")" "$PROTOCOL" "$(port_label)" "$SUBNET_ID"
    else
      printf '  %-16s  %bINVALID PROFILE%b\n' "$name" "$C_RED" "$C_RESET"
    fi
  done
  if [[ -n $old_profile ]]; then load_profile "$old_profile" >/dev/null 2>&1 || true; fi
}

choose_role() {
  local input
  prompt_read input "Server role [1 Iran / 2 Foreign]: " || return 1
  [[ $input == 1 || $input == 2 ]] || { err "Choose 1 or 2."; return 1; }
  ROLE=$input
}

choose_protocol() {
  local input default=${1:-}
  if [[ -n $default ]]; then
    prompt_read input "Service protocol [1 TCP / 2 UDP / 3 BOTH] [$default]: " || return 1
    input=${input:-$default}
  else
    prompt_read input "Service protocol [1 TCP / 2 UDP / 3 BOTH]: " || return 1
    [[ -n $input ]] || { err "Service protocol is required."; return 1; }
  fi
  case ${input^^} in
    1|TCP) PROTOCOL=TCP ;;
    2|UDP) PROTOCOL=UDP ;;
    3|BOTH) PROTOCOL=BOTH ;;
    *) err "Choose 1 (TCP), 2 (UDP) or 3 (BOTH)."; return 1 ;;
  esac
}

choose_port_mode() {
  local default_mode=${1:-} default_port=${2:-} input default_choice
  case $default_mode in ALL) default_choice=1 ;; CUSTOM) default_choice=2 ;; *) default_choice='' ;; esac
  if [[ -n $default_choice ]]; then
    prompt_read input "Port forwarding [1 All ports except 22 / 2 Custom port] [$default_choice]: " || return 1
    input=${input:-$default_choice}
  else
    prompt_read input "Port forwarding [1 All ports except 22 / 2 Custom port]: " || return 1
    [[ -n $input ]] || { err "Choose all ports or a custom port."; return 1; }
  fi
  case $input in
    1|ALL) PORT_MODE=ALL; SERVICE_PORT=0 ;;
    2|CUSTOM)
      PORT_MODE=CUSTOM
      if [[ -n $default_port && $default_port != 0 ]]; then
        prompt_read SERVICE_PORT "Custom service port [$default_port]: " || return 1
        SERVICE_PORT=${SERVICE_PORT:-$default_port}
      else
        prompt_read SERVICE_PORT "Custom service port: " || return 1
      fi
      valid_port "$SERVICE_PORT" || { err "Custom port must be between 1 and 65535."; return 1; }
      ;;
    *) err "Choose 1 (all except 22) or 2 (custom port)."; return 1 ;;
  esac
}

create_profile() {
  local input detected
  PROFILE=''
  prompt_read PROFILE "Profile name (letters, digits, _ or -): " || return 1
  valid_profile "$PROFILE" || { err "Invalid profile name."; return 1; }
  [[ ! -e "$PROFILES/$PROFILE.conf" ]] || { err "That profile already exists."; return 1; }

  prompt_read TUNNEL "Tunnel interface name: " || return 1
  choose_role || return 1

  detected=$(detect_public_ipv4 || true)
  if [[ -n $detected ]]; then
    if [[ $ROLE == 1 ]]; then
      printf 'Detected this Iran server public IP: %s\n' "$detected"
      prompt_read input "Iran public IP (Enter accepts detected IP): " || return 1
      IRAN_IP=${input:-$detected}
      prompt_read FOREIGN_IP "Foreign public IP: " || return 1
    else
      printf 'Detected this Foreign server public IP: %s\n' "$detected"
      prompt_read IRAN_IP "Iran public IP: " || return 1
      prompt_read input "Foreign public IP (Enter accepts detected IP): " || return 1
      FOREIGN_IP=${input:-$detected}
    fi
  else
    warn "Could not detect this server's public IP. Enter both addresses manually."
    prompt_read IRAN_IP "Iran public IP: " || return 1
    prompt_read FOREIGN_IP "Foreign public IP: " || return 1
  fi
  if [[ $ROLE == 1 ]]; then
    KEY=$(generate_gre_key) || { err "Could not generate a random GRE key."; return 1; }
    printf '\n%bGenerated GRE key (enter this same key on the Foreign server):%b\n  %b%s%b\n\n' \
      "$C_BOLD$C_WHITE" "$C_RESET" "$C_BOLD$C_BLUE" "$KEY" "$C_RESET"
  else
    prompt_read KEY "GRE Key (paste the 15-character key from Iran): " || return 1
  fi
  choose_port_mode || return 1
  choose_protocol || return 1
  prompt_read SUBNET_ID "Subnet ID 1-254: " || return 1

  validate_fields "$PROFILE" "$TUNNEL" "$ROLE" "$IRAN_IP" "$FOREIGN_IP" "$KEY" "$SERVICE_PORT" "$SUBNET_ID" "$PORT_MODE" || return 1
  [[ $PORT_MODE == CUSTOM ]] && SERVICE_PORT=$((10#$SERVICE_PORT))
  SUBNET_ID=$((10#$SUBNET_ID))
  unique_settings "$TUNNEL" "$SUBNET_ID" || return 1
  save_profile || { err "Could not save profile."; return 1; }
  printf '%s' "$PROFILE" > "$ACTIVE"
  ok "Profile saved and selected. Create the matching profile on the other server with the opposite role."
}

select_profile() {
  local profile
  show_profiles
  printf '\n'
  prompt_read profile "Profile name to activate: " || return 1
  load_profile "$profile" || { err "Profile not found or invalid."; return 1; }
  printf '%s' "$profile" > "$ACTIVE"
  ok "Active profile: $profile"
}

edit_profile() {
  with_active || return 1
  local old_tunnel=$TUNNEL old_role=$ROLE old_iran=$IRAN_IP old_foreign=$FOREIGN_IP
  local old_key=$KEY old_port=$SERVICE_PORT old_port_mode=$PORT_MODE old_subnet=$SUBNET_ID old_protocol=$PROTOCOL input
  local new_tunnel new_role new_iran new_foreign new_key new_port new_port_mode new_subnet new_protocol
  local needs_recreate=0 was_created=0

  printf '\n%bEdit profile: %s%b\n' "$C_BOLD" "$PROFILE" "$C_RESET"
  prompt_read input "Tunnel interface [$old_tunnel]: " || return 1
  new_tunnel=${input:-$old_tunnel}
  prompt_read input "Role 1 Iran / 2 Foreign [$old_role]: " || return 1
  new_role=${input:-$old_role}
  prompt_read input "Iran public IP [$old_iran]: " || return 1
  new_iran=${input:-$old_iran}
  prompt_read input "Foreign public IP [$old_foreign]: " || return 1
  new_foreign=${input:-$old_foreign}
  prompt_read input "GRE Key [$old_key]: " || return 1
  new_key=${input:-$old_key}
  choose_port_mode "$old_port_mode" "$old_port" || return 1
  new_port_mode=$PORT_MODE
  new_port=$SERVICE_PORT
  choose_protocol "$old_protocol" || return 1
  new_protocol=$PROTOCOL
  prompt_read input "Subnet ID [$old_subnet]: " || return 1
  new_subnet=${input:-$old_subnet}

  validate_fields "$PROFILE" "$new_tunnel" "$new_role" "$new_iran" "$new_foreign" "$new_key" "$new_port" "$new_subnet" "$new_port_mode" || return 1
  new_port_mode=${new_port_mode:-CUSTOM}
  if [[ $new_key =~ ^[0-9]+$ ]]; then new_key=$((10#$new_key)); fi
  [[ $new_port_mode == CUSTOM ]] && new_port=$((10#$new_port))
  new_subnet=$((10#$new_subnet))
  unique_settings "$new_tunnel" "$new_subnet" "$PROFILE" || return 1

  exists && was_created=1
  if [[ $old_tunnel != "$new_tunnel" || $old_role != "$new_role" || $old_iran != "$new_iran" ||
        $old_foreign != "$new_foreign" || $old_key != "$new_key" || $old_subnet != "$new_subnet" ]]; then
    needs_recreate=1
  fi

  if (( was_created == 1 && needs_recreate == 1 )); then
    warn "Changing tunnel identity requires removing the current interface."
    confirm_default_yes "Remove $old_tunnel to apply these tunnel changes?" || { warn "Edit cancelled."; return 0; }
    remove_rules
    ip link set dev "$old_tunnel" down 2>/dev/null || true
    ip tunnel del "$old_tunnel" || { err "Could not remove the old interface; profile unchanged."; return 1; }
  else
    # Remove rules using the old values before changing the saved profile.
    remove_rules
  fi

  TUNNEL=$new_tunnel
  ROLE=$new_role
  IRAN_IP=$new_iran
  FOREIGN_IP=$new_foreign
  KEY=$new_key
  PORT_MODE=$new_port_mode
  SERVICE_PORT=$new_port
  SUBNET_ID=$new_subnet
  PROTOCOL=$new_protocol
  save_profile || { err "Could not save profile."; return 1; }

  if (( was_created == 1 && needs_recreate == 0 )); then
    apply_rules || { err "Profile saved, but forwarding rules could not be refreshed."; return 1; }
  fi
  ok "Profile updated. Forwarding: $PROTOCOL/$(port_label)."
  (( was_created == 1 && needs_recreate == 1 )) && msg "Create the tunnel interface again, then Start it on both servers."
}

create_tunnel() {
  with_active || return 1
  if exists; then warn "Interface $TUNNEL already exists. Use Start or Restart."; return 0; fi
  msg "Creating $TUNNEL..."
  ip tunnel add "$TUNNEL" mode gre local "$(local_ip)" remote "$(remote_ip)" key "$(gre_key_number)" ttl 255 || {
    err "GRE creation failed. Check protocol 47 reachability, endpoints and GRE Key."
    return 1
  }
  ip addr add "$(local_tunnel_cidr)" dev "$TUNNEL" || {
    ip tunnel del "$TUNNEL" 2>/dev/null || true
    err "Could not assign the tunnel address; the new interface was rolled back."
    return 1
  }
  ok "Interface created and left DOWN. Choose Start to bring it up."
}

start_tunnel() {
  with_active || return 1
  exists || { err "Interface $TUNNEL is not created on this server. In Manage, choose Create tunnel interface first."; return 1; }
  ip link set dev "$TUNNEL" up || { err "Could not bring the interface up."; return 1; }
  apply_rules || { err "Interface is UP, but forwarding rules could not be applied."; return 1; }
  if [[ $ROLE == 1 ]]; then
    ok "$TUNNEL is UP. $PROTOCOL/$(port_label) is forwarded to $(remote_tunnel_ip)."
  else
    ok "$TUNNEL is UP. Port forwarding is configured on the Iran server."
  fi
}

stop_tunnel() {
  with_active || return 1
  remove_rules
  if exists; then
    ip link set dev "$TUNNEL" down || { err "Could not stop the interface."; return 1; }
    ok "$TUNNEL is DOWN. The interface and profile are preserved."
  else
    warn "Interface does not exist. Managed profile rules were cleaned if present."
  fi
}

restart_tunnel() {
  with_active || return 1
  exists || { err "Interface $TUNNEL is not created on this server. In Manage, choose Create tunnel interface first."; return 1; }
  ip link set dev "$TUNNEL" down || { err "Could not bring the interface down."; return 1; }
  remove_rules
  ip link set dev "$TUNNEL" up || { err "Interface is DOWN. Start it again to retry."; return 1; }
  apply_rules || { err "Interface is UP, but forwarding rules could not be applied."; return 1; }
  ok "$TUNNEL restarted. $PROTOCOL/$(port_label) forwarding is active."
}

show_status() {
  with_active || return 1
  local role
  role=$(role_label "$ROLE")
  section_title "TUNNEL STATUS: $PROFILE"
  printf '  %bProfile%b      %b%s%b\n' "$C_CYAN" "$C_RESET" "$C_WHITE" "$PROFILE" "$C_RESET"
  printf '  %bRole%b         %b%s%b\n' "$C_CYAN" "$C_RESET" "$C_WHITE" "$role" "$C_RESET"
  printf '  %bInterface%b    %b%s%b  ' "$C_CYAN" "$C_RESET" "$C_WHITE" "$TUNNEL" "$C_RESET"
  case $(link_state) in
    UP) printf '%bUP%b\n' "$C_GREEN" "$C_RESET" ;;
    DOWN) printf '%bDOWN%b\n' "$C_YELLOW" "$C_RESET" ;;
    *) printf '%b%s%b\n' "$C_DIM" "$(link_state)" "$C_RESET" ;;
  esac
  printf '  %bGRE Key%b      %b%s%b\n' "$C_CYAN" "$C_RESET" "$C_WHITE" "$KEY" "$C_RESET"
  printf '  %bPeer%b         %b%s%b\n' "$C_CYAN" "$C_RESET" "$C_WHITE" "$(remote_ip)" "$C_RESET"
  printf '  %bLocal tunnel%b %b%s%b\n' "$C_CYAN" "$C_RESET" "$C_WHITE" "$(local_tunnel_cidr)" "$C_RESET"
  printf '  %bRemote%b       %b%s%b\n' "$C_CYAN" "$C_RESET" "$C_WHITE" "$(remote_tunnel_ip)" "$C_RESET"
  printf '  %bForwarding%b   %b%s/%s%b\n' "$C_CYAN" "$C_RESET" "$C_WHITE" "$PROTOCOL" "$(port_label)" "$C_RESET"
  if exists; then
    printf '\n'
    ip -d tunnel show "$TUNNEL"
    ip -brief -4 addr show dev "$TUNNEL"
  else
    warn "Create the interface before starting it."
  fi
  if [[ $ROLE == 1 ]]; then
    printf '\n%b%bManaged firewall rules%b\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    iptables-save | grep -F -- "$TAG-$PROFILE" || printf '  No managed rules found.\n'
  else
    printf '\nPort-forwarding rules are applied on the Iran server only.\n'
  fi
}

delete_tunnel() {
  with_active || return 1
  if ! exists; then
    remove_rules
    warn "No interface exists. Managed rules were cleaned if present."
    return 0
  fi
  confirm_default_yes "Delete interface $TUNNEL? The profile will remain." || { warn "Cancelled."; return 0; }
  remove_rules
  ip link set dev "$TUNNEL" down 2>/dev/null || true
  ip tunnel del "$TUNNEL" || { err "Could not delete $TUNNEL."; return 1; }
  ok "Tunnel interface deleted. Profile retained."
}

delete_profile() {
  with_active || return 1
  exists && { err "Delete the tunnel interface first."; return 1; }
  confirm_default_yes "Delete profile $PROFILE?" || { warn "Cancelled."; return 0; }
  remove_rules
  rm -f "$PROFILES/$PROFILE.conf" "$ACTIVE"
  ok "Profile deleted."
}

create_tunnel_flow() {
  draw_header
  section_title "CREATE TUNNEL"
  create_profile || return 1
  create_tunnel || return 1
}

uninstall_manager() {
  local file name
  printf '\n%bUNINSTALL%b\n' "$C_BOLD" "$C_RESET"
  warn "This removes every tunnel interface and profile created by this manager."
  confirm_default_yes "Uninstall the manager and remove all managed tunnel interfaces and profiles?" || { warn "Uninstall cancelled."; return 0; }
  for file in "$PROFILES"/*.conf; do
    [[ -f $file ]] || continue
    name=${file##*/}; name=${name%.conf}
    if load_profile "$name"; then
      remove_rules || true
      if exists; then
        ip link set dev "$TUNNEL" down 2>/dev/null || true
        ip tunnel del "$TUNNEL" 2>/dev/null || warn "Could not remove interface $TUNNEL."
      fi
    fi
  done
  rm -rf -- "$BASE" || { err "Could not remove manager data."; return 1; }
  ok "Manager data, profiles and managed tunnel interfaces removed."
  exit 0
}

manage_menu() {
  local choice file name index=0 selected
  local -a profile_names=()
  draw_header
  section_title "SELECT A TUNNEL"
  for file in "$PROFILES"/*.conf; do
    [[ -f $file ]] || continue
    name=${file##*/}; name=${name%.conf}
    if load_profile "$name"; then
      profile_names+=("$name")
      ((index+=1))
      printf '  %b[%02d]%b  %b%-16s%b  %b%-8s%b  %b%s/%s%b  %bSUBNET %s%b\n' \
        "$C_BOLD$C_BLUE" "$index" "$C_RESET" "$C_WHITE" "$PROFILE" "$C_RESET" \
        "$C_CYAN" "$(role_label "$ROLE")" "$C_RESET" "$C_WHITE" "$PROTOCOL" "$(port_label)" "$C_RESET" "$C_DIM" "$SUBNET_ID" "$C_RESET"
    fi
  done
  (( index > 0 )) || { warn "No tunnel profiles yet. Choose Create tunnel first."; return 0; }
  printf '  %b[00]%b  %bBack%b\n\n' "$C_BOLD$C_BLUE" "$C_RESET" "$C_WHITE" "$C_RESET"
  prompt_read choice "Enter tunnel number: " || return 1
  [[ $choice == 0 || $choice == 00 ]] && return 0
  [[ $choice =~ ^[0-9]{1,2}$ ]] || { err "Enter a number from the list."; return 1; }
  index=$((10#$choice))
  (( index >= 1 && index <= ${#profile_names[@]} )) || { err "That tunnel number is not in the list."; return 1; }
  selected=${profile_names[index-1]}
  load_profile "$selected" || { err "Tunnel/profile is invalid."; return 1; }
  printf '%s' "$selected" > "$ACTIVE"

  while true; do
    draw_header
    section_title "MANAGE TUNNEL: $PROFILE"
    menu_item 1 "Edit settings"
    menu_item 2 "Create tunnel interface"
    menu_item 3 "Start tunnel"
    menu_item 4 "Stop tunnel"
    menu_item 5 "Restart tunnel"
    menu_item 6 "Status and connection details"
    menu_item 7 "Delete tunnel interface"
    menu_item 8 "Delete profile"
    printf '\n  %b[0]%b  %bBack to main menu%b\n\n' "$C_BOLD$C_BLUE" "$C_RESET" "$C_WHITE" "$C_RESET"
    prompt_read choice "Choose an option: " || return 0
    case $choice in
      1) edit_profile ;;
      2) create_tunnel ;;
      3) start_tunnel ;;
      4) stop_tunnel ;;
      5) restart_tunnel ;;
      6) show_status ;;
      7) delete_tunnel ;;
      8) delete_profile; break ;;
      0) break ;;
      *) warn "Choose one of the numbered actions." ;;
    esac
    pause_screen
  done
}

while true; do
  draw_header
  section_title "MAIN MENU"
  menu_item 1 "Create a tunnel profile"
  menu_item 2 "Manage existing tunnels"
  menu_item 3 "Uninstall manager and managed tunnels"
  menu_item 0 "Exit"
  printf '\n'
  prompt_read choice "Choose an option: " || goodbye
  case $choice in
    1) create_tunnel_flow ;;
    2) manage_menu ;;
    3) uninstall_manager ;;
    0) goodbye ;;
    *) warn "Choose one of the numbered actions." ;;
  esac
  pause_screen
done
