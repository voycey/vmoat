#!/usr/bin/env bash
# commands.sh -- subcommand implementations. Sourced by bin/vmoat.

# ---------------------------------------------------------------------------
# provision: ensure the VM exists, is running, and has the toolchain + seeds.
# ---------------------------------------------------------------------------
# Memory budget, checked before a VM is created OR started. A vz VM's host cost
# is the high-water mark of guest RAM it has touched, which only ratchets up
# (page cache fills it) and is never handed back while it runs -- so over time a
# running VM costs ~its full VM_MEMORY. Budget on configured sizes, and point at
# what to park. Warns, never refuses: macOS compresses/swaps cold guest pages, so
# overcommit is slow rather than fatal. (On WSL2 host RAM is the .wslconfig cap.)
preflight_ram() {
  local total_gb; total_gb=$(host_ram_gb)
  [ "${total_gb:-0}" -gt 0 ] || return 0
  local mem="${VM_MEMORY%.*}"
  if [ "$mem" -ge "$total_gb" ]; then
    warn "VM_MEMORY=${VM_MEMORY}G is >= host RAM (${total_gb}G). The VM will likely thrash."
  fi
  local reserve="${HOST_RESERVE:-}"
  [ -n "$reserve" ] || { reserve=$(( total_gb / 8 )); [ "$reserve" -ge 8 ] || reserve=8; }
  local committed=0 n=0 name status cpus gb
  while read -r name status cpus gb; do
    # An existing VM boots at the size it was created with (`colima start -p`
    # ignores --memory), not the current VM_MEMORY.
    [ "$name" = "$VM" ] && mem="$gb"
    [ "$status" = "running" ] && [ "$name" != "$VM" ] || continue
    committed=$(( committed + gb )); n=$(( n + 1 ))
  done <<EOF
$(colima_profiles)
EOF
  local budget=$(( total_gb - reserve ))
  log "Host RAM ${total_gb}G (${reserve}G reserved); ${n} other VM(s) running, ${committed}G committed; $VM wants ${mem}G."
  if [ $(( committed + mem )) -gt "$budget" ]; then
    warn "Starting $VM puts VM memory at $(( committed + mem ))G, over the ${budget}G budget. It will run, but macOS will compress/swap and everything slows."
    warn "Park a VM you're not using to free its RAM: 'vmoat ls' shows what's running and the host RAM each holds; 'vmoat down <vm>' stops it (disk + images kept, 'vmoat up' resumes)."
  fi
}

# A profile keeps the backend it was created with. Flag one that isn't on the
# platform's preferred backend (e.g. a qemu VM left over on a Mac).
check_backend() {
  [ -n "$VM_TYPE" ] || return 0
  local have; have=$(vm_backend "$VM")
  # krunkit means it was created with --reclaim / MEMORY_RECLAIM=1, which sticks.
  if [ -n "$have" ] && [ "$have" != "$VM_TYPE" ] && [ "$have" != "krunkit" ]; then
    warn "$VM was created with vmType '$have', not '$VM_TYPE'; Colima keeps a VM's backend. To move it: vmoat destroy && vmoat up (rebuilds images)."
  fi
}

bootstrap_toolchain() {
  # rsync always: Colima's image lacks it, and Lima's boot script then runs
  # apt-get on a VM's first boot, before DNS works -- ~3.5 min of timeouts for
  # every VM cloned from a base image. Installed once, that path is skipped.
  local apt_pkgs="rsync $PROVISION_APT"
  if [ -n "$apt_pkgs" ]; then
    # Detect missing via dpkg (package installed?), NOT `command -v`: packages
    # like ca-certificates / libfoo provide no same-named binary, so command -v
    # would re-trigger apt every run. apt-get update is slow, so only run if a
    # package is genuinely absent, and install only the missing ones.
    local missing="" t
    for t in $apt_pkgs; do
      in_vm_q "dpkg -s $t" || missing="$missing $t"
    done
    if [ -n "$missing" ]; then
      log "Installing apt packages in VM:$missing"
      colima ssh -p "$VM" -- sudo sh -c "DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq$missing" \
        || die "apt install failed in VM."
    fi
  fi
  if [ -n "$PROVISION_SCRIPT" ]; then
    log "Running provision script in VM."
    colima ssh -p "$VM" -- bash -lc "$PROVISION_SCRIPT" || die "PROVISION_SCRIPT failed in VM."
  fi
}

