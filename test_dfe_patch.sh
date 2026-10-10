#!/system/bin/sh
# Self-check for the DFE fstab/rc patch helpers.
#
# Guards the inverted-return regression: dfe_patch_fstab/_init_rc used to
# return 1 on SUCCESS, so `if dfe_patch_fstab ...` never fired and patched
# fstabs were silently dropped instead of being repacked into the boot ramdisk.
#
# Run as root on-device:  sh test_dfe_patch.sh
# (Only needs /data/local/tmp writable; does not touch any real partition.)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_TMP="${TMPDIR:-/data/local/tmp}"
D="$(mktemp -d "${BASE_TMP}/dfe_test.XXXXXX")" || exit 1
trap 'rm -rf "${D}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Function-only copy: drop the final `main "$@"` and redirect the hardcoded
# /data/local/tmp scratch paths into our private dir so no real state is touched.
sed -e '$d' -e "s#/data/local/tmp/#${D}/#g" "${SCRIPT_DIR}/dfe_ro2rw.sh" > "${D}/lib.sh"
. "${D}/lib.sh"
LOGFILE="${D}/test.log"; : > "${LOGFILE}"

# Patches when flags are present, and actually removes them.
printf 'userdata /data ext4 ro,forceencrypt=/dev/block/by-name/metadata\n' > "${D}/f.enc"
dfe_patch_fstab "${D}/f.enc" || fail "expected rc=0 when patching"
if grep -q 'forceencrypt' "${D}/f.enc"; then fail "forceencrypt not removed"; fi

# Returns non-zero when there is nothing to patch or the file is missing.
printf 'userdata /data ext4 ro,nosuid\n' > "${D}/f.plain"
if dfe_patch_fstab "${D}/f.plain"; then fail "expected rc=1 when nothing to patch"; fi
if dfe_patch_fstab "${D}/does-not-exist"; then fail "expected rc=1 for missing file"; fi

# The boot-image repack gate must fire on a real patch.
repacked=0
printf 'userdata /data ext4 ro,forceencrypt=x\n' > "${D}/f.boot"
if dfe_patch_fstab "${D}/f.boot"; then repacked=1; fi
[ "${repacked}" = "1" ] || fail "boot-image repack gate never fires"

# rc marker removal works and reports success.
printf 'on init\n    # DFE-NEO marker\n' > "${D}/init.rc"
dfe_patch_init_rc "${D}/init.rc" || fail "expected rc=0 when removing DFE-NEO marker"
if grep -q 'DFE-NEO' "${D}/init.rc"; then fail "DFE-NEO marker not removed"; fi

echo "PASS: DFE patch helpers"
