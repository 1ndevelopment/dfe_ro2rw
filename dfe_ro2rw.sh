#!/system/bin/sh

###############################################################################
# DFE + RO2RW Universal Script
# Disable Force Encryption (DFE) + Read-Only to Read-Write (RO2RW)
# For rooted Android 10+ devices with dynamic super partitions
#
# References:
#   DFE-NEO v2  - https://github.com/leegarchat/dfe-neo-v2
#   SystemRW    - https://github.com/lebigmac1/System-RW-Super-RW-v1.36-featuring-Make-RW-ro-2-rw-v1.1
#   RO2RW       - https://forum.xda-developers.com/t/4521131/
#   SuperRW     - https://forum.xda-developers.com/t/4247311/
#
# Requirements:
#   - Root access (Magisk/KernelSU)
#   - Android 10+ (dynamic partitions)
#   - arm64 device
###############################################################################

set -e
(set -o pipefail 2>/dev/null) && set -o pipefail || true

###############################################################################
# Environment & Paths
###############################################################################
export SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export ARCH=$(uname -m)

case "${ARCH}" in
    aarch64|arm64|arm64-v8a)
        export ARCH_DIR="arm64"
        ;;
    armv7l|armv8l|arm32|armeabi*|arm)
        export ARCH_DIR="arm32"
        ;;
    x86_64|amd64)
        export ARCH_DIR="x86_64"
        ;;
    i*86|x86)
        export ARCH_DIR="x86"
        ;;
    *)
        die "Unsupported architecture: ${ARCH}"
        ;;
esac

export BIN_DIR="${SCRIPT_DIR}/${ARCH_DIR}"

export TMPDIR="/data/local/tmp/superrw"
export LOGFILE="${TMPDIR}/dfe_ro2rw.log"
export BACKUPDIR="${TMPDIR}/backup"
export WORKDIR="${TMPDIR}/work"
export OUTPUTDIR="${TMPDIR}/output"
export SUPER_BLOCK=""
export CURRENT_SLOT=""
export CURRENT_SUFFIX=""
export UNCURRENT_SUFFIX=""

# Default paths (can be overridden)
export TMPDIR="/data/local/tmp/superrw"
export LOGFILE="${TMPDIR}/dfe_ro2rw.log"
export BACKUPDIR="${TMPDIR}/backup"
export WORKDIR="${TMPDIR}/work"
export OUTPUTDIR="${TMPDIR}/output"
# EXTRACT_DIR: where lpunpack output and raw.ext4 intermediates live.
# Must be on a dev-capable filesystem (not nodev) so loop mounts work if needed.
# Always defaults to internal /data; setup_workspace may override to WORKDIR
# only after confirming the chosen filesystem is not nodev.
export EXTRACT_DIR="/data/local/tmp/superrw/extracted"

# Prioritize bundled binaries over system ones
export PATH="${BIN_DIR}:${PATH}"

BB="" # busybox path

find_external_sdcard() {
    local sd=""
    # Look for standard Android physical SD card mount paths (e.g. /storage/XXXX-XXXX)
    sd=$(mount | awk '{print $3}' | grep -E "^/storage/[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$" | head -n 1 || true)
    if [ -n "${sd}" ]; then
        echo "${sd}"
        return 0
    fi
    
    # Fallback to direct media_rw path
    sd=$(mount | awk '{print $3}' | grep -E "^/mnt/media_rw/[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$" | head -n 1 || true)
    if [ -n "${sd}" ]; then
        echo "${sd}"
        return 0
    fi
    
    echo ""
}

is_nodev_fs() {
    # Returns 0 (true) if the filesystem containing the given path is mounted nodev.
    local path="$1"
    # Walk up to find the deepest existing ancestor (mount point resolution)
    local check="${path}"
    while [ ! -d "${check}" ] && [ "${check}" != "/" ]; do
        check=$(dirname "${check}")
    done
    # /proc/mounts is most reliable: fields are device mountpoint fstype options ...
    if awk -v mp="${check}" '$2 == mp { print $4 }' /proc/mounts 2>/dev/null | grep -q "nodev"; then
        return 0
    fi
    # Fallback: busybox mount output: "device on mountpoint type fstype (options)"
    # Field 3 = mountpoint, field 6 = (options)
    if mount 2>/dev/null | awk -v mp="${check}" '$3 == mp { print $6 }' | grep -q "nodev"; then
        return 0
    fi
    return 1
}

setup_workspace() {
    local ext_sd
    ext_sd=$(find_external_sdcard)

    echo ""
    echo "============================================"
    echo "  Workspace Storage Location"
    echo "============================================"
    echo "  1) Internal Data (/data/local/tmp/superrw) [Recommended, Fast]"
    echo "  2) Internal Storage (/sdcard/superrw)"
    
    if [ -n "${ext_sd}" ]; then
        echo "  3) External MicroSD Card (${ext_sd}/superrw)"
    fi
    
    echo -n "Select option: "
    read -r ws_choice

    if [ "${ws_choice}" = "3" ] && [ -n "${ext_sd}" ]; then
        TMPDIR="${ext_sd}/superrw"
    elif [ "${ws_choice}" = "2" ]; then
        TMPDIR="/sdcard/superrw"
    else
        TMPDIR="/data/local/tmp/superrw"
    fi

    LOGFILE="${TMPDIR}/dfe_ro2rw.log"
    BACKUPDIR="${TMPDIR}/backup"
    WORKDIR="${TMPDIR}/work"
    OUTPUTDIR="${TMPDIR}/output"

    mkdir -p "${TMPDIR}" "${BACKUPDIR}" "${WORKDIR}" "${OUTPUTDIR}"

    # Decide where to put lpunpack output and raw.ext4 intermediates.
    # These files may need loop-mounting, which requires a dev-capable filesystem.
    # If the chosen workspace is nodev (SD card, /sdcard), keep them on internal /data.
    # Otherwise co-locate with the workspace to avoid filling /data.
    if is_nodev_fs "${TMPDIR}"; then
        EXTRACT_DIR="/data/local/tmp/superrw/extracted"
        mkdir -p "${EXTRACT_DIR}"
        # Initialize log file before logging (LOGFILE is on the chosen workspace)
        > "${LOGFILE}"
        log "Workspace initialized at ${TMPDIR}"
        log "NOTE: ${TMPDIR} is mounted nodev — partition images will be extracted to"
        log "      ${EXTRACT_DIR} (internal /data) to allow loop mounts if needed."
        log "      Extracted tree directories (mnt_*) will use ${WORKDIR} on SD card."
    else
        EXTRACT_DIR="${WORKDIR}/extracted"
        mkdir -p "${EXTRACT_DIR}"
        > "${LOGFILE}"
        log "Workspace initialized at ${TMPDIR}"
        log "Extraction directory: ${EXTRACT_DIR}"
    fi
}