seed_files() {
  [ -n "$PROVISION_SEED" ] || return 0
  local f
  for f in $PROVISION_SEED; do
    if [ -e "$REPO_ROOT/$f" ]; then continue; fi
    if [ -e "$MAIN_WORKTREE/$f" ]; then
      mkdir -p "$(dirname "$REPO_ROOT/$f")"
      cp -a "$MAIN_WORKTREE/$f" "$REPO_ROOT/$f"
      log "Seeded '$f' from main checkout ($MAIN_WORKTREE)."
    else
      warn "Seed file '$f' missing from this worktree AND main checkout -- you must provide it or '$CMD_UP' may fail."
    fi
  done
}

# systemd 255 (Ubuntu 24.04, the Colima image) has a logind bug: if
# `loginctl terminate-user` races a login that is still opening -- Lima's boot
# script runs one -- logind busy-loops forever. That pins a core at 100%, makes
# every new login wait out pam_systemd's 120 s timeout, and keeps the load up so
# `reap` never sees the VM idle. Lima can't prevent it on this systemd, so a
# timer in the guest restarts logind whenever it's spinning.
install_logind_watchdog() {
  colima ssh -p "$VM" -- sudo sh -c "cat > /usr/local/sbin/vmoat-logind-watchdog <<'SCRIPT'
#!/bin/sh
# Installed by vmoat: restart systemd-logind if it's busy-looping (systemd 255 bug).
pid=\$(pidof systemd-logind) || exit 0
ticks() { awk '{print \$14 + \$15}' /proc/\$pid/stat 2>/dev/null || echo 0; }
a=\$(ticks); sleep 5; b=\$(ticks)
hz=\$(getconf CLK_TCK)
# 4+ s of CPU in 5 s: it's spinning, not working.
if [ \$((b - a)) -ge \$((4 * hz)) ]; then
  logger -t vmoat \"systemd-logind spinning (\$((b - a)) ticks in 5 s); restarting it\"
  # Spinning, it never handles SIGTERM, so a restart would wait out the 90 s
  # stop timeout. Kill it; Restart=always brings it straight back.
  systemctl kill --signal=SIGKILL systemd-logind
fi
SCRIPT
chmod 755 /usr/local/sbin/vmoat-logind-watchdog
cat > /etc/systemd/system/vmoat-logind-watchdog.service <<'UNIT'
[Unit]
Description=vmoat: restart systemd-logind if it is busy-looping

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vmoat-logind-watchdog
UNIT
cat > /etc/systemd/system/vmoat-logind-watchdog.timer <<'UNIT'
[Unit]
Description=vmoat: check systemd-logind every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload && systemctl enable --now vmoat-logind-watchdog.timer" >/dev/null 2>&1 \
    || warn "Could not install the systemd-logind watchdog in $VM."
}

# Only memory the guest has FREED goes back to macOS, and Linux keeps spare RAM
# full of page cache. A systemd timer drops that cache every RECLAIM_INTERVAL
# minutes so it is freed, and returned. (Rewritten each provision: cheap, and it
# picks up a changed interval.)
install_reclaim_timer() {
  case "$RECLAIM_INTERVAL" in ''|*[!0-9]*|0) die "RECLAIM_INTERVAL must be whole minutes > 0, got '$RECLAIM_INTERVAL'." ;; esac
  colima ssh -p "$VM" -- sudo sh -c "cat > /etc/systemd/system/vmoat-reclaim.service <<'UNIT'
[Unit]
Description=vmoat: drop page cache so freed memory returns to the host

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sync; echo 1 > /proc/sys/vm/drop_caches'
UNIT
cat > /etc/systemd/system/vmoat-reclaim.timer <<UNIT
[Unit]
Description=vmoat: drop page cache every ${RECLAIM_INTERVAL} min

[Timer]
OnBootSec=${RECLAIM_INTERVAL}min
OnUnitActiveSec=${RECLAIM_INTERVAL}min

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload && systemctl enable --now vmoat-reclaim.timer && systemctl restart vmoat-reclaim.timer" >/dev/null 2>&1 \
    || die "Could not install the page-cache reclaim timer in $VM."
  log "Memory reclaim on: freed guest RAM returns to macOS; page cache dropped every ${RECLAIM_INTERVAL} min."
}

