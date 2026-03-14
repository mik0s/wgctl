#!/usr/bin/env bash

set -euo pipefail
umask 027

resolve_script_path() {
  local source_path="${BASH_SOURCE[0]}"
  while [[ -L "$source_path" ]]; do
    local source_dir
    source_dir="$(cd "$(dirname "$source_path")" && pwd)"
    source_path="$(readlink "$source_path")"
    [[ "$source_path" != /* ]] && source_path="$source_dir/$source_path"
  done
  cd "$(dirname "$source_path")" && pwd
}

SCRIPT_DIR="$(resolve_script_path)"
DEFAULT_CONFIG_PATH="${WGCTL_CONFIG:-$SCRIPT_DIR/config/wgctl.conf}"

CONFIG_PATH=""
CONFIG_DIR=""
SERVER_ID=""
WG_ENDPOINT=""
WG_SERVER_PUBLIC_KEY=""
WG_ALLOWED_IPS=""
WG_ADDRESS_POOL=""
WG_CLIENT_PREFIX=""
WG_POOL_FIRST_HOST=""
WG_POOL_LAST_HOST=""
WG_DNS=""
WG_PERSISTENT_KEEPALIVE=""
WG_INTERFACE=""
WG_SERVER_CONFIG=""
WG_APPLY_CHANGES=""
WG_PERSIST_CHANGES=""
MAIL_FROM=""
SMTP_SENDMAIL=""
PROFILE_STORE=""
ARTIFACT_STORE=""

usage() {
  cat <<'EOF'
Usage:
  wgctl.sh [global-options] create NAME --email EMAIL [--address CIDR] [--public-key KEY] [--private-key KEY] [--dry-run]
  wgctl.sh [global-options] list
  wgctl.sh [global-options] show NAME
  wgctl.sh [global-options] delete NAME
  wgctl.sh [global-options] activity [NAME]
  wgctl.sh [global-options] server list
  wgctl.sh [global-options] server show [ID]
  wgctl.sh [global-options] server status [ID]
  wgctl.sh [global-options] server up [ID]
  wgctl.sh [global-options] server down [ID]
  wgctl.sh [global-options] server reload [ID]
  wgctl.sh [global-options] server peers [ID]
  wgctl.sh [global-options] server logs [ID]
  wgctl.sh [global-options] servers

Global options:
  --config PATH   Path to config file.
  --server ID     Server id from SERVERS or DEFAULT_SERVER fallback.

Commands:
  create    Create a WireGuard client profile, save artifacts, and send email.
  list      Show issued profiles for the selected server.
  show      Print metadata and the generated config for a profile.
  delete    Delete stored metadata and generated artifacts for a profile.
  activity  Show peer activity from `wg show <interface> dump`.
  server    Manage configured WireGuard server interfaces.
  servers   Show configured server ids.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

load_config() {
  CONFIG_PATH="${1:-$DEFAULT_CONFIG_PATH}"
  [[ -f "$CONFIG_PATH" ]] || die "Config not found: $CONFIG_PATH"
  CONFIG_PATH="$(cd "$(dirname "$CONFIG_PATH")" && pwd)/$(basename "$CONFIG_PATH")"
  CONFIG_DIR="$(dirname "$CONFIG_PATH")"

  # shellcheck disable=SC1090
  source "$CONFIG_PATH"
  MAIL_FROM="${MAIL_FROM:-wgctl@localhost}"
  SMTP_SENDMAIL="${SMTP_SENDMAIL:-/usr/sbin/sendmail}"
}

resolve_path() {
  local path_value="$1"
  if [[ -z "$path_value" || "$path_value" == /* ]]; then
    printf '%s' "$path_value"
  else
    printf '%s/%s' "$CONFIG_DIR" "$path_value"
  fi
}

uppercase() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

sanitize_id() {
  printf '%s' "$1" | tr -c '[:alnum:]' '_'
}

require_config_value() {
  local key="$1"
  local value="${!key:-}"
  [[ -n "$value" ]] || die "Missing config value: $key"
  printf '%s' "$value"
}

config_or_default() {
  local key="$1"
  local fallback="$2"
  local value="${!key:-}"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

load_server_config() {
  local server_id="$1"
  [[ -n "${SERVERS:-}" ]] || die "SERVERS is required in config"

  local found="false"
  local candidate
  for candidate in $SERVERS; do
    if [[ "$candidate" == "$server_id" ]]; then
      found="true"
      break
    fi
  done
  [[ "$found" == "true" ]] || die "Unknown server: $server_id"

  local prefix
  prefix="SERVER_$(uppercase "$(sanitize_id "$server_id")")"

  SERVER_ID="$server_id"
  WG_ENDPOINT="$(require_config_value "${prefix}_ENDPOINT")"
  WG_SERVER_PUBLIC_KEY="$(require_config_value "${prefix}_SERVER_PUBLIC_KEY")"
  WG_ALLOWED_IPS="$(require_config_value "${prefix}_ALLOWED_IPS")"
  WG_INTERFACE="$(require_config_value "${prefix}_INTERFACE")"
  WG_ADDRESS_POOL="$(config_or_default "${prefix}_ADDRESS_POOL" "")"
  WG_CLIENT_PREFIX="$(config_or_default "${prefix}_CLIENT_PREFIX" "32")"
  WG_POOL_FIRST_HOST="$(config_or_default "${prefix}_POOL_FIRST_HOST" "2")"
  WG_POOL_LAST_HOST="$(config_or_default "${prefix}_POOL_LAST_HOST" "")"
  WG_DNS="$(config_or_default "${prefix}_DNS" "1.1.1.1, 1.0.0.1")"
  WG_PERSISTENT_KEEPALIVE="$(config_or_default "${prefix}_PERSISTENT_KEEPALIVE" "25")"
  WG_SERVER_CONFIG="$(resolve_path "$(config_or_default "${prefix}_SERVER_CONFIG" "")")"
  WG_APPLY_CHANGES="$(config_or_default "${prefix}_APPLY_CHANGES" "true")"
  WG_PERSIST_CHANGES="$(config_or_default "${prefix}_PERSIST_CHANGES" "false")"
  MAIL_FROM="$(config_or_default "${prefix}_MAIL_FROM" "$MAIL_FROM")"
  SMTP_SENDMAIL="$(config_or_default "${prefix}_SMTP_SENDMAIL" "$SMTP_SENDMAIL")"
  PROFILE_STORE="$(resolve_path "$(config_or_default "${prefix}_PROFILE_STORE" "$SCRIPT_DIR/data/$server_id/profiles")")"
  ARTIFACT_STORE="$(resolve_path "$(config_or_default "${prefix}_ARTIFACT_STORE" "$SCRIPT_DIR/data/$server_id/artifacts")")"

  mkdir -p "$PROFILE_STORE" "$ARTIFACT_STORE"
  chmod 0750 "$PROFILE_STORE" "$ARTIFACT_STORE"
}

resolve_server_id() {
  local requested_server_id="$1"
  if [[ -n "$requested_server_id" ]]; then
    printf '%s' "$requested_server_id"
    return 0
  fi

  if [[ -n "${DEFAULT_SERVER:-}" ]]; then
    printf '%s' "$DEFAULT_SERVER"
    return 0
  fi

  die "--server is required when DEFAULT_SERVER is not set"
}

resolve_server_selector() {
  local requested_server_id="$1"
  local positional_server_id="${2:-}"

  if [[ -n "$requested_server_id" && -n "$positional_server_id" && "$requested_server_id" != "$positional_server_id" ]]; then
    die "Conflicting server ids: --server=$requested_server_id and argument=$positional_server_id"
  fi

  if [[ -n "$positional_server_id" ]]; then
    printf '%s' "$positional_server_id"
  else
    resolve_server_id "$requested_server_id"
  fi
}

quote_value() {
  printf "%q" "$1"
}

profile_path() {
  local name="$1"
  echo "$PROFILE_STORE/$name.env"
}

config_artifact_path() {
  local name="$1"
  echo "$ARTIFACT_STORE/$name.conf"
}

qr_artifact_path() {
  local name="$1"
  echo "$ARTIFACT_STORE/$name.png"
}

peer_artifact_path() {
  local name="$1"
  echo "$ARTIFACT_STORE/$name.peer.conf"
}

write_profile_metadata() {
  local path="$1"
  shift

  : > "$path"
  while (($#)); do
    local key="$1"
    local value="$2"
    printf "%s=%s\n" "$key" "$(quote_value "$value")" >> "$path"
    shift 2
  done
  chmod 0640 "$path"
}

load_profile() {
  local name="$1"
  local path
  path="$(profile_path "$name")"
  [[ -f "$path" ]] || die "Profile not found: $name"

  # shellcheck disable=SC1090
  source "$path"
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

ip_to_int() {
  local ip="$1"
  local a b c d
  IFS=. read -r a b c d <<< "$ip"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || die "Invalid IPv4 address: $ip"
  ((a >= 0 && a <= 255 && b >= 0 && b <= 255 && c >= 0 && c <= 255 && d >= 0 && d <= 255)) || die "Invalid IPv4 address: $ip"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int_to_ip() {
  local value="$1"
  printf '%d.%d.%d.%d\n' \
    $(((value >> 24) & 255)) \
    $(((value >> 16) & 255)) \
    $(((value >> 8) & 255)) \
    $((value & 255))
}

collect_used_addresses() {
  local file address
  shopt -s nullglob
  for file in "$PROFILE_STORE"/*.env; do
    # shellcheck disable=SC1090
    source "$file"
    address="${ADDRESS%%/*}"
    [[ -n "$address" ]] && printf '%s\n' "$address"
  done
}

allocate_address() {
  [[ -n "$WG_ADDRESS_POOL" ]] || die "--address is required when ADDRESS_POOL is not configured for server $SERVER_ID"
  [[ "$WG_ADDRESS_POOL" == */* ]] || die "Invalid ADDRESS_POOL: $WG_ADDRESS_POOL"

  local network_cidr network_ip prefix
  network_cidr="$WG_ADDRESS_POOL"
  network_ip="${network_cidr%/*}"
  prefix="${network_cidr#*/}"
  [[ "$prefix" =~ ^[0-9]+$ ]] || die "Invalid ADDRESS_POOL prefix: $WG_ADDRESS_POOL"
  ((prefix >= 0 && prefix <= 32)) || die "Invalid ADDRESS_POOL prefix: $WG_ADDRESS_POOL"
  [[ "$WG_CLIENT_PREFIX" =~ ^[0-9]+$ ]] || die "Invalid CLIENT_PREFIX: $WG_CLIENT_PREFIX"
  ((WG_CLIENT_PREFIX >= prefix && WG_CLIENT_PREFIX <= 32)) || die "CLIENT_PREFIX must be between pool prefix and 32"
  [[ "$WG_POOL_FIRST_HOST" =~ ^[0-9]+$ ]] || die "Invalid POOL_FIRST_HOST: $WG_POOL_FIRST_HOST"

  local network_int host_bits mask broadcast_int last_host max_host host candidate_ip
  network_int="$(ip_to_int "$network_ip")"
  if ((prefix == 0)); then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  fi
  (( (network_int & mask) == network_int )) || die "ADDRESS_POOL must be a network address: $WG_ADDRESS_POOL"

  host_bits=$((32 - prefix))
  max_host=$(( (1 << host_bits) - 1 ))
  broadcast_int=$(( network_int + max_host ))
  if [[ -n "$WG_POOL_LAST_HOST" ]]; then
    [[ "$WG_POOL_LAST_HOST" =~ ^[0-9]+$ ]] || die "Invalid POOL_LAST_HOST: $WG_POOL_LAST_HOST"
    last_host="$WG_POOL_LAST_HOST"
  else
    if ((max_host <= 1)); then
      last_host="$max_host"
    else
      last_host=$((max_host - 1))
    fi
  fi

  ((WG_POOL_FIRST_HOST >= 0 && WG_POOL_FIRST_HOST <= max_host)) || die "POOL_FIRST_HOST is outside ADDRESS_POOL"
  ((last_host >= WG_POOL_FIRST_HOST && last_host <= max_host)) || die "POOL_LAST_HOST is outside ADDRESS_POOL"

  local used_list used_ip
  used_list="$(collect_used_addresses || true)"

  for ((host = WG_POOL_FIRST_HOST; host <= last_host; host++)); do
    candidate_ip="$(int_to_ip $((network_int + host)))"
    if [[ -n "$used_list" ]] && grep -Fxq "$candidate_ip" <<< "$used_list"; then
      continue
    fi
    if (( network_int + host == broadcast_int )) && (( prefix < 31 )); then
      continue
    fi
    printf '%s/%s\n' "$candidate_ip" "$WG_CLIENT_PREFIX"
    return 0
  done

  die "No free addresses left in pool $WG_ADDRESS_POOL for server $SERVER_ID"
}