###############################################################################
# Logging & Utilities
###############################################################################
log() {
    local msg
    if [ $# -gt 0 ]; then
        msg="[$(date '+%H:%M:%S')] $*"
        echo "${msg}" >> "${LOGFILE}"
        echo "${msg}" >&2
    else
        while IFS= read -r line; do
            msg="[$(date '+%H:%M:%S')] ${line}"
            echo "${msg}" >> "${LOGFILE}"
            echo "${msg}" >&2
        done
    fi
}

die() {
    log "FATAL: $*"
    exit 1
}

find_busybox() {
    if [ -f "${BIN_DIR}/busybox" ]; then
        BB="${BIN_DIR}/busybox"
        log "Using bundled busybox: ${BB}"
        return 0
    fi
    for p in /data/adb/magisk/busybox /data/adb/ksu/busybox /system/xbin/busybox /system/bin/busybox; do
        if [ -f "${p}" ]; then
            BB="${p}"
            log "Using system busybox: ${BB}"
            return 0
        fi
    done
    if command -v busybox >/dev/null 2>&1; then
        BB="busybox"
        log "Using PATH busybox"
        return 0
    fi
    return 1
}

require_tool() {
    local tool="$1"
    if [ -x "${BIN_DIR}/${tool}" ]; then
        return 0
    fi
    if [ -n "${BB}" ]; then
        "${BB}" which "${tool}" >/dev/null 2>&1 && return 0
    fi
    command -v "${tool}" >/dev/null 2>&1 && return 0
    die "Required tool not found: ${tool} (looked in ${BIN_DIR} and PATH)"
}

###############################################################################
# Partition Detection
###############################################################################
get_current_slot() {
    local slot
    slot=$(getprop ro.boot.slot_suffix 2>/dev/null)
    if [ -z "${slot}" ]; then
        slot=$(sed -n 's/.*androidboot.slot_suffix=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null)
    fi
    if [ -z "${slot}" ]; then
        slot=$(sed -n 's/.*androidboot.slot=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null)
    fi
    case "${slot}" in
        "_a") CURRENT_SUFFIX="_a"; UNCURRENT_SUFFIX="_b"; CURRENT_SLOT="0" ;;
        "_b") CURRENT_SUFFIX="_b"; UNCURRENT_SUFFIX="_a"; CURRENT_SLOT="1" ;;
        *)    CURRENT_SUFFIX="";   UNCURRENT_SUFFIX="";    CURRENT_SLOT="0" ;;
    esac
    log "Active slot: ${CURRENT_SUFFIX:-A-only}, Slot number: ${CURRENT_SLOT}"
}

find_super_block() {
    for dev in /dev/block/by-name/super /dev/block/bootdevice/by-name/super /dev/block/platform/*/by-name/super; do
        if [ -b "${dev}" ]; then
            SUPER_BLOCK=$(readlink -f "${dev}")
            log "Super block device: ${SUPER_BLOCK}"
            return 0
        fi
    done
    die "Could not find super partition block device"
}

find_block() {
    local name="$1"
    for dev in "/dev/block/by-name/${name}" "/dev/block/bootdevice/by-name/${name}"; do
        if [ -b "${dev}" ]; then
            readlink -f "${dev}"
            return 0
        fi
    done
    return 1
}

###############################################################################
# Tool Detection / Setup
###############################################################################
setup_binaries() {
    log "Binary directory: ${BIN_DIR}"
    if [ -d "${BIN_DIR}" ]; then
        log "Setting execute permissions on bundled binaries..."
        chmod +x "${BIN_DIR}"/* 2>/dev/null || true
        chmod -R a+rX "${BIN_DIR}" 2>/dev/null || true
        
        # Create wrappers to prevent LD_LIBRARY_PATH pollution
        local wrapper_dir="${BIN_DIR}/wrapper"
        mkdir -p "${wrapper_dir}"
        for bin in "${BIN_DIR}"/*; do
            if [ -f "${bin}" ] && [ -x "${bin}" ]; then
                local bname
                bname=$(basename "${bin}")
                echo "#!/system/bin/sh" > "${wrapper_dir}/${bname}"
                echo "export LD_LIBRARY_PATH=\"${BIN_DIR}/lib:${BIN_DIR}:\${LD_LIBRARY_PATH}\"" >> "${wrapper_dir}/${bname}"
                echo "exec \"${bin}\" \"\$@\"" >> "${wrapper_dir}/${bname}"
                chmod +x "${wrapper_dir}/${bname}"
            fi
        done
        export PATH="${wrapper_dir}:${PATH}"
        
        ls -1 "${BIN_DIR}" 2>/dev/null | log || true
    else
        log "WARNING: Binary directory ${BIN_DIR} not found!"
    fi

    if find_busybox; then
        log "Using busybox: ${BB}"
    else
        die "Busybox not found. Make sure to push the ${ARCH_DIR} directory to $(dirname "${BIN_DIR}")."
    fi

    require_tool "lpdump"
    require_tool "lpmake"
    require_tool "lpunpack"
    require_tool "make_ext4fs"
    require_tool "magiskboot"

    log "All required tools found (prioritizing bundled in ${BIN_DIR})"
}

###############################################################################
# DFE - Disable Force Encryption
###############################################################################
dfe_patch_fstab() {
    local fstab_file="$1"
    local patched=0

    if [ ! -f "${fstab_file}" ]; then
        return 1
    fi

    log "Patching fstab: ${fstab_file}"

    # sed -i requires a writable temp file on the same filesystem, which fails on
    # FAT32/exFAT (SD card). Use an explicit temp file on internal /data instead.
    local _tmp_fstab="/data/local/tmp/_dfe_fstab_patch.tmp"

    local patterns="fileencryption= forceencrypt= forcefdeorfbe= encryptable= metadata_encryption= keydirectory= inlinecrypt quota wrappedkey"
    for pattern in ${patterns}; do
        if grep -q "${pattern}" "${fstab_file}" 2>/dev/null; then
            log "  Removing: ${pattern}"
            sed "s/[[:space:]]${pattern}[^[:space:]]*//g" "${fstab_file}" > "${_tmp_fstab}" && cp "${_tmp_fstab}" "${fstab_file}"
            sed "s/,${pattern}[^,]*//g" "${fstab_file}" > "${_tmp_fstab}" && cp "${_tmp_fstab}" "${fstab_file}"
            patched=1
        fi
    done
    rm -f "${_tmp_fstab}"

    return ${patched}
}

dfe_patch_init_rc() {
    local rc_file="$1"
    local patched=0

    if [ ! -f "${rc_file}" ]; then
        return 1
    fi

    # Remove any DFE-NEO injection markers from previous runs
    if grep -q "DFE-NEO" "${rc_file}" 2>/dev/null; then
        local _tmp_rc="/data/local/tmp/_dfe_rc_patch.tmp"
        sed '/DFE-NEO/d' "${rc_file}" > "${_tmp_rc}" && cp "${_tmp_rc}" "${rc_file}"
        rm -f "${_tmp_rc}"
        patched=1
    fi

    return ${patched}
}

dfe_patch_fstabs_in_dir() {
    local target_dir="$1"
    local found=0

    log "Searching for fstab files in ${target_dir}..."

    # Search recursively from target_dir root. Handles both combined-root layouts
    # (target_dir/vendor/etc/fstab.*) and per-partition extraction roots
    # (target_dir/etc/fstab.*) without hardcoded path guesses.
    for fstab in $(find "${target_dir}" -name "fstab.*" -type f 2>/dev/null); do
        if dfe_patch_fstab "${fstab}"; then
            found=1
        fi
    done

    if [ ${found} -eq 0 ]; then
        log "No fstab files needed patching in ${target_dir}"
    fi
}