cmd_provision() {
  need colima "Install Colima (macOS/Linux: 'brew install colima docker'; WSL2: install in the distro + enable nested virtualization). See the README."
  assert_mounted
  # `colima start` flips the user's ACTIVE docker context to colima-<vm>. Capture
  # the prior context and restore it at the end, so a user's plain `docker` keeps
  # hitting their main daemon. The tool itself always targets the VM via `-p`.
  local _prev_ctx; _prev_ctx=$(docker context show 2>/dev/null || true)
  # A krunkit VM (new with MEMORY_RECLAIM=1, or created that way earlier) must
  # start on the reclaiming krunkit, not whatever krunkit is on PATH.
  local _reclaim="" base=""
  if [ "$VM_TYPE" = "krunkit" ] || [ "$(vm_backend "$VM")" = "krunkit" ]; then
    _reclaim=1; use_reclaim_krunkit
  fi
  if vm_running; then
    ok "VM $VM already running."
  elif vm_exists; then
    check_backend
    preflight_ram
    log "Starting existing VM $VM..."
    colima start -p "$VM" || die "colima start failed for $VM."
  elif base=$(base_for_new_vm); then
    preflight_ram
    log "Cloning VM $VM from base image '${base#vmoat-base-}' (copy-on-write; 'vmoat up --fresh' to build from scratch)..."
    clone_vm "$base" "$VM"
    VMOAT_CREATED=clone
    colima start -p "$VM" --cpu "$VM_CPU" --memory "$VM_MEMORY" || die "colima start failed for $VM."
  else
    preflight_ram
    log "Creating VM $VM (platform: $WTVM_PLATFORM)..."
    VMOAT_CREATED=fresh
    # Only pass --vm-type/--mount-type when set (macOS pins vz+virtiofs; on
    # Linux/WSL2 they're empty so Colima picks its native qemu/KVM backend).
    # The ${arr[@]+...} guard keeps an empty array safe under `set -u` (bash 3.2).
    local -a _backend=()
    [ -n "$VM_TYPE" ] && _backend+=(--vm-type "$VM_TYPE")
    [ -n "$MOUNT_TYPE" ] && _backend+=(--mount-type "$MOUNT_TYPE")
    colima start -p "$VM" \
      ${_backend[@]+"${_backend[@]}"} \
      --cpu "$VM_CPU" --memory "$VM_MEMORY" --disk "$VM_DISK" \
      --mount "$VM_MOUNT:w" \
      || die "colima start failed for $VM. (Check 'colima start --help' for flag support on your version.)"
  fi
  # Remember which worktree owns this VM, for `vmoat ls`.
  runtime_dir
  printf '%s\n' "$REPO_ROOT" > "$RUNDIR/worktree"
  install_logind_watchdog
  [ -n "$_reclaim" ] && install_reclaim_timer
  bootstrap_toolchain
  seed_files
  if [ -n "$_prev_ctx" ] && [ "$_prev_ctx" != "colima-$VM" ]; then
    docker context use "$_prev_ctx" >/dev/null 2>&1 \
      && log "Restored active docker context to '$_prev_ctx' (VM stays reachable via 'vmoat')." || true
  fi
  ok "VM $VM provisioned."
}

# ---------------------------------------------------------------------------
# up: provision + run CMD_UP + wait for health.
# ---------------------------------------------------------------------------
health_wait() {
  [ -n "$HEALTH_URL" ] || return 0
  local start now last_beat deadline
  start=$(date +%s); last_beat=$start; deadline=$(( start + HEALTH_TIMEOUT ))
  log "Waiting for health inside VM: $HEALTH_URL (timeout ${HEALTH_TIMEOUT}s)..."
  while :; do
    if in_vm_q "curl -fsS -o /dev/null --max-time 5 $(_q "$HEALTH_URL")"; then
      ok "Healthy after $(( $(date +%s) - start ))s: $HEALTH_URL"
      return 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      die "Health check timed out after ${HEALTH_TIMEOUT}s. Inspect: vmoat ssh -- docker ps"
    fi
    if [ $(( now - last_beat )) -ge 60 ]; then
      log "... still waiting for health ($(( deadline - now ))s left). $(date '+%H:%M:%S')"
      last_beat=$now
    fi
    sleep 5
  done
}

print_reach() {
  ok "Stack is up in VM $VM (worktree: $REPO_ROOT)."
  log "  Tunnel to host:     vmoat tunnel"
  log "  Run tests in VM:    vmoat test --quick"
  log "  Shell into VM:      vmoat ssh"
  log "  Stop (keep disk):   vmoat down      Destroy: vmoat destroy"
}

# Best-effort default for how to start a project when CMD_UP isn't configured.
_autodetect_cmd_up() {
  local r="$REPO_ROOT"
  if [ -f "$r/compose.yaml" ] || [ -f "$r/compose.yml" ] \
     || [ -f "$r/docker-compose.yml" ] || [ -f "$r/docker-compose.yaml" ]; then
    printf 'docker compose up -d'
  elif [ -f "$r/Makefile" ] && grep -qE '^up:' "$r/Makefile"; then
    printf 'make up'
  elif [ -f "$r/package.json" ] && grep -qE '"dev"[[:space:]]*:' "$r/package.json"; then
    printf 'npm run dev'
  fi
}

