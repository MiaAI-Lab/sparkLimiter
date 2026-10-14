#!/usr/bin/env bash
# spark-limiter: cap the GPU graphics clock on DGX Sparks and keep it across reboots.
#
# Finds the DGX Sparks on your network, runs `sudo nvidia-smi -lgc 0,2200` on
# the ones you confirm, and installs a systemd service on each so the limit is
# re-applied at boot.
#
# Usage:
#   ./spark-limiter.sh                      # discover Sparks, confirm, apply
#   ./spark-limiter.sh spark1 10.0.0.12     # skip discovery, use these hosts
#   ./spark-limiter.sh -n [host ...]        # only list the Sparks found, change nothing
#   ./spark-limiter.sh -s                   # also sweep the local /24 subnet(s)
#   ./spark-limiter.sh -y                   # apply to everything found, no questions
#   ./spark-limiter.sh -l ubuntu            # ssh user for hosts found by IP/mDNS
#   ./spark-limiter.sh -c 0,1800            # custom clock range (MHz)
#   ./spark-limiter.sh --uninstall          # remove service and reset clocks
#
# Needs key-based ssh to each Spark. Hosts can be `user@host`.
# `localhost` means the machine you are on.

set -f   # no globbing: host lists come from files and the network

CLOCKS="0,2200"
SERVICE="spark-gpu-clock-limit"
UNIT_PATH="/etc/systemd/system/${SERVICE}.service"
NVSMI=/usr/bin/nvidia-smi
UNINSTALL=0; SCAN=0; YES=0; LIST_ONLY=0; SSH_USER=""
HOSTS=()

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }
log()   { printf '%s\n' "$*" >&2; }

# Host names end up as ssh targets, so they must never look like ssh options.
valid_host() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._:%@-]*$ ]]; }

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--clocks)    CLOCKS="${2:?missing value for $1}"; shift 2 ;;
    -l|--user)      SSH_USER="${2:?missing value for $1}"; shift 2 ;;
    -s|--scan)      SCAN=1; shift ;;
    -y|--yes)       YES=1; shift ;;
    -n|--list)      LIST_ONLY=1; shift ;;
    -u|--uninstall) UNINSTALL=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    --)             shift; while [ $# -gt 0 ]; do HOSTS+=("$1"); shift; done ;;
    -*)             log "Unknown option: $1"; usage >&2; exit 2 ;;
    *)              HOSTS+=("$1"); shift ;;
  esac
done

if ! [[ "$CLOCKS" =~ ^[0-9]{1,5},[0-9]{1,5}$ ]] \
   || [ "${CLOCKS%,*}" -gt "${CLOCKS#*,}" ] || [ "${CLOCKS#*,}" -gt 10000 ]; then
  log "Invalid clock range '$CLOCKS' (expected MIN,MAX in MHz with MIN<=MAX, e.g. 0,2200)"; exit 2
