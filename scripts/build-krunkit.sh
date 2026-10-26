#!/usr/bin/env bash
# Build a krunkit whose virtio-balloon gives memory the guest frees back to macOS,
# for vmoat's MEMORY_RECLAIM=1 (README: "Memory on macOS").
#
# Released libkrun only madvise()s free page reports, which on macOS releases
# nothing the guest has written to. libkrun PR #941 (unmerged as of 2026-10)
# backports the "Replace" mode that does, with a 1.x C API; this builds it, plus
# krunkit patched to call that API, into $KRUNKIT_HOME:
#   bin/krunkit  lib/libkrun.1.dylib  share/krunkit/KRUN_EFI.silent.fd
# Needs Apple Silicon, macOS 14+, git and a Rust toolchain (cargo).
#
#   usage: scripts/build-krunkit.sh
set -euo pipefail

KRUNKIT_HOME="${KRUNKIT_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/vmoat/krunkit}"
LIBKRUN_REPO="https://github.com/containers/libkrun"
LIBKRUN_REF="${LIBKRUN_REF:-8fbf86de4970d37086b6323440853b84031dd51a}"   # tested; pull/941/head for the latest
KRUNKIT_REPO="https://github.com/containers/krunkit"
KRUNKIT_REF="${KRUNKIT_REF:-9e39476d9a4f82ba91da5b0c8dc1245dbffb31cb}"   # the patch below is against this