cmd_up() {
  if [ -z "$CMD_UP" ]; then
    CMD_UP="$(_autodetect_cmd_up)"
    [ -n "$CMD_UP" ] && log "No CMD_UP configured -- auto-detected: $CMD_UP"
  fi
  [ -n "$CMD_UP" ] || die "Can't tell how to start this project. Add a compose file / Makefile 'up' target, set CMD_UP in vmoat.conf, or run 'vmoat init'."
  cmd_provision
  log "Running up command in VM $VM: $CMD_UP"
  in_vm "$CMD_UP" || die "'$CMD_UP' failed in VM $VM."
  health_wait
  # First from-scratch build of this repo on this backend: keep it as the base
  # image so every later worktree clones it instead of building. Saving stops
  # and restarts the VM, so bring the stack back up after (images are built).
  if [ "${VMOAT_CREATED:-}" = fresh ] && [ "$AUTO_BASE" = 1 ] && [ "$WTVM_PLATFORM" = "darwin" ] \
     && ! vm_exists_named "$(base_profile "" "$(vm_backend "$VM")")"; then
    log "First build of this repo: saving it as the base image so new worktrees start in seconds (AUTO_BASE=0 to skip)."
    _base_save
    [ "$(vm_backend "$VM")" = "krunkit" ] && use_reclaim_krunkit
    in_vm "$CMD_UP" || die "'$CMD_UP' failed in VM $VM after saving the base image."
    health_wait
  fi
  print_reach
}

# ---------------------------------------------------------------------------
# test: run CMD_TEST [args] inside the VM (localhost defaults resolve to the stack).
# ---------------------------------------------------------------------------
cmd_test() {
  [ -n "$CMD_TEST" ] || die "CMD_TEST is not set in vmoat.conf."
  vm_running || die "VM $VM is not running. Run 'vmoat up' first."
  local extra=""
  [ "$#" -gt 0 ] && extra=" $*"
  log "Running tests in VM $VM: ${CMD_TEST}${extra}"
  in_vm "${CMD_TEST}${extra}"
}

# ---------------------------------------------------------------------------
# tunnel / untunnel: surface an in-VM port to the host for browser/Chrome.
# ---------------------------------------------------------------------------
# Published host-side ports of the running containers in the VM (deduped).
# Lets `tunnel` work with NO config: forward whatever the stack actually exposes.
_discover_ports() {
  colima ssh -p "$VM" -- docker ps --format '{{.Ports}}' 2>/dev/null \
    | tr ',' '\n' | grep -oE ':[0-9]+->' | grep -oE '[0-9]+' | sort -un
}

# Open ONE forward: a free host port -> VM 127.0.0.1:<gport>. Prints the URL.
_tunnel_one() {
  local gport="$1" halias="$2"
  local pidf="$RUNDIR/tunnel-$gport.pid" portf="$RUNDIR/tunnel-$gport.port"
  if [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    ok "Already open: http://localhost:$(cat "$portf")  ->  VM 127.0.0.1:$gport"
    printf 'http://localhost:%s\n' "$(cat "$portf")"
    return 0
  fi
  local hport; hport=$(_free_port)
  # ControlMaster=no + ControlPath=none: give the tunnel its OWN connection.
  # colima's ssh-config enables mux; attaching to its persistent master makes
  # the client exit immediately (breaking the pidfile) while the forward leaks.
  nohup ssh -F "$RUNDIR/ssh-config" -NT \
    -o ControlMaster=no -o ControlPath=none \
    -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
    -L "127.0.0.1:$hport:127.0.0.1:$gport" "$halias" >/dev/null 2>&1 &
  echo $! > "$pidf"; echo "$hport" > "$portf"
  sleep 1
  if ! kill -0 "$(cat "$pidf")" 2>/dev/null; then
    rm -f "$pidf" "$portf"; die "Tunnel to VM port $gport failed to establish."
  fi
  ok "Tunnel open: http://localhost:$hport  ->  VM $VM 127.0.0.1:$gport  (close: vmoat untunnel)"
  printf 'http://localhost:%s\n' "$hport"
}

#   vmoat tunnel            -> EXPOSE_PORTS if set, else auto-discovered published ports
#   vmoat tunnel <port> ... -> a forward for each given guest port
cmd_tunnel() {
  vm_running || die "VM $VM is not running."
  runtime_dir
  colima ssh-config -p "$VM" > "$RUNDIR/ssh-config" 2>/dev/null \
    || die "Could not read ssh-config for $VM."
  local halias; halias=$(awk '/^Host /{print $2; exit}' "$RUNDIR/ssh-config")
  [ -n "$halias" ] || die "Could not parse ssh host alias for $VM."

  local ports p
  if [ "$#" -gt 0 ]; then
    ports="$*"
  else
    # EXPOSE_PORTS may be a bash array (preferred) or a space-separated string;
    # [*] joins either to a string, set-u-safe for an empty/unset array.
    ports="${EXPOSE_PORTS[*]+${EXPOSE_PORTS[*]}}"
    # Nothing configured? Auto-discover the published ports of running containers.
    if [ -z "$ports" ]; then
      ports="$(_discover_ports | tr '\n' ' ')"
      [ -n "$ports" ] && log "Auto-discovered published ports: $ports"
    fi
  fi
  [ -n "$ports" ] || die "No published ports found to tunnel. Expose ports in your stack, set EXPOSE_PORTS, or pass one: vmoat tunnel <port>."
  for p in $ports; do
    case "$p" in ''|*[!0-9]*) die "Not a port number: '$p'." ;; esac
    _tunnel_one "$p" "$halias"
  done
}