persist_server_state() {
  if ! is_true "$WG_PERSIST_CHANGES"; then
    return 0
  fi

  [[ -n "$WG_SERVER_CONFIG" ]] || die "Persistence enabled but WG_SERVER_CONFIG is not set for server $SERVER_ID"

  local config_dir
  config_dir="$(dirname "$WG_SERVER_CONFIG")"
  [[ -d "$config_dir" ]] || die "Server config directory does not exist: $config_dir"

  wg showconf "$WG_INTERFACE" > "$WG_SERVER_CONFIG"
}

apply_peer_on_server() {
  local public_key="$1"
  local address="$2"

  if ! is_true "$WG_APPLY_CHANGES"; then
    return 0
  fi

  require_cmd wg
  wg set "$WG_INTERFACE" peer "$public_key" allowed-ips "$address"
  persist_server_state
}

remove_peer_from_server() {
  local public_key="$1"

  if ! is_true "$WG_APPLY_CHANGES"; then
    return 0
  fi

  require_cmd wg
  wg set "$WG_INTERFACE" peer "$public_key" remove
  persist_server_state
}

send_email() {
  local recipient="$1"
  local subject="$2"
  local body="$3"
  local config_file="$4"
  local qr_file="$5"

  [[ -x "$SMTP_SENDMAIL" ]] || die "sendmail binary not found or not executable: $SMTP_SENDMAIL"

  local boundary
  boundary="wgctl-$(date +%s)-$$"

  {
    printf 'From: %s\n' "$MAIL_FROM"
    printf 'To: %s\n' "$recipient"
    printf 'Subject: %s\n' "$subject"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: multipart/mixed; boundary="%s"\n' "$boundary"
    printf '\n--%s\n' "$boundary"
    printf 'Content-Type: text/plain; charset=UTF-8\n'
    printf 'Content-Transfer-Encoding: 8bit\n\n'
    printf '%s\n' "$body"
    printf '\n--%s\n' "$boundary"
    printf 'Content-Type: text/plain; name="%s"\n' "$(basename "$config_file")"
    printf 'Content-Disposition: attachment; filename="%s"\n' "$(basename "$config_file")"
    printf 'Content-Transfer-Encoding: base64\n\n'
    base64 < "$config_file"
    printf '\n--%s\n' "$boundary"
    printf 'Content-Type: image/png; name="%s"\n' "$(basename "$qr_file")"
    printf 'Content-Disposition: attachment; filename="%s"\n' "$(basename "$qr_file")"
    printf 'Content-Transfer-Encoding: base64\n\n'
    base64 < "$qr_file"
    printf '\n--%s--\n' "$boundary"
  } | "$SMTP_SENDMAIL" -t
}

