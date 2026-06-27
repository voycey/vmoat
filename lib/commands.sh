#!/usr/bin/env bash
# commands.sh -- subcommand implementations. Sourced by bin/vmoat.

# ---------------------------------------------------------------------------
# provision: ensure the VM exists, is running, and has the toolchain + seeds.
# ---------------------------------------------------------------------------
preflight_ram() {
  # Portable host-RAM probe. On WSL2 this reads the RAM allotted to the WSL VM
  # (set in .wslconfig) -- which is exactly the budget Colima has to work with.
  local total_gb=0
  if [ "$WTVM_PLATFORM" = "darwin" ]; then
    total_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
  elif [ -r /proc/meminfo ]; then
    local kb; kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
    [ -n "$kb" ] && total_gb=$(( kb / 1048576 ))
  fi
  [ "$total_gb" -gt 0 ] || return 0
  if [ "$VM_MEMORY" -ge "$total_gb" ]; then
    warn "VM_MEMORY=${VM_MEMORY}G is >= host RAM (${total_gb}G). The VM will likely thrash."
  fi
  log "Host RAM ${total_gb}G; allocating ${VM_MEMORY}G + ${VM_CPU} cpu + ${VM_DISK}G disk to $VM."
}

bootstrap_toolchain() {
  if [ -n "$PROVISION_APT" ]; then
    # Detect missing via dpkg (package installed?), NOT `command -v`: packages
    # like ca-certificates / libfoo provide no same-named binary, so command -v
    # would re-trigger apt every run. apt-get update is slow, so only run if a
    # package is genuinely absent, and install only the missing ones.
    local missing="" t
    for t in $PROVISION_APT; do
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

cmd_provision() {
  need colima "Install Colima (macOS/Linux: 'brew install colima docker'; WSL2: install in the distro + enable nested virtualization). See the README."
  assert_mounted
  # `colima start` flips the user's ACTIVE docker context to colima-<vm>. Capture
  # the prior context and restore it at the end, so a user's plain `docker` keeps
  # hitting their main daemon. The tool itself always targets the VM via `-p`.
  local _prev_ctx; _prev_ctx=$(docker context show 2>/dev/null || true)
  if vm_running; then
    ok "VM $VM already running."
  elif vm_exists; then
    log "Starting existing VM $VM..."
    colima start -p "$VM" || die "colima start failed for $VM."
  else
    preflight_ram
    log "Creating VM $VM (platform: $WTVM_PLATFORM)..."
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

cmd_ssh() {
  vm_running || die "VM $VM is not running."
  if [ "$#" -eq 0 ]; then
    colima ssh -p "$VM"
  else
    in_vm "$*"
  fi
}

cmd_down() {
  vm_exists || { log "VM $VM does not exist."; return 0; }
  cmd_untunnel
  colima stop -p "$VM" || die "colima stop failed."
  ok "Stopped $VM (disk kept). 'vmoat up' to resume, 'destroy' to remove."
}

cmd_destroy() {
  vm_exists || { log "VM $VM does not exist."; return 0; }
  # Announce the exact target: `destroy` acts on the CURRENT worktree's VM, so a
  # bare invocation from the wrong directory would otherwise silently nuke it.
  log "Destroying VM $VM (worktree: $REPO_ROOT)..."
  cmd_untunnel
  colima delete -p "$VM" ${WTVM_FORCE:+-f} || die "colima delete failed."
  ok "Destroyed $VM."
}