# ---------------------------------------------------------------------------
# init: scaffold a vmoat.conf (OPTIONAL -- vmoat works without one).
# ---------------------------------------------------------------------------
cmd_init() {
  local cfg="$REPO_ROOT/vmoat.conf"
  [ -e "$cfg" ] && die "vmoat.conf already exists at $REPO_ROOT -- edit it directly."
  local up; up="$(_autodetect_cmd_up)"
  {
    echo "# vmoat.conf -- generated by 'vmoat init'. Only CMD_UP is required;"
    echo "# everything else is optional (ports are auto-discovered if EXPOSE_PORTS is unset)."
    echo
    if [ -n "$up" ]; then
      echo "CMD_UP=\"$up\""
    else
      echo '# CMD_UP="docker compose up -d"     # REQUIRED: how to start your stack'
    fi
    echo '# CMD_TEST="docker compose exec -T app pytest"'
    echo '# HEALTH_URL="http://127.0.0.1:8080/health"'
    echo '# EXPOSE_PORTS=(8080)                 # omit to auto-discover published ports'
    echo '# VM_CPU=4; VM_MEMORY=8; VM_DISK=60'
  } > "$cfg"
  ok "Wrote $cfg${up:+ (auto-detected CMD_UP=\"$up\")}. Review, then run: vmoat up"
}

cmd_untunnel() {
  runtime_dir
  local pf any=0
  for pf in "$RUNDIR"/tunnel-*.pid; do
    [ -e "$pf" ] || continue
    kill "$(cat "$pf")" 2>/dev/null || true
    rm -f "$pf" "${pf%.pid}.port"
    any=1
  done
  [ "$any" = 1 ] && ok "Closed tunnels for $VM." || log "No open tunnels for $VM."
}

# ---------------------------------------------------------------------------
# status / ssh / down / destroy / name
# ---------------------------------------------------------------------------
cmd_status() {
  if ! vm_exists; then log "VM $VM does not exist."; return 0; fi
  colima list 2>/dev/null | awk 'NR==1 || $1=="'"$VM"'"'
  if vm_running; then
    log "Containers in VM $VM:"
    colima ssh -p "$VM" -- docker ps --format '  {{.Names}}  {{.Status}}' 2>/dev/null || true
    if [ -n "$HEALTH_URL" ]; then
      if in_vm_q "curl -fsS -o /dev/null --max-time 5 $(_q "$HEALTH_URL")"; then ok "Health OK ($HEALTH_URL)"; else warn "Health not ready ($HEALTH_URL)"; fi
    fi
    runtime_dir
    local pf
    for pf in "$RUNDIR"/tunnel-*.port; do
      [ -e "$pf" ] || continue
      log "Tunnel: http://localhost:$(cat "$pf")"
    done
  fi
}

# ---------------------------------------------------------------------------
# base images: copy-on-write clones of a provisioned VM. A new worktree's VM is
# cloned from its repo's base in well under a second and boots with the
# toolchain and built images already there, instead of a 10-20 min first up.
# ---------------------------------------------------------------------------
# clone_vm SRC DST: clone a STOPPED Colima VM. On APFS the copies share blocks
# until they diverge, so a clone costs no disk up front.
clone_vm() {
  local src="$1" dst="$2" home="${COLIMA_HOME:-$HOME/.colima}"
  local lima="$home/_lima"
  [ "$WTVM_PLATFORM" = "darwin" ] || die "Base images need macOS (APFS copy-on-write clones)."
  need limactl "It comes with Colima (Lima 2.x provides 'limactl clone')."
  vm_running_named "$src" && die "Can't clone $src while it's running."
  # Root disk + Lima instance files (limactl clone uses clonefile on APFS).
  LIMA_HOME="$lima" limactl clone "colima-$src" "colima-$dst" >/dev/null 2>&1 \
    || die "limactl clone colima-$src colima-$dst failed."
  # The Docker data disk (images, build cache, volumes) is a separate file.
  mkdir -p "$lima/_disks/colima-$dst" "$home/$dst"
  cp -c "$lima/_disks/colima-$src/datadisk" "$lima/_disks/colima-$dst/datadisk" \
    || die "Copy-on-write clone of the data disk failed (is ~/.colima on APFS?)."
  cp "$home/$src/colima.yaml" "$home/$dst/colima.yaml"
  # Without its state file Colima thinks the data disk is new and formats it.
  cp "$home/_store/colima-$src.json" "$home/_store/colima-$dst.json" 2>/dev/null || true
  # Colima rewrites the disk entries on start but keeps the hostname scripts, and
  # writes the source's hostname into colima.yaml; blank it so it's re-derived.
  sed -i '' -E "s/colima-$src([^a-z0-9-]|\$)/colima-$dst\1/g" "$lima/colima-$dst/lima.yaml"
  local y
  for y in "$home/$dst/colima.yaml" "$lima/colima-$dst/colima.yaml"; do
    [ -f "$y" ] && sed -i '' -E 's/^hostname: .*/hostname: ""/' "$y"
  done
}