create_profile() {
  require_cmd wg
  require_cmd qrencode
  require_cmd base64

  local name="${1:-}"
  local email=""
  local address=""
  local public_key=""
  local private_key=""
  local dry_run="false"

  [[ -n "$name" ]] || die "NAME is required"
  shift || true

  while (($#)); do
    case "$1" in
      --email) email="${2:-}"; shift 2 ;;
      --address) address="${2:-}"; shift 2 ;;
      --public-key) public_key="${2:-}"; shift 2 ;;
      --private-key) private_key="${2:-}"; shift 2 ;;
      --dry-run) dry_run="true"; shift ;;
      *) die "Unknown create option: $1" ;;
    esac
  done

  [[ -n "$email" ]] || die "--email is required"
  if [[ -z "$address" ]]; then
    address="$(allocate_address)"
  fi

  local metadata_file config_file qr_file peer_file
  metadata_file="$(profile_path "$name")"
  config_file="$(config_artifact_path "$name")"
  qr_file="$(qr_artifact_path "$name")"
  peer_file="$(peer_artifact_path "$name")"

  [[ ! -f "$metadata_file" ]] || die "Profile already exists: $name"

  if [[ -z "$public_key" && -z "$private_key" ]]; then
    private_key="$(wg genkey)"
    public_key="$(printf '%s' "$private_key" | wg pubkey)"
  elif [[ -n "$private_key" && -z "$public_key" ]]; then
    public_key="$(printf '%s' "$private_key" | wg pubkey)"
  elif [[ -n "$public_key" && -z "$private_key" ]]; then
    echo "Warning: public key provided without private key; generated config will omit PrivateKey." >&2
  fi

  {
    echo "[Interface]"
    if [[ -n "$private_key" ]]; then
      echo "PrivateKey = $private_key"
    fi
    echo "Address = $address"
    echo "DNS = $WG_DNS"
    echo
    echo "[Peer]"
    echo "PublicKey = $WG_SERVER_PUBLIC_KEY"
    echo "AllowedIPs = $WG_ALLOWED_IPS"
    echo "Endpoint = $WG_ENDPOINT"
    echo "PersistentKeepalive = $WG_PERSISTENT_KEEPALIVE"
  } > "$config_file"
  chmod 0640 "$config_file"

  {
    echo "[Peer]"
    echo "PublicKey = $public_key"
    echo "AllowedIPs = $address"
  } > "$peer_file"
  chmod 0640 "$peer_file"

  qrencode -o "$qr_file" < "$config_file"
  chmod 0640 "$qr_file"

  local created_at
  created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  write_profile_metadata "$metadata_file" \
    NAME "$name" \
    EMAIL "$email" \
    ADDRESS "$address" \
    PUBLIC_KEY "$public_key" \
    PRIVATE_KEY "$private_key" \
    CREATED_AT "$created_at" \
    CONFIG_FILE "$config_file" \
    QR_FILE "$qr_file" \
    PEER_FILE "$peer_file"

  if [[ "$dry_run" == "false" ]]; then
    apply_peer_on_server "$public_key" "$address"
  fi

  if [[ "$dry_run" == "false" ]]; then
    send_email \
      "$email" \
      "WireGuard profile: $name" \
      "Attached are the WireGuard config and QR code for profile '$name'." \
      "$config_file" \
      "$qr_file"
  fi

  echo "Profile created: $name"
  echo "Server: $SERVER_ID ($WG_INTERFACE)"
  if [[ "$dry_run" == "true" ]]; then
    echo "Peer applied on server: no (--dry-run)"
  elif is_true "$WG_APPLY_CHANGES"; then
    echo "Peer applied on server: yes"
  else
    echo "Peer applied on server: no"
  fi
  echo "Config: $config_file"
  echo "QR: $qr_file"
  echo "Server peer snippet: $peer_file"
  if [[ "$dry_run" == "true" ]]; then
    echo "Email skipped (--dry-run)"
  else
    echo "Email sent to: $email"
  fi
}