dfe_patch_rc_in_dir() {
    local target_dir="$1"
    local found=0

    # Search recursively — same reasoning as dfe_patch_fstabs_in_dir.
    for rc in $(find "${target_dir}" -name "*.rc" -type f 2>/dev/null); do
        if dfe_patch_init_rc "${rc}"; then
            found=1
        fi
    done
}

dfe_patch_boot_images() {
    log "Patching fstab in boot image ramdisks..."
    local found=0
    for boot_part in boot vendor_boot init_boot; do
        local boot_dev
        boot_dev=$(find_block "${boot_part}${CURRENT_SUFFIX}" 2>/dev/null) || continue
        local boot_dir="${WORKDIR}/ramdisk_${boot_part}"
        mkdir -p "${boot_dir}"
        cd "${boot_dir}"
        magiskboot unpack "${boot_dev}" 2>/dev/null || continue
        if [ -f "ramdisk.cpio" ]; then
            mkdir -p ramdisk_root
            cd ramdisk_root
            magiskboot cpio "../ramdisk.cpio" extract 2>/dev/null || true
            for fstab in $(find . -name "fstab.*" -type f 2>/dev/null); do
                if dfe_patch_fstab "${fstab}"; then
                    magiskboot cpio "../ramdisk.cpio" "add 644 ${fstab} ${fstab}" 2>/dev/null
                    found=1
                fi
            done
            cd "${boot_dir}"
            magiskboot repack "${boot_dev}" 2>/dev/null
            local new_boot="${boot_dir}/new-boot.img"
            if [ -f "${new_boot}" ]; then
                blockdev --setrw "${boot_dev}" 2>/dev/null || true
                cat "${new_boot}" > "${boot_dev}"
                log "Patched ${boot_part} ramdisk fstab"
            fi
        fi
        cd "${TMPDIR}"
        rm -rf "${boot_dir}"
    done
}

dfe_hide_encrypted_flag() {
    # Force system to think data is not encrypted
    log "Setting ro.crypto.state to 'unencrypted'..."
    resetprop ro.crypto.state unencrypted 2>/dev/null || true
    resetprop ro.crypto.type file 2>/dev/null || true
    log "Encryption state properties set"
}

dfe_disable_encryption_live() {
    log "============================================"
    log "  Disable Force Encryption (DFE) - Live"
    log "============================================"

    # Remount vendor as RW first
    local vendor_dev=""
    vendor_dev=$(find_block "vendor${CURRENT_SUFFIX}" 2>/dev/null) || vendor_dev=$(find_block "vendor" 2>/dev/null) || true
    if [ -n "${vendor_dev}" ]; then
        mount -o rw,remount "${vendor_dev}" 2>/dev/null || true
    fi
    mount -o rw,remount /vendor 2>/dev/null || true
    mount -o rw,remount / 2>/dev/null || true

    # Patch fstabs in live root
    dfe_patch_fstabs_in_dir "/"
    dfe_patch_rc_in_dir "/"
    
    # Patch boot images
    dfe_patch_boot_images

    # Set crypto state to unencrypted
    dfe_hide_encrypted_flag

    log "DFE live patching completed"
}

###############################################################################
# RO2RW - Read-Only to Read-Write Super Conversion
###############################################################################
ro2rw_dump_super() {
    local super_img="${OUTPUTDIR}/super_original.img"

    if [ -f "${super_img}" ]; then
        log "Using existing super dump: ${super_img}"
        echo "${super_img}"
        return 0
    fi

    log "Dumping super partition to ${super_img}..."
    if [ -b "${SUPER_BLOCK}" ]; then
        dd if="${SUPER_BLOCK}" of="${super_img}" bs=1M conv=sparse 2>/dev/null || {
            dd if="${SUPER_BLOCK}" of="${super_img}" bs=1M 2>/dev/null || die "Failed to dump super partition"
        }
    else
        die "Super block device not found"
    fi

    local size
    size=$(${BB} stat -c%s "${super_img}" 2>/dev/null)
    log "Dumped super image: ${size} bytes"
    echo "${super_img}"
}

ro2rw_get_lp_metadata() {
    local super_img="$1"
    # Write metadata to internal storage — SD card (FAT32/exFAT) file redirects
    # can fail silently, and lpdump output must be reliably writable.
    local metadata_file="/data/local/tmp/superrw_lp_metadata.txt"
    mkdir -p "$(dirname "${metadata_file}")"

    log "Reading logical partition metadata..."
    # Always read from block device directly — avoids SD card fstat issues.
    # Fall back to image file only if block device is unavailable.
    local _lpdump_src="${super_img}"
    if [ -b "${SUPER_BLOCK}" ]; then
        _lpdump_src="${SUPER_BLOCK}"
    fi

    # Disable set -e around lpdump so we can handle non-zero exit ourselves
    set +e
    lpdump "${_lpdump_src}" > "${metadata_file}" 2>&1
    local _rc=$?
    set -e

    if [ ${_rc} -ne 0 ] || [ ! -s "${metadata_file}" ]; then
        log "lpdump on ${_lpdump_src} failed (rc=${_rc}), trying alternate..."
        if [ "${_lpdump_src}" = "${SUPER_BLOCK}" ] && [ -f "${super_img}" ]; then
            set +e
            lpdump "${super_img}" > "${metadata_file}" 2>&1
            _rc=$?
            set -e
        fi
        [ ${_rc} -ne 0 ] && die "lpdump failed (rc=${_rc})"
        [ ! -s "${metadata_file}" ] && die "lpdump produced empty metadata"
    fi

    log "lpdump metadata size: $(wc -c < "${metadata_file}") bytes"
    cat "${metadata_file}" >> "${LOGFILE}"
    cp "${metadata_file}" "${WORKDIR}/lp_metadata.txt" 2>/dev/null || true
    echo "${metadata_file}"
}