vm_running_named() {
  [ "$(colima list 2>/dev/null | awk -v p="$1" 'NR>1 && $1==p {print tolower($2)}')" = "running" ]
}
vm_exists_named() {
  colima list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$1"
}

# Print the base profile to clone a new VM from; fail if there's none to use.
base_for_new_vm() {
  [ "$WTVM_PLATFORM" = "darwin" ] && [ -z "${VMOAT_FRESH:-}" ] || return 1
  local bp; bp=$(base_profile "" "$VM_TYPE")
  vm_exists_named "$bp" || return 1
  printf '%s' "$bp"
}

#   vmoat base save [name]  snapshot this worktree's VM as base image <name>
#   vmoat base ls           list base images
#   vmoat base rm <name>    delete a base image (clones made from it are unaffected)
cmd_base() {
  local sub="${1:-ls}"; [ "$#" -gt 0 ] && shift
  case "$sub" in
    save) _base_save "$@" ;;
    ls)
      colima list 2>/dev/null | awk '
        NR == 1 { printf "%-28s %-8s %5s %8s %8s\n", "BASE IMAGE", "STATUS", "CPUS", "MEMORY", "DISK"; next }
        $1 ~ /^vmoat-base-/ { sub(/^vmoat-base-/, "", $1); printf "%-28s %-8s %5s %8s %8s\n", $1, tolower($2), $4, $5, $6 }' ;;
    rm)
      [ -n "${1:-}" ] || die "Usage: vmoat base rm <name>"
      local bp; bp=$(base_profile "$1")
      vm_exists_named "$bp" || die "No base image '$1' (see 'vmoat base ls')."
      colima delete -p "$bp" --data -f >/dev/null 2>&1 || die "colima delete $bp failed."
      ( VM="$bp"; _kill_ssh_mux )
      ok "Deleted base image '$1'. VMs cloned from it keep working." ;;
    *) die "Unknown: vmoat base $sub (save [name] | ls | rm <name>)." ;;
  esac
}

_base_save() {
  vm_exists || die "This worktree has no VM to save. Run 'vmoat up' first."
  # Each `colima start` below switches the active docker context; put it back.
  local prev_ctx; prev_ctx=$(docker context show 2>/dev/null || true)
  local name; name=$(base_name "${1:-}")
  local bp; bp=$(base_profile "$name" "$(vm_backend "$VM")")
  local was_running=""; vm_running && was_running=1
  if [ -n "$was_running" ]; then
    log "Stopping $VM to snapshot it (it restarts afterwards)..."
    cmd_untunnel >/dev/null 2>&1 || true
    colima stop -p "$VM" >/dev/null 2>&1 || die "colima stop failed for $VM."
  fi
  if vm_exists_named "$bp"; then
    log "Replacing base image '$name'."
    colima delete -p "$bp" --data -f >/dev/null 2>&1 || die "Could not delete the old base image."
  fi
  log "Cloning $VM -> base image '${bp#vmoat-base-}'..."
  clone_vm "$VM" "$bp"
  # Tidy the base, not the source: drop this worktree's containers (and, unless
  # BASE_KEEP_VOLUMES=1, its volumes) so clones start clean but keep the images
  # and build cache, and make sure rsync is baked in (see bootstrap_toolchain).
  [ "$(vm_backend "$bp")" = "krunkit" ] && use_reclaim_krunkit
  log "Preparing the base image (one boot)..."
  colima start -p "$bp" >/dev/null 2>&1 || die "Could not boot base image $bp to prepare it."
  colima ssh -p "$bp" -- sudo sh -c '
    docker ps -aq | xargs -r docker rm -f >/dev/null
    [ "'"${BASE_KEEP_VOLUMES:-}"'" = 1 ] || docker volume prune -af >/dev/null
    command -v rsync >/dev/null || { DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync; } >/dev/null 2>&1
    true' || warn "Couldn't fully tidy the base image."
  colima stop -p "$bp" >/dev/null 2>&1 || die "colima stop failed for $bp."
  ( VM="$bp"; _kill_ssh_mux )
  docker context rm "colima-$bp" >/dev/null 2>&1 || true
  if [ -n "$was_running" ]; then
    colima start -p "$VM" >/dev/null 2>&1 || warn "Could not restart $VM; run 'vmoat up'."
  fi
  [ -n "$prev_ctx" ] && docker context use "$prev_ctx" >/dev/null 2>&1 || true
  ok "Saved base image '${bp#vmoat-base-}'. New worktrees of this repo now start from it: vmoat up"
}