fi
if [ -n "$SSH_USER" ] && ! [[ "$SSH_USER" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
  log "Invalid ssh user '$SSH_USER'"; exit 2
fi

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

have_tty() { { : < /dev/tty; } 2>/dev/null; }

ask() { # prompt -> answer on stdout; fails if there is no terminal or EOF
  local a=""
  have_tty || return 1
  read -r -p "$1" a < /dev/tty || return 1
  printf '%s' "$a"
}

# --- discovery ----------------------------------------------------------------
# A host counts as a Spark if it answers over key-based ssh and reports a GB10
# GPU / DGX Spark product name. machine-id + hostname is used to drop duplicates
# (the same Spark reachable via ssh alias, IP and .local name).
#
# Probes are read-only, never send a password (BatchMode) and don't forward
# agents/ports. They deliberately do NOT verify host keys, so discovery works on
# first contact; host keys are verified normally when you apply (see README).

PROBE=$(cat <<'EOF'
info="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1)|$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null)|$(cat /etc/dgx-release 2>/dev/null)"
if printf '%s' "$info" | grep -qiE 'GB10|DGX[ _-]?Spark'; then
  echo "SPARK $(cat /etc/machine-id 2>/dev/null || echo none) $(hostname)"
fi
EOF
)

TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 20"
CANDS=()
PROBED=" "
FOUND_T=(); FOUND_N=(); SEEN_IDS=" "
DENIED=0

# add_cand NAME [raw]  -- "raw" names (IPs, mDNS) get --user prepended
add_cand() {
  local n="$1"
  valid_host "$n" || return
  case "$PROBED" in *" $n "*) return ;; esac
  PROBED="$PROBED$n "
  if [ "${2:-}" = raw ] && [ -n "$SSH_USER" ] && [[ "$n" != *@* ]]; then n="$SSH_USER@$n"; fi
  CANDS+=("$n")
}

# Private / link-local / CGNAT addresses and LAN-style names only.
is_lan_name() {
  local h="$1" a b
  case "$h" in *.local|*.lan|*.home|*.internal|*.home.arpa) return 0 ;; esac
  if [[ "$h" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
    [ "$a" -eq 10 ] && return 0
    [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0
    [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 0
    [ "$a" -eq 169 ] && [ "$b" -eq 254 ] && return 0
    [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 0
    return 1
  fi
  [[ "$h" != *.* && "$h" != *:* ]]   # single-label names
}

unicast_only() { grep -Ev '^(22[4-9]|23[0-9])\.|\.255$'; }

src_ssh_config() {
  [ -r "$HOME/.ssh/config" ] || return
  awk 'tolower($1)=="host" {for (i=2;i<=NF;i++) if ($i !~ /[*?!]/) print $i}' "$HOME/.ssh/config"
}

src_known_hosts() { # plain names on port 22 only, LAN-looking only
  [ -r "$HOME/.ssh/known_hosts" ] || return
  awk '$1 !~ /^\|/ && $1 !~ /^@/ {print $1}' "$HOME/.ssh/known_hosts" | tr ',' '\n' \
    | grep -Ev '^\[|[*?!]' | while read -r h; do is_lan_name "$h" && echo "$h"; done
}

src_mdns() { # addresses, not advertised names (those are attacker-controlled)
  command -v avahi-browse >/dev/null 2>&1 || return
  avahi-browse -rtp _ssh._tcp 2>/dev/null | awk -F';' '$1=="=" && $3=="IPv4" {print $8}' | unicast_only
}

src_neighbors() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 neigh show 2>/dev/null | awk '$NF!="FAILED" && $NF!="INCOMPLETE" {print $1}' | unicast_only
  elif command -v arp >/dev/null 2>&1; then
    arp -an 2>/dev/null | sed -n 's/.*(\([0-9][0-9.]*\)).*/\1/p' | unicast_only
  fi
}

local_ipv4() {
  if command -v ip >/dev/null 2>&1; then
    ip -o -4 addr show scope global 2>/dev/null \
      | awk '$2 !~ /^(docker|br-|veth|virbr|lo|tailscale|zt)/ {split($4,a,"/"); print a[1]}'
  else
    ifconfig 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {print $2}'
  fi
}

src_subnets() { # the /24 around each local address, minus the local addresses
  local ip base seen=" " mine i
  mine=" $(local_ipv4 | tr '\n' ' ') "
  for ip in $(local_ipv4); do
    base=${ip%.*}
    case "$seen" in *" $base "*) continue ;; esac
    seen="$seen$base "
    for i in $(seq 1 254); do
      case "$mine" in *" $base.$i "*) ;; *) echo "$base.$i" ;; esac
    done
  done
}

probe_one() { # target index
  local out rc
  out=$($TO ssh -o BatchMode=yes -o ConnectTimeout=3 -o ServerAliveInterval=2 -o ServerAliveCountMax=1 \
            -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes \
            -- "$1" "$PROBE" 2>"$TMP/$2.err" | grep -m1 '^SPARK [^ ]* [^ ]*$')
  rc=$?
  if [ -n "$out" ]; then printf '%s\t%s\n' "$1" "$out" > "$TMP/$2.res"
  elif grep -q 'Permission denied' "$TMP/$2.err" 2>/dev/null; then : > "$TMP/$2.denied"
  fi
  return 0
}

PROBE_N=0
run_probes() {
  local t running=0 start=$PROBE_N i line id name
  [ ${#CANDS[@]} -eq 0 ] && return
  for t in "${CANDS[@]}"; do
    probe_one "$t" "$PROBE_N" &
    PROBE_N=$((PROBE_N + 1)); running=$((running + 1))
    if [ $running -ge 32 ]; then wait; running=0; fi
  done
  wait
  CANDS=()
  for ((i = start; i < PROBE_N; i++)); do
    [ -e "$TMP/$i.denied" ] && DENIED=$((DENIED + 1))
    [ -r "$TMP/$i.res" ] || continue
    line=$(cat "$TMP/$i.res")
    name=$(printf '%s' "$line" | awk '{print $4}')
    id="$(printf '%s' "$line" | awk '{print $3}'):$name"
    case "$SEEN_IDS" in *" $id "*) continue ;; esac
    SEEN_IDS="$SEEN_IDS$id "
    FOUND_T+=("$(printf '%s' "$line" | cut -f1)"); FOUND_N+=("$name")
  done
}

probe_local() { # is this machine itself a Spark?
  local me id name
  me=$(bash -c "$PROBE" 2>/dev/null | grep -m1 '^SPARK [^ ]* [^ ]*$')
  [ -n "$me" ] || return
  name=$(printf '%s' "$me" | awk '{print $3}')
  id="$(printf '%s' "$me" | awk '{print $2}'):$name"
  case "$SEEN_IDS" in *" $id "*) return ;; esac
  SEEN_IDS="$SEEN_IDS$id "
  FOUND_T+=("localhost"); FOUND_N+=("$name")
}

discover() {
  log "Discovering DGX Sparks (ssh config, known_hosts, mDNS, neighbours$([ $SCAN -eq 1 ] && echo ', subnet sweep'))..."
  local h
  probe_local
  for h in $(src_ssh_config);  do add_cand "$h"; done
  for h in $(src_known_hosts); do add_cand "$h" raw; done
  for h in $(src_mdns);        do add_cand "$h" raw; done
  for h in $(src_neighbors);   do add_cand "$h" raw; done
  [ $SCAN -eq 1 ] && for h in $(src_subnets); do add_cand "$h" raw; done
  run_probes
}

scan_more() {
  local h
  log "Sweeping local subnet(s) for ssh hosts..."
  for h in $(src_subnets); do add_cand "$h" raw; done
  run_probes
}

print_found() {
  local i
  for ((i = 0; i < ${#FOUND_T[@]}; i++)); do
    printf '  %d) %-28s hostname: %s\n' $((i + 1)) "${FOUND_T[$i]}" "${FOUND_N[$i]}"
  done
}

TARGETS=()
if [ ${#HOSTS[@]} -gt 0 ]; then
  for h in "${HOSTS[@]}"; do
    valid_host "$h" || { log "Invalid host name: $h"; exit 2; }
  done
  if [ $LIST_ONLY -eq 1 ]; then
    for h in "${HOSTS[@]}"; do
      if [ "$h" = localhost ]; then probe_local; else add_cand "$h"; fi
    done
    run_probes
    if [ ${#FOUND_T[@]} -gt 0 ]; then print_found; else echo "None of the given hosts is a reachable DGX Spark."; fi
    exit 0
  fi
  TARGETS=("${HOSTS[@]}")
else
  discover
  if [ ${#FOUND_T[@]} -eq 0 ] && [ $SCAN -eq 0 ] && [ $LIST_ONLY -eq 0 ] && [ $YES -eq 0 ]; then
    log "No Sparks found."
    r=$(ask 'Sweep the local subnet for ssh hosts? [y/N] ') || r=n
    [[ "$r" == [yY]* ]] && scan_more
  fi
  [ "$DENIED" -gt 0 ] && log "($DENIED host(s) answered on ssh but refused your key and were skipped.)"

  if [ ${#FOUND_T[@]} -gt 0 ]; then
    echo "Found ${#FOUND_T[@]} DGX Spark(s):"
    print_found
  else
    echo "No Sparks discovered."
  fi
  [ "$LIST_ONLY" -eq 1 ] && exit 0

  TARGETS=("${FOUND_T[@]}")
  if [ "$YES" -eq 0 ]; then
    have_tty || { log "No terminal to confirm on; use --yes or pass hosts."; exit 2; }
    while :; do
      ans=$(ask "Apply to [Enter=all, numbers e.g. '1 3', a=add hosts, q=quit]: ") \
        || { log "No input; aborting."; exit 2; }
      case "$ans" in
        ""|y|Y) break ;;
        q|Q)    exit 0 ;;
        a|A)    extra=$(ask "Extra hosts/IPs (space or comma separated): ") || exit 2
                extra=${extra//,/ }; bad=0
                for h in $extra; do
                  if valid_host "$h"; then TARGETS+=("$h"); else log "Invalid host name: $h"; bad=1; fi
                done
                [ $bad -eq 0 ] && break ;;
        *)      sel=(); good=1
                for n in ${ans//,/ }; do
                  if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#FOUND_T[@]} ]; then
                    sel+=("${FOUND_T[$((n - 1))]}")
                  else good=0; fi
                done
                if [ $good -eq 1 ] && [ ${#sel[@]} -gt 0 ]; then TARGETS=("${sel[@]}"); break; fi
                log "Didn't understand '$ans'." ;;
      esac
    done
  fi
fi

if [ ${#TARGETS[@]} -eq 0 ]; then log "No Sparks to configure."; exit 1; fi

# --- what runs on each Spark ---------------------------------------------------
unit=$(cat <<EOF
[Unit]
Description=Limit NVIDIA GPU graphics clock (${CLOCKS} MHz)
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${NVSMI} -lgc ${CLOCKS}
ExecStop=${NVSMI} -rgc
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
)
unit_b64=$(printf '%s\n' "$unit" | base64 | tr -d '\n')

if [ "$UNINSTALL" -eq 1 ]; then
  REMOTE="{ sudo systemctl disable --now ${SERVICE}.service || true; } \
    && sudo ${NVSMI} -rgc \
    && sudo rm -f ${UNIT_PATH} \
    && sudo systemctl daemon-reload \
    && echo 'removed ${SERVICE}, clocks reset'"
else
  # Check nvidia-smi and apply the clocks first, so a host without a working
  # driver is left untouched instead of with a broken enabled unit.
  REMOTE="test -x ${NVSMI} && sudo ${NVSMI} -lgc ${CLOCKS} >/dev/null \
    && echo ${unit_b64} | base64 -d | sudo tee ${UNIT_PATH} >/dev/null \
    && sudo systemctl daemon-reload \
    && sudo systemctl enable ${SERVICE}.service \
    && sudo systemctl restart ${SERVICE}.service \
    && echo \"service: enabled=\$(systemctl is-enabled ${SERVICE}.service) active=\$(systemctl is-active ${SERVICE}.service)\" \
    && ${NVSMI} --query-gpu=name,clocks.max.gr --format=csv,noheader"
fi

# --- run on every Spark ---------------------------------------------------------
ok=(); failed=()
for host in "${TARGETS[@]}"; do
  echo
  echo "=== $host ==="
  if [ "$host" = "localhost" ] || [ "$host" = "127.0.0.1" ]; then
    bash -c "$REMOTE"
  else
    # Normal host-key checking: you are asked to verify unknown fingerprints.
    # -t lets sudo prompt for a password if the host needs one.
    ssh -t -o ConnectTimeout=10 -- "$host" "$REMOTE"
  fi
  if [ $? -eq 0 ]; then ok+=("$host"); else failed+=("$host"); fi
done

echo
echo "Done. OK: ${#ok[@]}  Failed: ${#failed[@]}"
if [ ${#failed[@]} -gt 0 ]; then echo "Failed hosts: ${failed[*]}" >&2; exit 1; fi
exit 0