list_profiles() {
  local file
  printf 'Server: %s (%s)\n' "$SERVER_ID" "$WG_INTERFACE"
  printf '%-24s %-28s %-18s %-20s\n' "NAME" "EMAIL" "ADDRESS" "CREATED_AT"
  shopt -s nullglob
  for file in "$PROFILE_STORE"/*.env; do
    # shellcheck disable=SC1090
    source "$file"
    printf '%-24s %-28s %-18s %-20s\n' "$NAME" "$EMAIL" "$ADDRESS" "$CREATED_AT"
  done
}

show_profile() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "NAME is required"
  shift || true
  (($# == 0)) || die "Unknown show option: $1"

  load_profile "$name"
  cat <<EOF
Server: $SERVER_ID ($WG_INTERFACE)
Name: $NAME
Email: $EMAIL
Address: $ADDRESS
Created: $CREATED_AT
Public key: $PUBLIC_KEY
Private key stored: $([[ -n "${PRIVATE_KEY:-}" ]] && echo yes || echo no)
Config file: $CONFIG_FILE
QR file: $QR_FILE
Server peer snippet: $PEER_FILE

$(cat "$CONFIG_FILE")
EOF
}

delete_profile() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "NAME is required"
  shift || true
  (($# == 0)) || die "Unknown delete option: $1"

  load_profile "$name"
  remove_peer_from_server "$PUBLIC_KEY"
  rm -f "$(profile_path "$name")" "$CONFIG_FILE" "$QR_FILE" "$PEER_FILE"
  echo "Deleted profile: $name from server $SERVER_ID"
}

format_handshake() {
  local latest="$1"
  if [[ "$latest" == "0" ]]; then
    echo "never"
  else
    date -u -d "@$latest" +"%Y-%m-%dT%H:%M:%SZ"
  fi
}

print_activity_row() {
  local name="$1"
  local public_key="$2"
  local endpoint="$3"
  local allowed_ips="$4"
  local latest_handshake="$5"
  local rx="$6"
  local tx="$7"

  printf '%-24s %-24s %-21s %-16s %-12s %-12s\n' \
    "$name" \
    "$(format_handshake "$latest_handshake")" \
    "${endpoint:--}" \
    "${allowed_ips:--}" \
    "$rx" \
    "$tx"
}

activity_profiles() {
  require_cmd wg

  local name_filter="${1:-}"
  shift || true
  (($# == 0)) || die "Unknown activity option: $1"
  if [[ -n "$name_filter" && "$name_filter" == --* ]]; then
    die "Unknown activity option: $name_filter"
  fi

  local dump_file
  dump_file="$(mktemp)"
  wg show "$WG_INTERFACE" dump > "$dump_file"

  declare -A peer_name_map
  local file
  shopt -s nullglob
  for file in "$PROFILE_STORE"/*.env; do
    # shellcheck disable=SC1090
    source "$file"
    if [[ -n "$name_filter" && "$NAME" != "$name_filter" ]]; then
      continue
    fi
    peer_name_map["$PUBLIC_KEY"]="$NAME"
  done

  printf 'Server: %s (%s)\n' "$SERVER_ID" "$WG_INTERFACE"
  printf '%-24s %-24s %-21s %-16s %-12s %-12s\n' "NAME" "LAST_HANDSHAKE_UTC" "ENDPOINT" "ALLOWED_IPS" "RX_BYTES" "TX_BYTES"

  while IFS=$'\t' read -r public_key _ endpoint allowed_ips latest_handshake rx tx _; do
    local profile_name="${peer_name_map[$public_key]:-}"
    if [[ -z "$profile_name" ]]; then
      continue
    fi
    print_activity_row "$profile_name" "$public_key" "$endpoint" "$allowed_ips" "$latest_handshake" "$rx" "$tx"
  done < <(tail -n +2 "$dump_file")

  rm -f "$dump_file"
}

list_servers() {
  [[ -n "${SERVERS:-}" ]] || die "SERVERS is required in config"

  local server_id prefix interface_key profile_store_key endpoint_key interface profile_store endpoint
  printf '%-16s %-16s %-32s %s\n' "SERVER_ID" "INTERFACE" "ENDPOINT" "PROFILE_STORE"
  for server_id in $SERVERS; do
    prefix="SERVER_$(uppercase "$(sanitize_id "$server_id")")"
    interface_key="${prefix}_INTERFACE"
    profile_store_key="${prefix}_PROFILE_STORE"
    endpoint_key="${prefix}_ENDPOINT"
    interface="${!interface_key:-}"
    profile_store="${!profile_store_key:-$SCRIPT_DIR/data/$server_id/profiles}"
    endpoint="${!endpoint_key:-}"
    printf '%-16s %-16s %-32s %s\n' "$server_id" "${interface:--}" "${endpoint:--}" "$profile_store"
  done
}

systemd_unit_name() {
  printf 'wg-quick@%s.service' "$WG_INTERFACE"
}

server_is_active() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet "$(systemd_unit_name)"; then
      return 0
    fi
  fi

  if command -v wg >/dev/null 2>&1; then
    local interfaces
    interfaces="$(wg show interfaces 2>/dev/null || true)"
    [[ " $interfaces " == *" $WG_INTERFACE "* ]]
    return
  fi

  return 1
}

print_server_status_line() {
  if server_is_active; then
    printf 'active\n'
  else
    printf 'inactive\n'
  fi
}

server_show() {
  local positional_server_id="${1:-}"
  if [[ -n "$positional_server_id" ]]; then
    shift || true
  fi
  (($# == 0)) || die "Unknown server show option: $1"

  local selected_server_id
  selected_server_id="$(resolve_server_selector "${SERVER_ID:-}" "$positional_server_id")"
  load_server_config "$selected_server_id"

  cat <<EOF
Server: $SERVER_ID
Interface: $WG_INTERFACE
Status: $(print_server_status_line)
Endpoint: $WG_ENDPOINT
AllowedIPs: $WG_ALLOWED_IPS
Address pool: ${WG_ADDRESS_POOL:-disabled}
Client prefix: $WG_CLIENT_PREFIX
DNS: $WG_DNS
PersistentKeepalive: $WG_PERSISTENT_KEEPALIVE
Apply changes: $WG_APPLY_CHANGES
Persist changes: $WG_PERSIST_CHANGES
Server config: ${WG_SERVER_CONFIG:-disabled}
Profile store: $PROFILE_STORE
Artifact store: $ARTIFACT_STORE
EOF
}

server_status() {
  local positional_server_id="${1:-}"
  if [[ -n "$positional_server_id" ]]; then
    shift || true
  fi
  (($# == 0)) || die "Unknown server status option: $1"

  local selected_server_id
  selected_server_id="$(resolve_server_selector "${SERVER_ID:-}" "$positional_server_id")"
  load_server_config "$selected_server_id"

  printf 'Server: %s (%s)\n' "$SERVER_ID" "$WG_INTERFACE"
  printf 'Status: %s\n' "$(print_server_status_line)"

  if command -v systemctl >/dev/null 2>&1; then
    printf 'Systemd unit: %s\n' "$(systemd_unit_name)"
  fi
}

server_peers() {
  local positional_server_id="${1:-}"
  if [[ -n "$positional_server_id" ]]; then
    shift || true
  fi
  (($# == 0)) || die "Unknown server peers option: $1"

  local selected_server_id
  selected_server_id="$(resolve_server_selector "${SERVER_ID:-}" "$positional_server_id")"
  load_server_config "$selected_server_id"

  require_cmd wg

  printf 'Server: %s (%s)\n' "$SERVER_ID" "$WG_INTERFACE"
  printf '%-45s %-24s %-21s %-16s %-12s %-12s\n' "PUBLIC_KEY" "LAST_HANDSHAKE_UTC" "ENDPOINT" "ALLOWED_IPS" "RX_BYTES" "TX_BYTES"

  while IFS=$'\t' read -r public_key _ endpoint allowed_ips latest_handshake rx tx _; do
    printf '%-45s %-24s %-21s %-16s %-12s %-12s\n' \
      "$public_key" \
      "$(format_handshake "$latest_handshake")" \
      "${endpoint:--}" \
      "${allowed_ips:--}" \
      "$rx" \
      "$tx"
  done < <(wg show "$WG_INTERFACE" dump | tail -n +2)
}

server_logs() {
  local positional_server_id="${1:-}"
  if [[ -n "$positional_server_id" ]]; then
    shift || true
  fi
  (($# == 0)) || die "Unknown server logs option: $1"

  local selected_server_id
  selected_server_id="$(resolve_server_selector "${SERVER_ID:-}" "$positional_server_id")"
  load_server_config "$selected_server_id"

  command -v journalctl >/dev/null 2>&1 || die "journalctl is required for server logs"

  printf 'Server: %s (%s)\n' "$SERVER_ID" "$WG_INTERFACE"
  if command -v systemctl >/dev/null 2>&1; then
    journalctl -u "$(systemd_unit_name)" -n 50 --no-pager
  else
    journalctl -n 50 --no-pager
  fi
}

run_server_action() {
  local action="$1"
  local positional_server_id="${2:-}"

  local selected_server_id
  selected_server_id="$(resolve_server_selector "${SERVER_ID:-}" "$positional_server_id")"
  load_server_config "$selected_server_id"

  case "$action" in
    up)
      if command -v systemctl >/dev/null 2>&1; then
        systemctl start "$(systemd_unit_name)"
      else
        require_cmd wg-quick
        wg-quick up "$WG_INTERFACE"
      fi
      ;;
    down)
      if command -v systemctl >/dev/null 2>&1; then
        systemctl stop "$(systemd_unit_name)"
      else
        require_cmd wg-quick
        wg-quick down "$WG_INTERFACE"
      fi
      ;;
    reload)
      if command -v systemctl >/dev/null 2>&1; then
        systemctl restart "$(systemd_unit_name)"
      else
        require_cmd wg-quick
        wg-quick down "$WG_INTERFACE"
        wg-quick up "$WG_INTERFACE"
      fi
      ;;
    *)
      die "Unknown server action: $action"
      ;;
  esac

  printf 'Server: %s (%s)\n' "$SERVER_ID" "$WG_INTERFACE"
  printf 'Action: %s\n' "$action"
  printf 'Status: %s\n' "$(print_server_status_line)"
}

server_command() {
  local subcommand="${1:-}"
  [[ -n "$subcommand" ]] || die "Server subcommand is required"
  shift || true

  case "$subcommand" in
    list)
      (($# == 0)) || die "server list does not accept extra arguments"
      list_servers
      ;;
    show)
      server_show "$@"
      ;;
    status)
      server_status "$@"
      ;;
    peers)
      server_peers "$@"
      ;;
    logs)
      server_logs "$@"
      ;;
    up|down|reload)
      local positional_server_id="${1:-}"
      if [[ -n "$positional_server_id" ]]; then
        shift || true
      fi
      (($# == 0)) || die "Unknown server $subcommand option: $1"
      run_server_action "$subcommand" "$positional_server_id"
      ;;
    *)
      die "Unknown server command: $subcommand"
      ;;
  esac
}

main() {
  local config_path="$DEFAULT_CONFIG_PATH"
  local server_id=""

  while (($#)); do
    case "${1:-}" in
      --config)
        config_path="${2:-}"
        shift 2
        ;;
      --server)
        server_id="${2:-}"
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done

  local command="${1:-}"
  [[ -n "$command" ]] || {
    usage
    exit 1
  }
  shift || true

  case "$command" in
    help|-h|--help)
      usage
      exit 0
      ;;
  esac

  load_config "$config_path"

  if [[ "$command" == "servers" ]]; then
    list_servers
    exit 0
  fi

  if [[ "$command" == "server" ]]; then
    if [[ "${1:-}" == "list" ]]; then
      server_command "$@"
      exit 0
    fi

    if [[ "${1:-}" != "list" ]]; then
      if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
        server_id="$(resolve_server_selector "$server_id" "${2:-}")"
      else
        server_id="$(resolve_server_id "$server_id")"
      fi
      load_server_config "$server_id"
    fi

    server_command "$@"
    exit 0
  fi

  server_id="$(resolve_server_id "$server_id")"
  load_server_config "$server_id"

  case "$command" in
    create) create_profile "$@" ;;
    list) list_profiles "$@" ;;
    show) show_profile "$@" ;;
    delete) delete_profile "$@" ;;
    activity) activity_profiles "$@" ;;
    servers) list_servers ;;
    *) die "Unknown command: $command" ;;
  esac
}

main "$@"