# ls: every vmoat VM on this host (any worktree), with the host RAM each running
# one actually holds -- the number to look at before starting another.
cmd_ls() {
  local total_gb; total_gb=$(host_ram_gb)
  local rows name status cpus gb host wt held=0 committed=0
  rows=$(colima_profiles | awk -v p="$VM_PREFIX" 'index($1, p) == 1')
  if [ -z "$rows" ]; then log "No vmoat VMs (prefix '$VM_PREFIX')."; return 0; fi
  _vz_pids >/dev/null   # populate the pid->profile cache once, in this shell
  local w; w=$(printf '%s\n' "$rows" | awk '{ if (length($1) > m) m = length($1) } END { print m }')
  printf "%-${w}s %-8s %4s %7s %9s  %s\n" "VM" "STATUS" "CPU" "MEMORY" "HOST RAM" "WORKTREE"
  while read -r name status cpus gb; do
    host="-"
    if [ "$status" = "running" ]; then
      host=$(vm_host_footprint "$name")
      committed=$(( committed + gb ))
      [ "$host" != "-" ] && held=$(awk -v a="$held" -v b="$host" 'BEGIN{printf "%.1f", a + b}')
    fi
    wt=$(cat "${XDG_RUNTIME_DIR:-$HOME/.cache/vmoat}/$name/worktree" 2>/dev/null || printf -- '-')
    printf "%-${w}s %-8s %4s %6sG %9s  %s\n" "$name" "$status" "$cpus" "$gb" "${host}${host:+G}" "$wt" \
      | sed 's/ -G / -  /'
  done <<EOF
$rows
EOF
  log "Running VMs hold ${held}G of host RAM now (${committed}G configured, which they grow toward) of ${total_gb}G total."
}

# reap: stop vmoat VMs nobody is using, so their RAM goes back to the host. On
# vz stopping is the only way to get it back (README: "Memory on macOS"). A
# running VM is stopped only when ALL of these hold, so in-use work never is:
#   - no vmoat command has touched it for --idle minutes (status/test/ssh/... all count);
#   - no `vmoat ssh/test/up` session is attached to it right now;
#   - none of its tunnels has an open connection (a browser or agent is on it);
#   - its guest 5-min load average is under REAP_LOAD (a build or ingest is running).
# A VM with no last-used record gets one now and is kept: the clock starts here.
cmd_reap() {
  local idle="$REAP_IDLE_MIN" dry="" install=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --idle)          idle="${2:-}"; shift 2 || shift ;;
      --idle=*)        idle="${1#*=}"; shift ;;
      -n|--dry-run)    dry=1; shift ;;
      --install-agent) install=1; shift ;;
      *) die "Unknown reap option: '$1' (try: --idle MIN, --dry-run, --install-agent)." ;;
    esac
  done
  case "$idle" in ''|*[!0-9]*) die "--idle needs whole minutes, got '$idle'." ;; esac
  if [ -n "$install" ]; then _reap_install_agent "$idle"; return 0; fi

  local base="${XDG_RUNTIME_DIR:-$HOME/.cache/vmoat}" now names name dir last age why pf port load
  now=$(date +%s)
  names=$(colima_profiles | awk -v p="$VM_PREFIX" 'index($1, p) == 1 && $2 == "running" {print $1}')
  [ -n "$names" ] || { log "No running vmoat VMs."; return 0; }
  for name in $names; do
    dir="$base/$name"; mkdir -p "$dir"
    if [ ! -s "$dir/last-used" ]; then
      printf '%s\n' "$now" > "$dir/last-used"
      log "keep  $name: first time seen; its idle clock starts now."
      continue
    fi
    last=$(cat "$dir/last-used"); age=$(( (now - last) / 60 ))
    why=""
    if [ "$age" -lt "$idle" ]; then
      why="used ${age}m ago (idle after ${idle}m)"
    elif pgrep -f "colima ssh -p $name( |\$)" >/dev/null 2>&1; then
      why="a vmoat ssh/test/up session is attached"
    else
      for pf in "$dir"/tunnel-*.port; do
        [ -e "$pf" ] || continue
        port=$(cat "$pf")
        if lsof -nP -iTCP:"$port" -sTCP:ESTABLISHED >/dev/null 2>&1; then
          why="tunnel localhost:$port has an open connection"; break
        fi
      done
    fi
    if [ -z "$why" ]; then
      load=$(colima ssh -p "$name" -- cat /proc/loadavg </dev/null 2>/dev/null | awk '{print $2}' || true)
      if [ -z "$load" ]; then
        why="couldn't read its load average"
      elif awk -v l="$load" -v m="$REAP_LOAD" 'BEGIN{exit !(l >= m)}'; then
        why="busy: 5-min load $load (>= $REAP_LOAD)"
      fi
    fi
    if [ -n "$why" ]; then
      log "keep  $name: $why."
    elif [ -n "$dry" ]; then
      log "would stop $name: idle ${age}m, no sessions or tunnel connections, load $load."
    else
      log "stop  $name: idle ${age}m, no sessions or tunnel connections, load $load."
      # Subshell: one VM failing to stop mustn't abort the rest (cmd_down dies on error).
      ( VM="$name"; cmd_down ) || warn "Could not stop $name."
    fi
  done
}

