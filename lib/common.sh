#!/usr/bin/env bash
# common.sh -- shared helpers, config loading, worktree/VM resolution.
# Sourced by bin/vmoat. Targets bash 3.2 (macOS default).

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
if [ -t 2 ]; then
  _NC=$'\033[0m'; _BOLD=$'\033[1m'; _DIM=$'\033[2m'
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YLW=$'\033[1;33m'; _BLU=$'\033[0;34m'
else
  _NC=; _BOLD=; _DIM=; _RED=; _GRN=; _YLW=; _BLU=
fi

_tag() { printf '%s[vmoat]%s' "$_BLU" "$_NC"; }
log()  { printf '%s %s\n' "$(_tag)" "$*" >&2; }
ok()   { printf '%s %s%s%s\n' "$(_tag)" "$_GRN" "$*" "$_NC" >&2; }
warn() { printf '%s %s%s%s\n' "$(_tag)" "$_YLW" "$*" "$_NC" >&2; }
die()  { printf '%s %sERROR:%s %s\n' "$(_tag)" "$_RED" "$_NC" "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "Required tool '$1' not found.${2:+ $2}"
}

# bash-builtin shell quoting (bash 3.2 has printf %q)
_q() { printf '%q' "$1"; }

# platform: darwin | wsl | linux | other  (drives the VM-backend defaults below)
wtvm_platform() {
  case "$(uname -s)" in
    Darwin) printf 'darwin' ;;
    Linux)
      if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        printf 'wsl'
      else
        printf 'linux'
      fi ;;
    *) printf 'other' ;;
  esac
}
WTVM_PLATFORM="$(wtvm_platform)"

# ---------------------------------------------------------------------------
# config defaults (overridden by <repo>/vmoat.conf, which is sourced)
# ---------------------------------------------------------------------------
VM_PREFIX="wt-"
VM_CPU=4
VM_MEMORY=8
VM_DISK=60
# VM backend defaults are PLATFORM-AWARE (override either in vmoat.conf):
#   macOS      -> vz + virtiofs (Virtualization.framework, fast; macOS 13+)
#   Linux/WSL2 -> empty -> let Colima pick its native backend (qemu + KVM)
if [ "$WTVM_PLATFORM" = "darwin" ]; then
  VM_TYPE="vz"; MOUNT_TYPE="virtiofs"
else
  VM_TYPE=""; MOUNT_TYPE=""
fi
VM_MOUNT="$HOME"      # host path mounted writable into the VM (must contain the worktree)

PROVISION_APT=""      # apt packages to install in the VM
PROVISION_SCRIPT=""   # arbitrary shell run in the VM after apt (e.g. install dotenvx)
PROVISION_SEED=""     # gitignored files to copy from the main checkout into this worktree

CMD_UP=""             # command run inside the VM to bring the stack up (e.g. ./deploy.sh local)
CMD_TEST=""           # command run inside the VM to test (e.g. ./deploy.sh test)

HEALTH_URL=""         # polled INSIDE the VM after 'up' (e.g. http://127.0.0.1:38003/health)
HEALTH_TIMEOUT=1800   # seconds to wait for health (first build can be 10-20 min)

# Guest ports `tunnel` surfaces to the host. Bash array (preferred) or a
# space-separated string both work, e.g. EXPOSE_PORTS=(30001 38003).
EXPOSE_PORTS=()

load_config() {
  WTVM_CONFIG="$REPO_ROOT/vmoat.conf"
  if [ -f "$WTVM_CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$WTVM_CONFIG"
  else
    warn "No vmoat.conf at $REPO_ROOT -- using defaults. Copy vmoat.example.conf to get started."
  fi
  # Per-worktree override. vmoat.local.conf is gitignored, so it exists only in
  # THIS worktree's directory -- sourced last, it wins. Use it to give one
  # worktree different EXPOSE_PORTS / sizing / commands without touching (or
  # committing to) the shared vmoat.conf.
  if [ -f "$REPO_ROOT/vmoat.local.conf" ]; then
    # shellcheck disable=SC1090
    . "$REPO_ROOT/vmoat.local.conf"
  fi
}

# ---------------------------------------------------------------------------
# worktree / VM identity
# ---------------------------------------------------------------------------
resolve_repo() {
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "Not inside a git repository. vmoat operates on the current git worktree."

  # absolute common dir -> the main (primary) worktree, which holds gitignored
  # seed files like .env.keys that linked worktrees lack.
  local cdir
  cdir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || cdir=""
  if [ -z "$cdir" ]; then
    cdir=$(git rev-parse --git-common-dir 2>/dev/null)
    case "$cdir" in /*) ;; *) cdir="$REPO_ROOT/$cdir" ;; esac
  fi
  MAIN_WORKTREE=$(cd "$(dirname "$cdir")" && pwd)
}

# sanitised, stable VM/profile name derived from the worktree directory name.
vm_name() {
  local base
  base=$(basename "$REPO_ROOT")
  base=$(printf '%s' "$base" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9-' '-' \
    | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')
  printf '%s%s' "$VM_PREFIX" "$base"
}

# assert the worktree is reachable inside the VM via the writable mount.
assert_mounted() {
  case "$REPO_ROOT/" in
    "$VM_MOUNT"/*) : ;;
    *) die "Worktree ($REPO_ROOT) is not under VM_MOUNT ($VM_MOUNT); the VM could not see it. Set VM_MOUNT in vmoat.conf." ;;
  esac
}

# ---------------------------------------------------------------------------
# VM exec
# ---------------------------------------------------------------------------
vm_exists() {
  colima list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$VM"
}
vm_running() {
  [ "$(colima list 2>/dev/null | awk -v p="$VM" 'NR>1 && $1==p {print tolower($2)}')" = "running" ]
}

# run a command string inside the VM, cd'd to the worktree path. streams output.
in_vm() {
  colima ssh -p "$VM" -- bash -lc "cd $(_q "$REPO_ROOT") && $1"
}
# run a command in the VM, suppressing output, returning its exit status.
in_vm_q() {
  colima ssh -p "$VM" -- bash -lc "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# host ports / runtime dir
# ---------------------------------------------------------------------------
runtime_dir() {
  RUNDIR="${XDG_RUNTIME_DIR:-$HOME/.cache/vmoat}/$VM"
  mkdir -p "$RUNDIR"
}

_port_in_use() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$1" -sTCP:LISTEN -nP >/dev/null 2>&1
  else
    ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) >/dev/null 2>&1 && { exec 3>&- 3<&- 2>/dev/null; return 0; } || return 1
  fi
}
_free_port() {
  local p
  for p in $(seq 9000 9099); do
    _port_in_use "$p" || { printf '%s' "$p"; return 0; }
  done
  die "No free host port in 9000-9099 for a tunnel."
}