die() { echo "build-krunkit: $*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || die "needs macOS on Apple Silicon."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || die "krunkit needs macOS 14 or newer."
command -v git >/dev/null || die "git not found."
command -v cargo >/dev/null || die "cargo not found. Install Rust (https://rustup.rs), then re-run."

work=$(mktemp -d "${TMPDIR:-/tmp}/vmoat-krunkit.XXXXXX")
trap 'rm -rf "$work"' EXIT

fetch() {  # fetch <repo> <ref> <dir>
  git init -q "$3"
  git -C "$3" fetch -q --depth 1 "$1" "$2"
  git -C "$3" checkout -q FETCH_HEAD
}

echo "build-krunkit: libkrun $LIBKRUN_REF ..."
fetch "$LIBKRUN_REPO" "$LIBKRUN_REF" "$work/libkrun"
# -p libkrun --no-default-features: EFI boot needs no guest init blob (which would
# need a Linux musl target); efi implies blk + net. No gpu (needs virglrenderer).
( cd "$work/libkrun" && cargo build --release -p libkrun --no-default-features --features efi )
grep -q krun_set_balloon_free_page_reporting_mode "$work/libkrun/include/libkrun.h" \
  || die "libkrun $LIBKRUN_REF has no krun_set_balloon_free_page_reporting_mode; set LIBKRUN_REF to a ref that does."

prefix="$work/prefix"; mkdir -p "$prefix/lib"
cp "$work/libkrun/target/release/libkrun.dylib" "$prefix/lib/libkrun.1.dylib"
install_name_tool -id @rpath/libkrun.1.dylib "$prefix/lib/libkrun.1.dylib"
ln -s libkrun.1.dylib "$prefix/lib/libkrun.dylib"

echo "build-krunkit: krunkit $KRUNKIT_REF + reclaim patch ..."
fetch "$KRUNKIT_REPO" "$KRUNKIT_REF" "$work/krunkit"
git -C "$work/krunkit" apply <<'PATCH'
diff --git a/src/context.rs b/src/context.rs
index eed1a6e..4b84ca3 100644
--- a/src/context.rs
+++ b/src/context.rs
@@ -28,12 +28,18 @@ extern "C" {
     fn krun_set_firmware(ctx_id: u32, c_firmware_path: *const c_char) -> i32;
     fn krun_set_gpu_options2(ctx_id: u32, virgl_flags: u32, shm_size: u64) -> i32;
     fn krun_set_vm_config(ctx_id: u32, num_vcpus: u8, ram_mib: u32) -> i32;
+    fn krun_set_balloon_free_page_reporting_mode(ctx_id: u32, mode: u32) -> i32;
     fn krun_set_smbios_oem_strings(ctx_id: u32, oem_strings: *const *const c_char) -> i32;
     fn krun_set_nested_virt(ctx_id: u32, enabled: bool) -> i32;
     fn krun_check_nested_virt() -> i32;
     fn krun_start_enter(ctx_id: u32) -> i32;
 }
 
+/// Free page reporting modes (libkrun PR #941). REPLACE gives memory the guest frees back to
+/// macOS; DEFAULT only madvise()s it, which releases nothing the guest has written to.
+const KRUN_FREE_PAGE_REPORTING_MODE_DEFAULT: u32 = 0;
+const KRUN_FREE_PAGE_REPORTING_MODE_REPLACE: u32 = 1;
+
 const VIRGLRENDERER_VENUS: u32 = 1 << 6;
 const VIRGLRENDERER_NO_VIRGL: u32 = 1 << 7;
 
@@ -170,14 +176,25 @@ impl TryFrom<Args> for KrunContext {
             return Err(anyhow!("unable to set krun vCPU/RAM configuration"));
         }
 
+        // Give freed guest memory back to the host unless KRUNKIT_FREE_PAGE_REPORTING=default.
+        // Read from the environment because Lima/Colima launch krunkit with fixed arguments.
+        let fpr_mode = match std::env::var("KRUNKIT_FREE_PAGE_REPORTING").as_deref() {
+            Ok("default") => KRUN_FREE_PAGE_REPORTING_MODE_DEFAULT,
+            _ => KRUN_FREE_PAGE_REPORTING_MODE_REPLACE,
+        };
+        if unsafe { krun_set_balloon_free_page_reporting_mode(id, fpr_mode) } < 0 {
+            log::warn!("unable to set the balloon's free page reporting mode to {fpr_mode}");
+        }
+
         // Temporarily enable GPU by default
         let virgl_flags = VIRGLRENDERER_VENUS | VIRGLRENDERER_NO_VIRGL;
         let sys = sysinfo::System::new_all();
         // Limit RAM + VRAM to 64 GB (36 bit IPA address limit) minus 2 GB (start address plus rounding).
         let rounded_mem = ((args.memory as u64) / 1024 + 1) * 1024;
         let vram = std::cmp::min((63488 - rounded_mem) * 1024 * 1024, sys.total_memory());
+        // Non-fatal: a libkrun built without the gpu feature (no virglrenderer) can't do it.
         if unsafe { krun_set_gpu_options2(id, virgl_flags, vram) } < 0 {
-            return Err(anyhow!("unable to set krun vCPU/RAM configuration"));
+            log::warn!("unable to enable the GPU; continuing without it");
         }
 
         // Configure each virtio device to include in the VM.
PATCH
( cd "$work/krunkit" && PREFIX="$prefix" cargo build --release )

echo "build-krunkit: installing to $KRUNKIT_HOME ..."
rm -rf "$KRUNKIT_HOME"; mkdir -p "$KRUNKIT_HOME/bin" "$KRUNKIT_HOME/lib" "$KRUNKIT_HOME/share/krunkit"
cp "$prefix/lib/libkrun.1.dylib" "$KRUNKIT_HOME/lib/"
cp "$work/krunkit/target/release/krunkit" "$KRUNKIT_HOME/bin/"
cp "$work/krunkit/edk2/KRUN_EFI.silent.fd" "$KRUNKIT_HOME/share/krunkit/"
install_name_tool -add_rpath @executable_path/../lib "$KRUNKIT_HOME/bin/krunkit"
codesign --force -s - "$KRUNKIT_HOME/lib/libkrun.1.dylib"
codesign --force -s - --entitlements "$work/krunkit/krunkit.entitlements" "$KRUNKIT_HOME/bin/krunkit"
"$KRUNKIT_HOME/bin/krunkit" --version >/dev/null || die "the built krunkit doesn't run."

# vmoat checks for this marker before creating a MEMORY_RECLAIM=1 VM.
{
  echo "libkrun=$LIBKRUN_REF@$(git -C "$work/libkrun" rev-parse HEAD)"
  echo "krunkit=$(git -C "$work/krunkit" rev-parse HEAD)+vmoat-reclaim.patch"
  echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$KRUNKIT_HOME/VMOAT_RECLAIM"
echo "build-krunkit: done. Set MEMORY_RECLAIM=1 in vmoat.conf or vmoat.local.conf; new VMs use $KRUNKIT_HOME/bin/krunkit."