ro2rw_extract_partitions() {
    local super_img="$1"
    # Use EXTRACT_DIR set by setup_workspace — internal /data when the workspace
    # is nodev (SD card / sdcard), otherwise co-located with the workspace.
    local extract_dir="${EXTRACT_DIR}"
    mkdir -p "${extract_dir}"

    log "Extracting partitions from super image..."
    # Read from block device directly to avoid SD card fstat issues
    local _lpu_src="${super_img}"
    [ -b "${SUPER_BLOCK}" ] && _lpu_src="${SUPER_BLOCK}"
    lpunpack "${_lpu_src}" "${extract_dir}" 2>&1 | log || {
        log "lpunpack encountered issues, checking extracted files..."
    }

    # Verify at least one partition was extracted
    local _count
    _count=$(ls -1 "${extract_dir}"/*.img 2>/dev/null | wc -l)
    if [ "${_count}" -eq 0 ]; then
        die "lpunpack produced no partition images in ${extract_dir}"
    fi

    log "Extracted partitions:"
    ls -la "${extract_dir}" >> "${LOGFILE}"
    ls -1 "${extract_dir}" 2>/dev/null | log

    echo "${extract_dir}"
}

ro2rw_get_orig_size() {
    local name="$1"
    local sizes_str="$2"
    for _entry in ${sizes_str}; do
        local _en="${_entry%%:*}"
        local _ev="${_entry#*:}"
        if [ "${_en}" = "${name}" ]; then
            echo "${_ev}"
            return 0
        fi
    done
    echo "0"
}

ro2rw_convert_to_rw() {
    local extract_dir="$1"
    local do_dfe="$2"
    local orig_sizes_str="$3"
    local converted=0

    log "Converting read-only partitions to read-write..."

    for img in "${extract_dir}"/*.img; do
        local name
        name=$(${BB} basename "${img}")
        local fstype
        fstype=$(${BB} blkid "${img}" 2>/dev/null | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p' || true)
        if [ -z "${fstype}" ]; then
            fstype=$(blkid "${img}" 2>/dev/null | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p' || true)
        fi

        log "Processing: ${name} (fs: ${fstype})"

        case "${fstype}" in
            "erofs")
                log "  Converting EROFS -> EXT4: ${name}"
                local size=$(${BB} stat -c%s "${img}" 2>/dev/null)
                local mnt_point="${WORKDIR}/mnt_${name}"
                mkdir -p "${mnt_point}"
                
                # Mount or extract the erofs image
                local loop_dev=""
                local mounted=0
                
                if mount -t erofs -o loop,ro "${img}" "${mnt_point}" 2>/dev/null; then
                    mounted=1
                else
                    loop_dev=$(losetup -f 2>/dev/null || true)
                    if [ -n "${loop_dev}" ]; then
                        losetup "${loop_dev}" "${img}" 2>/dev/null || true
                        if mount -t erofs -o ro "${loop_dev}" "${mnt_point}" 2>/dev/null; then
                            mounted=1
                        fi
                    fi
                fi
                
                if [ ${mounted} -eq 0 ]; then
                    log "  Cannot mount EROFS natively, falling back to manual extraction..."
                    # Extract the erofs image
                    erofs -i "${img}" -x "${mnt_point}" 2>/dev/null || \
                    erofs extract -i "${img}" -x "${mnt_point}" 2>/dev/null || \
                    erofs "${img}" "${mnt_point}" 2>/dev/null || {
                        log "  Skipping conversion for ${name} (cannot mount or extract EROFS)"
                        [ -n "${loop_dev}" ] && losetup -d "${loop_dev}" 2>/dev/null || true
                        continue
                    }
                fi

                # Get actual uncompressed data size (EROFS is highly compressed)
                local uncompressed_kb=$(${BB} du -sk "${mnt_point}" 2>/dev/null | ${BB} awk '{print $1}')
                [ -z "${uncompressed_kb}" ] && uncompressed_kb=$((size / 1024))
                # Use original partition size from lpdump when available, else compute
                local _part_name="${name%.*}"
                local _orig_size
                _orig_size=$(ro2rw_get_orig_size "${_part_name}" "${orig_sizes_str}")
                local new_size
                if [ -n "${_orig_size}" ] && [ "${_orig_size}" -gt 0 ] 2>/dev/null; then
                    # Use exact original partition size from lpdump so images fit in super
                    new_size="${_orig_size}"
                else
                    # No lpdump size: use actual uncompressed data + 40% headroom.
                    # ext4 needs extra space for journal, inode table, and block group
                    # descriptors on top of raw file data — 20% was too tight.
                    new_size=$(${BB} awk -v kb="${uncompressed_kb}" -v orig="${size}" 'BEGIN { s = (kb * 1024) * 1.40 + 8388608; if (s < orig) s = orig; printf "%.0f\n", s }')
                fi
                # Enforce 64MB minimum so ext4 journal always fits
                new_size=$(${BB} awk -v s="${new_size}" 'BEGIN { m=67108864; printf "%.0f\n", (s<m?m:s) }')

                # Apply DFE patches before packing into ext4.
                # When the EROFS was extracted by a userspace tool (mounted=0), the
                # directory is writable and we can patch in-place.
                # When it's a kernel mount (mounted=1), the filesystem is read-only;
                # patching must happen inside the writable ext4 mount below instead.
                local _dfe_done_pre=0
                if [ "${do_dfe}" = "1" ] && [ ${mounted} -eq 0 ]; then
                    log "  Applying DFE to ${name} (pre-pack, extracted tree)..."
                    dfe_patch_fstabs_in_dir "${mnt_point}"
                    dfe_patch_rc_in_dir "${mnt_point}"
                    _dfe_done_pre=1
                elif [ "${do_dfe}" = "1" ] && [ ${mounted} -eq 1 ]; then
                    log "  Applying DFE to ${name} (pre-pack)..."
                    # mnt_point is a kernel-mounted read-only EROFS.
                    # Patch fstabs via temp copies on /data and repack with make_ext4fs.
                    # We'll handle this by patching inside the ext4 mount in the alternate path.
                    _dfe_done_pre=0
                fi

                # Create a raw ext4 image (not sparse) — lpmake needs fstat-able files
                local raw_img="${extract_dir}/${name%.*}.raw.ext4"
                make_ext4fs -l "${new_size}" "${raw_img}" "${mnt_point}" >"${WORKDIR}/_mkfs_${name%.*}.log" 2>&1 && _mkok=0 || _mkok=$?
                cat "${WORKDIR}/_mkfs_${name%.*}.log" | log || true
                if [ ${_mkok} -ne 0 ]; then
                    log "  make_ext4fs failed, trying alternate method for ${name}..."
                    rm -f "${raw_img}"
                    # The original partition size may be too tight once EROFS is
                    # decompressed into ext4 (journal + inode table overhead).
                    # Add 20% headroom capped at the super device budget.
                    local alt_size
                    alt_size=$(${BB} awk -v s="${new_size}" -v kb="${uncompressed_kb}" -v orig="${_orig_size}" 'BEGIN {
                        data = kb * 1024
                        candidate = data * 1.30 + 8388608
                        candidate = (candidate > s ? candidate : s)
                        if (orig > 0 && candidate > orig) candidate = orig
                        printf "%.0f\n", candidate
                    }')
                    # Create empty ext4, then mount and copy files from already-patched tree
                    make_ext4fs -l "${alt_size}" "${raw_img}" >"${WORKDIR}/_mkfs_${name%.*}.log" 2>&1 && _mkok=0 || _mkok=$?
                    cat "${WORKDIR}/_mkfs_${name%.*}.log" | log || true
                    if [ ${_mkok} -eq 0 ] && [ -f "${raw_img}" ]; then
                        # ext4 loop mount requires a dev-capable filesystem.
                        # Use internal /data regardless of workspace choice.
                        local ext4_mnt="/data/local/tmp/superrw_ext4_${name}"
                        rm -rf "${ext4_mnt}"
                        mkdir -p "${ext4_mnt}"
                        local loop_dev2=$(losetup -f 2>/dev/null || true)
                        if [ -n "${loop_dev2}" ]; then
                            losetup "${loop_dev2}" "${raw_img}" 2>/dev/null || true
                            if mount -t ext4 -o rw "${loop_dev2}" "${ext4_mnt}" 2>/dev/null || mount -o rw "${loop_dev2}" "${ext4_mnt}" 2>/dev/null; then
                                log "  Copying files from EROFS into ext4 image..."
                                # Capture cp exit status separately — piping through log swallows it
                                _cp_err=0
                                ${BB} cp -a "${mnt_point}/." "${ext4_mnt}/" 2>&1 | log || _cp_err=1
                                sync
                                # If DFE wasn't applied pre-pack (EROFS kernel-mounted RO),
                                # apply fstab patches now inside the writable ext4 mount.
                                if [ "${do_dfe}" = "1" ] && [ "${_dfe_done_pre}" = "0" ]; then
                                    log "  Applying DFE to ${name} (post-copy, inside ext4 mount)..."
                                    dfe_patch_fstabs_in_dir "${ext4_mnt}"
                                    dfe_patch_rc_in_dir "${ext4_mnt}"
                                fi
                                # Verify the copy filled at least 80% of what the source had.
                                # If the image ran out of space cp will have printed errors above.
                                _src_kb=$(${BB} du -sk "${mnt_point}" 2>/dev/null | ${BB} awk '{print $1}')
                                _dst_kb=$(${BB} du -sk "${ext4_mnt}" 2>/dev/null | ${BB} awk '{print $1}')
                                if [ -n "${_src_kb}" ] && [ -n "${_dst_kb}" ] && [ "${_src_kb}" -gt 0 ]; then
                                    _pct=$(${BB} awk -v s="${_src_kb}" -v d="${_dst_kb}" 'BEGIN { printf "%d", d*100/s }')
                                    if [ "${_pct}" -lt 80 ]; then
                                        log "  WARNING: Only ${_pct}% of source data copied — image too small; retrying with larger size"
                                        _cp_err=1
                                    fi
                                fi
                                umount -fl "${ext4_mnt}" 2>/dev/null || true
                                if [ "${_cp_err}" -eq 0 ]; then
                                    _mkok=0
                                else
                                    # Retry once with a larger image (+40% of uncompressed data)
                                    losetup -d "${loop_dev2}" 2>/dev/null || true
                                    rm -f "${raw_img}"
                                    local retry_size
                                    retry_size=$(${BB} awk -v kb="${uncompressed_kb}" -v orig="${_orig_size}" 'BEGIN {
                                        candidate = (kb * 1024) * 1.50 + 16777216
                                        if (orig > 0 && candidate > orig) candidate = orig
                                        printf "%.0f\n", candidate
                                    }')
                                    log "  Retrying with larger image: ${retry_size} bytes"
                                    make_ext4fs -l "${retry_size}" "${raw_img}" >/dev/null 2>&1 && {
                                        loop_dev2=$(losetup -f 2>/dev/null || true)
                                        losetup "${loop_dev2}" "${raw_img}" 2>/dev/null || true
                                        mount -t ext4 -o rw "${loop_dev2}" "${ext4_mnt}" 2>/dev/null || true
                                        ${BB} cp -a "${mnt_point}/." "${ext4_mnt}/" 2>&1 | log || true
                                        sync
                                        if [ "${do_dfe}" = "1" ] && [ "${_dfe_done_pre}" = "0" ]; then
                                            dfe_patch_fstabs_in_dir "${ext4_mnt}"
                                            dfe_patch_rc_in_dir "${ext4_mnt}"
                                        fi
                                        umount -fl "${ext4_mnt}" 2>/dev/null || true
                                        _mkok=0
                                    } || _mkok=1
                                fi
                            else
                                _mkok=1
                            fi
                            losetup -d "${loop_dev2}" 2>/dev/null || true
                        else
                            _mkok=1
                        fi
                        rm -rf "${ext4_mnt}"
                    fi
                    # Clean up EROFS mount
                    umount -fl "${mnt_point}" 2>/dev/null || true
                    [ -n "${loop_dev}" ] && losetup -d "${loop_dev}" 2>/dev/null || true
                    if [ ${_mkok} -ne 0 ]; then
                        log "  Failed to create ext4 image for ${name} (all methods exhausted)"
                        rm -rf "${mnt_point}"
                        continue
                    fi
                    log "  Created ext4 image via alternate method: ${name}"
                fi
                umount -fl "${mnt_point}" 2>/dev/null || true
                [ -n "${loop_dev}" ] && losetup -d "${loop_dev}" 2>/dev/null || true
                rm -rf "${mnt_point}"

                if [ -f "${raw_img}" ]; then
                    ${BB} mv -f "${raw_img}" "${img}"
                    converted=1
                    log "  Converted ${name} to EXT4"
                else
                    log "  Skipping ${name}: raw ext4 image not created"
                fi
                ;;
            "f2fs")
                log "  Handling F2FS: ${name}"
                local size=$(${BB} stat -c%s "${img}" 2>/dev/null)
                local mnt_point="${WORKDIR}/mnt_${name}"
                mkdir -p "${mnt_point}"
                
                # Try mounting natively
                local loop_dev=""
                local mounted=0
                
                if mount -t f2fs -o loop,ro "${img}" "${mnt_point}" 2>/dev/null; then
                    mounted=1
                else
                    loop_dev=$(losetup -f 2>/dev/null || true)
                    if [ -n "${loop_dev}" ]; then
                        losetup "${loop_dev}" "${img}" 2>/dev/null || true
                        if mount -t f2fs -o ro "${loop_dev}" "${mnt_point}" 2>/dev/null; then
                            mounted=1
                        fi
                    fi
                fi
                
                # Get actual uncompressed size
                local uncompressed_kb=$(${BB} du -sk "${mnt_point}" 2>/dev/null | ${BB} awk '{print $1}')
                [ -z "${uncompressed_kb}" ] && uncompressed_kb=$((size / 1024))
                # Use original partition size when available, else compute
                local _part_name="${name%.*}"
                local _orig_size
                _orig_size=$(ro2rw_get_orig_size "${_part_name}" "${orig_sizes_str}")
                local new_size
                if [ -n "${_orig_size}" ] && [ "${_orig_size}" -gt 0 ] 2>/dev/null; then
                    new_size="${_orig_size}"
                else
                    new_size=$(${BB} awk -v kb="${uncompressed_kb}" 'BEGIN { printf "%.0f\n", (kb * 1024) * 1.10 + 52428800 }')
                fi
                
                if [ ${mounted} -eq 1 ]; then
                    # Apply DFE to the live mount before packing — no loop device needed
                    if [ "${do_dfe}" = "1" ]; then
                        log "  Applying DFE to ${name} (pre-pack)..."
                        dfe_patch_fstabs_in_dir "${mnt_point}"
                        dfe_patch_rc_in_dir "${mnt_point}"
                    fi

                    local raw_img="${extract_dir}/${name%.*}.raw.ext4"
                    make_ext4fs -l "${new_size}" "${raw_img}" "${mnt_point}" 2>&1 | log || true
                    umount -fl "${mnt_point}" 2>/dev/null || true
                    [ -n "${loop_dev}" ] && losetup -d "${loop_dev}" 2>/dev/null || true

                    # Keep raw (non-sparse) — lpmake needs fstat-able files
                    ${BB} mv -f "${raw_img}" "${img}"
                    converted=1
                    log "  Converted ${name} from F2FS to EXT4"
                else
                    log "  Cannot mount F2FS natively, skipping conversion"
                    [ -n "${loop_dev}" ] && losetup -d "${loop_dev}" 2>/dev/null || true
                fi
                rm -rf "${mnt_point}"
                ;;
            "ext4")
                log "  Already EXT4, verifying RW compatibility: ${name}"
                local mnt_point="${WORKDIR}/mnt_${name}"
                mkdir -p "${mnt_point}"
                local needs_tuning=0
                
                if mount -t ext4 -o loop,rw "${img}" "${mnt_point}" 2>/dev/null || mount -o loop,rw "${img}" "${mnt_point}" 2>/dev/null; then
                    touch "${mnt_point}/.rw_test" 2>/dev/null && {
                        rm -f "${mnt_point}/.rw_test"
                        log "  ${name} is already RW-compatible"
                        if [ "${do_dfe}" = "1" ]; then
                            log "  Applying DFE to ${name}..."
                            dfe_patch_fstabs_in_dir "${mnt_point}"
                            dfe_patch_rc_in_dir "${mnt_point}"
                        fi
                        umount -fl "${mnt_point}" 2>/dev/null || true
                    } || {
                        log "  ${name} is RO, tuning..."
                        needs_tuning=1
                        umount -fl "${mnt_point}" 2>/dev/null || true
                    }
                else
                    needs_tuning=1
                fi
                
                if [ ${needs_tuning} -eq 1 ]; then
                    local size
                    size=$(${BB} stat -c%s "${img}" 2>/dev/null)
                    local _part_name="${name%.*}"
                    local _orig_size
                    _orig_size=$(ro2rw_get_orig_size "${_part_name}" "${orig_sizes_str}")
                    local new_size
                    if [ -n "${_orig_size}" ] && [ "${_orig_size}" -gt 0 ] 2>/dev/null; then
                        new_size="${_orig_size}"
                    else
                        new_size=$(${BB} awk -v s="${size}" 'BEGIN { printf "%.0f\n", s + s/10 + 52428800 }')
                    fi
                    
                    local loop_dev=""
                    local mounted=0
                    
                    if mount -t ext4 -o loop,ro "${img}" "${mnt_point}" 2>/dev/null || mount -o loop,ro "${img}" "${mnt_point}" 2>/dev/null; then
                        mounted=1
                    else
                        loop_dev=$(losetup -f 2>/dev/null || true)
                        if [ -n "${loop_dev}" ]; then
                            losetup "${loop_dev}" "${img}" 2>/dev/null || true
                            if mount -t ext4 -o ro "${loop_dev}" "${mnt_point}" 2>/dev/null || mount -o ro "${loop_dev}" "${mnt_point}" 2>/dev/null; then
                                mounted=1
                            fi
                        fi
                    fi
                    
                    if [ ${mounted} -eq 1 ]; then
                        local raw_img="${extract_dir}/${name%.*}.raw.ext4"
                        make_ext4fs -l "${new_size}" "${raw_img}" "${mnt_point}" 2>&1 | log || true
                        umount -fl "${mnt_point}" 2>/dev/null || true
                        [ -n "${loop_dev}" ] && losetup -d "${loop_dev}" 2>/dev/null || true
                        
                        if [ "${do_dfe}" = "1" ]; then
                            local rw_mnt="${WORKDIR}/rw_${name}"
                            mkdir -p "${rw_mnt}"
                            if mount -t ext4 -o loop,rw "${raw_img}" "${rw_mnt}" 2>/dev/null || mount -o loop,rw "${raw_img}" "${rw_mnt}" 2>/dev/null; then
                                log "  Applying DFE to ${name}..."
                                dfe_patch_fstabs_in_dir "${rw_mnt}"
                                dfe_patch_rc_in_dir "${rw_mnt}"
                                umount -fl "${rw_mnt}" 2>/dev/null || true
                            fi
                            rm -rf "${rw_mnt}"
                        fi

                        # Keep raw (non-sparse) — lpmake needs fstat-able files
                        ${BB} mv -f "${raw_img}" "${img}"
                        converted=1
                    else
                        log "  Cannot mount EXT4 natively for tuning, skipping"
                        [ -n "${loop_dev}" ] && losetup -d "${loop_dev}" 2>/dev/null || true
                    fi
                fi
                rm -rf "${mnt_point}"
                ;;
            *)
                if ${BB} strings "${img}" 2>/dev/null | head -5 | grep -q "ext4" 2>/dev/null; then
                    log "  Detected as EXT4 by signature: ${name}"
                else
                    log "  Unknown fstype, skipping: ${name}"
                fi
                ;;
        esac
    done

    if [ ${converted} -eq 0 ]; then
        log "No partitions needed conversion, or conversion not possible"
    else
        log "Partition conversion complete"
    fi
}

ro2rw_get_orig_sizes() {
    local metadata_file="$1"
    # Parse lpdump output for partition sizes. Handles two formats:
    #
    # Format A: explicit "Size: N bytes" line after "Name: part"
    # Format B (this device): extent lines "  START .. END linear super OFFSET"
    #   size = sum of (END - START + 1) * 512 bytes per partition
    #   Partition blocks are separated by "------------------------" lines.
    #
    # Outputs "partname:bytes" lines consumed by ro2rw_get_orig_size().
    awk '
        /^[[:space:]]*Name:[[:space:]]/ && !/[Gg]roup/ {
            # Flush previous partition if we have extent data but no Size: line
            if (name != "" && extent_sectors > 0 && !emitted) {
                print name ":" extent_sectors * 512
            }
            name = $NF
            sub(/:$/, "", name)
            extent_sectors = 0
            emitted = 0
        }
        /^[[:space:]]*[Ss]ize:[[:space:]]/ && name != "" && !emitted {
            for (i = 1; i <= NF; i++) {
                val = $i + 0
                if (val > 0) {
                    print name ":" val
                    emitted = 1
                    break
                }
            }
        }
        # Extent line: "    START .. END linear ..."  ($1=int $2=".." $3=int)
        /^[[:space:]]*[0-9]/ && $2 == ".." && name != "" {
            sectors = $3 - $1 + 1
            if (sectors > 0) extent_sectors += sectors
        }
        # Partition separator — flush extent-derived size if no explicit Size: seen
        /^-+$/ && name != "" && !emitted {
            if (extent_sectors > 0) {
                print name ":" extent_sectors * 512
                emitted = 1
            }
        }
    END {
        if (name != "" && extent_sectors > 0 && !emitted)
            print name ":" extent_sectors * 512
    }
    ' "${metadata_file}" 2>/dev/null
}

ro2rw_build_new_super() {
    local extract_dir="$1"
    local metadata_file="$2"
    local orig_sizes_str="$3"
    local new_super="${OUTPUTDIR}/super_rw.img"
    # Use already-parsed metadata file (passed in) — avoids re-running lpdump
    # against the SD card image which causes fstat failures on FAT32/exFAT.
    local metadata_info
    metadata_info=$(grep -E "(super partition name:|block device-size:|partition size:|Partition name|Group name|Metadata max size|Metadata slot count|Block size)" "${metadata_file}" 2>/dev/null || true)

    log "Building new read-write super image..."

    # Build lpmake command from lpdump output
    local lp_args=""
    local block_size=4096
    local super_name="super"
    local metadata_slots=3
    local metadata_max_size=""

    # Parse lpdump for metadata
    if [ -f "${metadata_file}" ]; then
        block_size=$(${BB} grep -m1 "Block size" "${metadata_file}" 2>/dev/null | ${BB} awk '{print $NF}' || true)
        [ -z "${block_size}" ] && block_size="4096"
        super_name=$(${BB} grep -m1 "super partition name:" "${metadata_file}" 2>/dev/null | ${BB} awk '{print $NF}' || true)
        [ -z "${super_name}" ] && super_name="super"
        metadata_slots=$(${BB} grep -m1 "Metadata slot count" "${metadata_file}" 2>/dev/null | ${BB} awk '{print $NF}' || true)
        [ -z "${metadata_slots}" ] && metadata_slots="3"
        metadata_max_size=$(${BB} grep -m1 "Metadata max size" "${metadata_file}" 2>/dev/null | ${BB} awk '{print $(NF-1)}' || true)
        [ -z "${metadata_max_size}" ] && metadata_max_size="65536"
    fi

    # Get total super size
    local total_size
    total_size=$(${BB} stat -c%s "${OUTPUTDIR}/super_original.img" 2>/dev/null || true)
    if [ -z "${total_size}" ]; then
        die "Failed to get size of ${OUTPUTDIR}/super_original.img"
    fi

    lp_args="--device-size ${total_size} --metadata-size ${metadata_max_size} --metadata-slots ${metadata_slots} --block-size ${block_size} --super-name ${super_name}"

    # Detect groups from lpdump
    local groups
    groups=$(${BB} grep -E "Group name|group:" "${metadata_file}" 2>/dev/null | ${BB} awk '{print $NF}' | sort -u || true)
    [ -z "${groups}" ] && groups="default"

    # Determine partition arrangement — use actual image file size so lpmake
    # declared sizes always match the images being passed (no over-allocation).
    # Build --partition args first, then --image args (lpmake requires this order).
    #
    # The alternate EROFS->EXT4 path may have grown partitions beyond their original
    # sizes to fit the decompressed data. If the sum of all partition sizes exceeds
    # the super device budget, lpmake will fail. We must proportionally shrink
    # oversized images back to fit, using resize2fs to avoid corrupting ext4.
    local _total_parts=0
    for img in "${extract_dir}"/*.img; do
        [ -f "${img}" ] || continue
        _sz=$(${BB} stat -c%s "${img}" 2>/dev/null || echo 0)
        _total_parts=$(${BB} awk -v a="${_total_parts}" -v b="${_sz}" 'BEGIN{printf "%d", a+b}')
    done
    # Reserve space for metadata: slots * max_size * 2 (primary+backup) + 1MB headroom
    local _meta_reserve
    _meta_reserve=$(${BB} awk -v slots="${metadata_slots}" -v ms="${metadata_max_size}"         'BEGIN{printf "%d", slots*ms*2 + 1048576}')
    local _budget
    _budget=$(${BB} awk -v ts="${total_size}" -v mr="${_meta_reserve}"         'BEGIN{printf "%d", ts - mr}')
    if [ "${_total_parts}" -gt "${_budget}" ] 2>/dev/null; then
        log "WARNING: Partition images total ${_total_parts} bytes, but super budget is ${_budget} bytes."
        log "         Shrinking oversized ext4 images proportionally to fit..."
        for img in "${extract_dir}"/*.img; do
            [ -f "${img}" ] || continue
            _iname=$(${BB} basename "${img}" .img)
            _isz=$(${BB} stat -c%s "${img}" 2>/dev/null || echo 0)
            # Compute allowed size: proportional share of budget, aligned to 4096
            _allowed=$(${BB} awk -v sz="${_isz}" -v tot="${_total_parts}" -v bgt="${_budget}"                 'BEGIN{printf "%d", int(sz/tot*bgt/4096)*4096}')
            if [ "${_allowed}" -lt "${_isz}" ] 2>/dev/null && [ "${_allowed}" -gt 0 ] 2>/dev/null; then
                log "  Shrinking ${_iname}: ${_isz} -> ${_allowed} bytes"
                # e2fsck then resize2fs to shrink safely; fall back to truncate
                e2fsck -fy "${img}" >/dev/null 2>&1 || true
                if resize2fs "${img}" "$((${_allowed}/4096))s" >/dev/null 2>&1; then
                    truncate -s "${_allowed}" "${img}" 2>/dev/null || true
                else
                    log "  resize2fs failed for ${_iname}, using truncate (may corrupt fs)"
                    truncate -s "${_allowed}" "${img}" 2>/dev/null || true
                fi
            fi
        done
    fi

    local partitions=""
    local image_args=""
    for img in "${extract_dir}"/*.img; do
        [ -f "${img}" ] || continue
        local name
        name=$(${BB} basename "${img}" .img)
        # Always use actual file size so declared size == image size
        local size
        size=$(${BB} stat -c%s "${img}" 2>/dev/null)
        [ -z "${size}" ] || [ "${size}" -eq 0 ] 2>/dev/null && continue

        local orig_group="default"
        orig_group=$(${BB} grep -B1 "${name}" "${metadata_file}" 2>/dev/null | ${BB} grep "Group name" 2>/dev/null | ${BB} awk '{print $NF}' || true)
        [ -z "${orig_group}" ] && orig_group="default"

        partitions="${partitions} --partition ${name}:none:${size}:${orig_group}"
        image_args="${image_args} --image ${name}=${img}"
    done

    # Build group arguments
    local group_args=""
    for grp in ${groups}; do
        if [ "${grp}" = "default" ]; then
            continue
        fi
        local max_size=0
        # Get max size from original metadata
        max_size=$(${BB} grep -A2 "Group name.*${grp}" "${metadata_file}" 2>/dev/null | ${BB} grep "max size" 2>/dev/null | ${BB} awk '{print $(NF-1)}' || true)
        if [ -z "${max_size}" ] || [ "${max_size}" = "0" ] || [ "${max_size}" = "none" ]; then
            max_size="${total_size}"
        fi
        group_args="${group_args} --group ${grp}:${max_size}"
    done

    local cmd="lpmake ${lp_args} ${group_args} ${partitions}${image_args} --output ${new_super}"
    log "lpmake command: ${cmd}"
    echo "${cmd}" > "${WORKDIR}/lpmake_cmd.txt"

    # Verify all image files exist before running lpmake
    for _vimg in "${extract_dir}"/*.img; do
        if [ ! -f "${_vimg}" ]; then
            die "Image file not found for lpmake: ${_vimg}"
        fi
    done

    # Execute lpmake
    ${cmd} 2>&1 | log || {
        log "lpmake failed (likely SD card fstat issue), retrying with internal storage..."
        # Copy images to internal /data which supports fstat properly
        local local_img_dir="/data/local/tmp/superrw/lpmake_images"
        rm -rf "${local_img_dir}"
        mkdir -p "${local_img_dir}"
        for _src in "${extract_dir}"/*.img; do
            [ -f "${_src}" ] || continue
            ${BB} cp "${_src}" "${local_img_dir}/" 2>/dev/null ||                 dd if="${_src}" of="${local_img_dir}/$(${BB} basename "${_src}")" bs=1M 2>/dev/null || true
        done
        # Build --partition and --image args in two passes (lpmake requires this order)
        local local_part_args=""
        local local_img_args=""
        for img in "${local_img_dir}"/*.img; do
            [ -f "${img}" ] || continue
            local name
            name=$(${BB} basename "${img}" .img)
            local size
            size=$(${BB} stat -c%s "${img}" 2>/dev/null)
            [ -z "${size}" ] || [ "${size}" -eq 0 ] 2>/dev/null && continue
            local_part_args="${local_part_args} --partition ${name}:none:${size}:default"
            local_img_args="${local_img_args} --image ${name}=${img}"
        done
        local local_cmd="lpmake --device-size ${total_size} --metadata-size 65536 --metadata-slots 3 --block-size 4096 --super-name ${super_name}${local_part_args}${local_img_args} --output ${new_super}"
        log "Local lpmake: ${local_cmd}"
        ${local_cmd} 2>&1 | log || die "lpmake failed even with local images"
    }

    log "New RW super image created: ${new_super}"
    ls -lh "${new_super}" >> "${LOGFILE}"
    echo "${new_super}"
}

ro2rw_flash_super() {
    local super_img="$1"

    log "============================================"
    log "  Preparing to flash new super image"
    log "============================================"
    log "Image: ${super_img}"
    log "Target: ${SUPER_BLOCK}"

    # Try fastboot method first (more reliable)
    if command -v fastboot >/dev/null 2>&1; then
        log "Fastboot available. You can flash manually:"
        log "  fastboot flash super ${super_img}"
        log "  fastboot reboot"
    fi

    # Direct dd flash (works if bootloader is unlocked and partition is writable)
    log "Attempting direct flash..."
    if blockdev --setrw "${SUPER_BLOCK}" 2>/dev/null; then
        log "Set super block to RW"
    fi

    if dd if="${super_img}" of="${SUPER_BLOCK}" bs=1M 2>/dev/null; then
        log "Super partition flashed successfully!"
        return 0
    fi

    log "Direct flash failed. Please flash manually via fastboot!"
    log "  fastboot flash super ${super_img}"
    log "After flashing, wipe data and reboot."
    return 1
}

ro2rw_convert() {
    local extra_size="${1:-0}"
    local do_dfe="${2:-0}"
    local skip_backup="${3:-0}"

    log "============================================"
    log "  RO2RW - Super Partition Conversion"
    log "============================================"

    # Dump super
    local super_img
    super_img=$(ro2rw_dump_super)

    # Backup original (skippable — useful when re-running after a failed attempt
    # and the original dump already exists on the SD card)
    local backup_img="${BACKUPDIR}/super_backup.img"
    if [ "${skip_backup}" = "1" ]; then
        log "Skipping backup (--skip-backup requested)"
    elif [ -f "${backup_img}" ]; then
        echo -n "Backup already exists at ${backup_img}. Overwrite? [y/N]: "
        read -r _bak_ans
        case "${_bak_ans}" in
            [Yy]*) log "Backing up original super to ${backup_img}..."
                   cp "${super_img}" "${backup_img}"
                   log "Backup created" ;;
            *)     log "Keeping existing backup." ;;
        esac
    else
        log "Backing up original super to ${backup_img}..."
        cp "${super_img}" "${backup_img}"
        log "Backup created"
    fi

    # Get metadata
    local metadata
    metadata=$(ro2rw_get_lp_metadata "${super_img}")

    # Parse original partition sizes from lpdump metadata
    local orig_sizes
    orig_sizes=$(ro2rw_get_orig_sizes "${metadata}")

    # Extract partitions
    local extract_dir
    extract_dir=$(ro2rw_extract_partitions "${super_img}")

    # Convert to RW (and optionally DFE)
    ro2rw_convert_to_rw "${extract_dir}" "${do_dfe}" "${orig_sizes}"

    # If DFE was requested, patch boot images too
    if [ "${do_dfe}" = "1" ]; then
        dfe_patch_boot_images
        dfe_hide_encrypted_flag
    fi

    # Build new super
    local new_super
    new_super=$(ro2rw_build_new_super "${extract_dir}" "${metadata}" "${orig_sizes}")

    log "RO2RW conversion complete!"
    log "New super image: ${new_super}"
    log "Backup: ${backup_img}"
    echo "${new_super}"
}

###############################################################################
# Main Execution
###############################################################################
main() {
    # Check root
    if [ "$(id -u)" -ne 0 ]; then
        echo "FATAL: This script must be run as root (su)"
        exit 1
    fi

    # Initialize workspace based on user choice
    setup_workspace

    log "============================================"
    log "  DFE + RO2RW Universal Script"
    log "  Starting at $(date)"
    log "============================================"

    # Setup
    get_current_slot
    find_super_block
    setup_binaries

    # Ask about backup before showing main menu
    _skip_backup="0"
    if [ -f "${BACKUPDIR}/super_backup.img" ]; then
        echo ""
        echo "Existing backup found: ${BACKUPDIR}/super_backup.img"
        echo -n "Skip backup step to save time? [Y/n]: "
        read -r _skip_ans
        case "${_skip_ans}" in
            [Nn]*) _skip_backup="0" ;;
            *)     _skip_backup="1" ;;
        esac
    else
        echo ""
        echo -n "Skip backup step? (not recommended for first run) [y/N]: "
        read -r _skip_ans
        case "${_skip_ans}" in
            [Yy]*) _skip_backup="1" ;;
            *)     _skip_backup="0" ;;
        esac
    fi

    # Menu
    echo ""
    echo "============================================"
    echo "  DFE + RO2RW Tool"
    echo "============================================"
    echo "  1) Disable Force Encryption (DFE only)"
    echo "  2) RO2RW (convert super to read-write)"
    echo "  3) DFE + RO2RW (both)"
    echo "  4) Flash existing RW super image"
    echo "  5) Restore original super from backup"
    echo "  6) Exit"
    echo "============================================"
    echo -n "Select option [1-6]: "

    read -r choice

    case "${choice}" in
        1)
            dfe_disable_encryption_live
            log "DFE completed. Reboot recommended."
            ;;
        2)
            ro2rw_convert "0" "0" "${_skip_backup}"
            log "RO2RW completed. Flash the new super and reboot."
            ;;
        3)
            log "Starting DFE + RO2RW..."
            ro2rw_convert "0" "1" "${_skip_backup}"
            log "Both DFE and RO2RW completed."
            log "Flash the new super image and reboot."
            ;;
         4)
            _img_list=""
            _img_count=0
            for _img in "${OUTPUTDIR}"/super_rw*.img; do
                if [ -f "${_img}" ]; then
                    _img_count=$((_img_count + 1))
                    _img_list="${_img_list}${_img_list:+ }${_img}"
                    echo "  ${_img_count}) ${_img} ($(${BB} du -h "${_img}" | ${BB} awk '{print $1}'))"
                fi
            done
            if [ "${_img_count}" -eq 0 ]; then
                log "No RW super images found in ${OUTPUTDIR}"
                log "Please place the image file in ${OUTPUTDIR}"
            else
                echo -n "Select image [1-${_img_count}]: "
                read -r _img_choice
                _idx=0
                _chosen=""
                IFS=' '
                for _img in ${_img_list}; do
                    _idx=$((_idx + 1))
                    if [ "${_idx}" -eq "${_img_choice}" ] 2>/dev/null; then
                        _chosen="${_img}"
                        break
                    fi
                done
                if [ -n "${_chosen}" ]; then
                    ro2rw_flash_super "${_chosen}"
                else
                    log "Invalid selection: ${_img_choice}"
                fi
            fi
            unset _img_list _img_count _img _img_choice _idx _chosen
            ;;
        5)
            if [ -f "${BACKUPDIR}/super_backup.img" ]; then
                log "Restoring original super from backup..."
                ro2rw_flash_super "${BACKUPDIR}/super_backup.img"
            else
                log "No backup found at ${BACKUPDIR}/super_backup.img"
            fi
            ;;
        6)
            log "Exiting."
            exit 0
            ;;
        *)
            die "Invalid option: ${choice}"
            ;;
    esac

    log "============================================"
    log "  Script completed at $(date)"
    log "  Log: ${LOGFILE}"
    log "============================================"
}

main "$@"