# Write a launchd agent that runs `vmoat reap` every 10 minutes. Loading it is
# left to the user: it's a standing job on their Mac.
_reap_install_agent() {
  local idle="$1"
  [ "$WTVM_PLATFORM" = "darwin" ] || {
    log "Not macOS: run it from cron instead, e.g.  */10 * * * * $(command -v vmoat || printf '%s' "$SELF_DIR/vmoat") reap --idle $idle"
    return 0
  }
  # Prefer the PATH entry (stable across brew upgrades) over our resolved Cellar path.
  local bin; bin=$(command -v vmoat 2>/dev/null || printf '%s/vmoat' "$SELF_DIR")
  # An older vmoat on PATH has no `reap`; launchd would just log errors forever.
  if ! "$bin" help 2>&1 | grep -q '^  reap'; then
    warn "$bin is an older vmoat without 'reap'; pointing the agent at $SELF_DIR/vmoat instead. Re-run --install-agent after upgrading."
    bin="$SELF_DIR/vmoat"
  fi
  local label="dev.vmoat.reap" plist="$HOME/Library/LaunchAgents/dev.vmoat.reap.plist"
  local logf="${XDG_RUNTIME_DIR:-$HOME/.cache/vmoat}/reap.log"
  mkdir -p "$(dirname "$plist")" "$(dirname "$logf")"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$bin</string><string>reap</string><string>--idle</string><string>$idle</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>StartInterval</key><integer>600</integer>
  <key>StandardOutPath</key><string>$logf</string>
  <key>StandardErrorPath</key><string>$logf</string>
</dict>
</plist>
PLIST
  ok "Wrote $plist (reap every 10 min, idle after ${idle}m; log: $logf)."
  log "Turn it on:   launchctl bootstrap gui/$(id -u) $plist"
  log "Turn it off:  launchctl bootout gui/$(id -u)/$label"
}

cmd_ssh() {
  vm_running || die "VM $VM is not running."
  if [ "$#" -eq 0 ]; then
    colima ssh -p "$VM"
  else
    in_vm "$*"
  fi
}

# Lima's ssh ControlMaster for a VM outlives `colima stop/delete`; reap it.
_kill_ssh_mux() {
  pkill -f "ssh: .*/colima-$VM/ssh.sock \\[mux\\]" 2>/dev/null || true
}

cmd_down() {
  vm_exists || { log "VM $VM does not exist."; return 0; }
  cmd_untunnel
  colima stop -p "$VM" || die "colima stop failed."
  _kill_ssh_mux
  ok "Stopped $VM: its host RAM is free again (disk, images and volumes kept). 'vmoat up' to resume, 'destroy' to remove."
}

cmd_destroy() {
  vm_exists || { log "VM $VM does not exist."; return 0; }
  # Announce the exact target: `destroy` acts on the CURRENT worktree's VM, so a
  # bare invocation from the wrong directory would otherwise silently nuke it.
  log "Destroying VM $VM (worktree: $REPO_ROOT)..."
  cmd_untunnel
  # --data: also delete the Docker data disk, which colima otherwise leaves behind.
  colima delete -p "$VM" --data ${WTVM_FORCE:+-f} || die "colima delete failed."
  _kill_ssh_mux
  ok "Destroyed $VM."
}
