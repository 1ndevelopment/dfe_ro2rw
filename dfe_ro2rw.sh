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
    
    # Initialize log file
    > "${LOGFILE}"
    log "Workspace initialized at ${TMPDIR}"
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

    local patterns="fileencryption= forceencrypt= forcefdeorfbe= encryptable= metadata_encryption= keydirectory= inlinecrypt quota wrappedkey"
    for pattern in ${patterns}; do
        if grep -q "${pattern}" "${fstab_file}" 2>/dev/null; then
            log "  Removing: ${pattern}"
            sed -i "s/[[:space:]]${pattern}[^[:space:]]*//g" "${fstab_file}"
            sed -i "s/,${pattern}[^,]*//g" "${fstab_file}"
            patched=1
        fi
    done

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
        sed -i '/DFE-NEO/d' "${rc_file}"
        patched=1
    fi

    return ${patched}
}

dfe_patch_fstabs_in_dir() {
    local target_dir="$1"
    local search_dirs="${target_dir}/vendor/etc ${target_dir}/system/etc ${target_dir}/system/system_ext/etc ${target_dir}/product/etc ${target_dir}/odm/etc ${target_dir}/etc"
    local found=0

    log "Searching for fstab files in ${target_dir}..."

    for dir in ${search_dirs}; do
        if [ -d "${dir}" ]; then
            for fstab in $(find "${dir}" -name "fstab.*" -type f 2>/dev/null); do
                if dfe_patch_fstab "${fstab}"; then
                    found=1
                fi
            done
        fi
    done

    if [ ${found} -eq 0 ]; then
        log "No fstab files needed patching in ${target_dir}"
    fi
}

dfe_patch_rc_in_dir() {
    local target_dir="$1"
    local search_dirs="${target_dir}/vendor/etc/init ${target_dir}/vendor/etc/init/hw ${target_dir}/system/etc/init ${target_dir}/system/system_ext/etc/init ${target_dir}/product/etc/init ${target_dir}/odm/etc/init ${target_dir}/etc/init"
    local found=0

    for dir in ${search_dirs}; do
        if [ -d "${dir}" ]; then
            for rc in $(find "${dir}" -name "*.rc" -type f 2>/dev/null); do
                if dfe_patch_init_rc "${rc}"; then
                    found=1
                fi
            done
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
    dfe_patch_fstabs_in_dir ""
    dfe_patch_rc_in_dir ""
    
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
    local metadata_file="${WORKDIR}/lp_metadata.txt"

    log "Reading logical partition metadata..."
    lpdump "${super_img}" > "${metadata_file}" 2>&1 || die "lpdump failed"
    cat "${metadata_file}" >> "${LOGFILE}"
    echo "${metadata_file}"
}

ro2rw_extract_partitions() {
    local super_img="$1"
    local extract_dir="${WORKDIR}/extracted"

    mkdir -p "${extract_dir}"

    log "Extracting partitions from super image..."
    lpunpack "${super_img}" "${extract_dir}" 2>&1 | log || {
        log "lpunpack encountered issues, checking extracted files..."
    }

    log "Extracted partitions:"
    ls -la "${extract_dir}" >> "${LOGFILE}"
    ls -1 "${extract_dir}" 2>/dev/null | log

    echo "${extract_dir}"
}

ro2rw_convert_to_rw() {
    local extract_dir="$1"
    local do_dfe="$2"
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
                # Add 50% + 200MB padding for EXT4 journal, inodes, and filesystem overhead
                local new_size=$(${BB} awk -v kb="${uncompressed_kb}" -v orig="${size}" 'BEGIN { s = (kb * 1024) * 1.50 + 209715200; if (s < orig) s = orig; printf "%.0f\n", s }')
                
                # Create a raw ext4 image (not sparse) to mount and modify it
                local raw_img="${extract_dir}/${name%.*}.raw.ext4"
                make_ext4fs -l "${new_size}" "${raw_img}" "${mnt_point}" >"${WORKDIR}/_mkfs_${name%.*}.log" 2>&1 && _mkok=0 || _mkok=$?
                cat "${WORKDIR}/_mkfs_${name%.*}.log" | log || true
                if [ ${_mkok} -ne 0 ]; then
                    log "  make_ext4fs failed, trying alternate method for ${name}..."
                    rm -f "${raw_img}"
                    # Create empty ext4, then mount and copy files from EROFS
                    make_ext4fs -l "${new_size}" "${raw_img}" >"${WORKDIR}/_mkfs_${name%.*}.log" 2>&1 && _mkok=0 || _mkok=$?
                    cat "${WORKDIR}/_mkfs_${name%.*}.log" | log || true
                    if [ ${_mkok} -eq 0 ] && [ -f "${raw_img}" ]; then
                        local ext4_mnt="${WORKDIR}/ext4_${name}"
                        mkdir -p "${ext4_mnt}"
                        local loop_dev2=$(losetup -f 2>/dev/null || true)
                        if [ -n "${loop_dev2}" ]; then
                            losetup "${loop_dev2}" "${raw_img}" 2>/dev/null || true
                            if mount -t ext4 -o rw "${loop_dev2}" "${ext4_mnt}" 2>/dev/null || mount -o rw "${loop_dev2}" "${ext4_mnt}" 2>/dev/null; then
                                log "  Copying files from EROFS into ext4 image..."
                                ${BB} cp -a "${mnt_point}/." "${ext4_mnt}/" 2>&1 | log || true
                                sync
                                umount -fl "${ext4_mnt}" 2>/dev/null || true
                                _mkok=0
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

                if [ "${do_dfe}" = "1" ]; then
                    local rw_mnt="${WORKDIR}/rw_${name}"
                    mkdir -p "${rw_mnt}"
                    if mount -o loop,rw "${raw_img}" "${rw_mnt}" 2>/dev/null; then
                        log "  Applying DFE to ${name}..."
                        dfe_patch_fstabs_in_dir "${rw_mnt}"
                        dfe_patch_rc_in_dir "${rw_mnt}"
                        umount -fl "${rw_mnt}" 2>/dev/null || true
                    else
                        log "  Failed to mount ${raw_img} RW for DFE patching"
                    fi
                    rm -rf "${rw_mnt}"
                fi

                local new_img="${extract_dir}/${name%.*}.ext4.img"
                if [ -f "${raw_img}" ]; then
                    img2simg "${raw_img}" "${new_img}" 2>&1 | log || ${BB} mv -f "${raw_img}" "${new_img}"
                    rm -f "${raw_img}"
                    # Replace original
                    ${BB} mv -f "${new_img}" "${img}"
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
                # Add 10% + 50MB padding
                local new_size=$(${BB} awk -v kb="${uncompressed_kb}" 'BEGIN { printf "%.0f\n", (kb * 1024) * 1.10 + 52428800 }')
                
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

                    local new_img="${extract_dir}/${name%.*}.ext4.img"
                    img2simg "${raw_img}" "${new_img}" 2>&1 | log || ${BB} mv -f "${raw_img}" "${new_img}"
                    rm -f "${raw_img}"

                    ${BB} mv -f "${new_img}" "${img}"
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
                    # Add 10% + 50MB padding to ensure make_ext4fs has room
                    local new_size=$(${BB} awk -v s="${size}" 'BEGIN { printf "%.0f\n", s + s/10 + 52428800 }')
                    
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

                        local new_img="${extract_dir}/${name%.*}.rw.img"
                        img2simg "${raw_img}" "${new_img}" 2>&1 | log || ${BB} mv -f "${raw_img}" "${new_img}"
                        rm -f "${raw_img}"

                        ${BB} mv -f "${new_img}" "${img}"
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

ro2rw_build_new_super() {
    local extract_dir="$1"
    local metadata_file="$2"
    local new_super="${OUTPUTDIR}/super_rw.img"
    local metadata_info
    metadata_info=$(lpdump "${OUTPUTDIR}/super_original.img" 2>&1 | grep -E "(super partition name:|block device-size:|partition size:|Partition name|Group name|Metadata max size|Metadata slot count|Block size)")

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

    # Determine partition arrangement from lpdump
    local partitions=""
    local image_args=""
    for img in "${extract_dir}"/*.img; do
        local name
        name=$(${BB} basename "${img}" .img)
        local size
        size=$(${BB} stat -c%s "${img}" 2>/dev/null)
        # lpmake expands sparse images internally, so we must use the raw
        # (uncompressed) size for --partition, not the sparse file size.
        local _rawsz="${WORKDIR}/_rawsize_${name}.img"
        simg2img "${img}" "${_rawsz}" 2>/dev/null && size=$(${BB} stat -c%s "${_rawsz}" 2>/dev/null) || true
        rm -f "${_rawsz}"

        # Strip suffix if A/B
        local base_name="${name}"
        local group_name="default"

        # Determine group from original metadata
        local orig_group
        orig_group=$(${BB} grep -B1 "${name}" "${metadata_file}" 2>/dev/null | ${BB} grep "Group name" 2>/dev/null | ${BB} awk '{print $NF}' || true)
        if [ -z "${orig_group}" ]; then
            orig_group="${group_name}"
        fi

        partitions="${partitions} --partition ${base_name}:none:${size}:${orig_group}"
        image_args="${image_args} --image ${base_name}=${img}"
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

    local cmd="lpmake ${lp_args} ${group_args} ${partitions}${image_args}"
    log "lpmake command: ${cmd}"
    echo "${cmd}" > "${WORKDIR}/lpmake_cmd.txt"

    # Verify all image files exist before running lpmake
    for _vimg in "${extract_dir}"/*.img; do
        if [ ! -f "${_vimg}" ]; then
            die "Image file not found for lpmake: ${_vimg}"
        fi
    done

    # Execute lpmake
    ${cmd} --output "${new_super}" 2>&1 | log || {
        log "lpmake failed, trying alternative approach..."

        # Fallback: try with default group and minimal metadata
        local fallback_cmd="lpmake --device-size ${total_size} --metadata-size 65536 --metadata-slots 3 --block-size 4096 --super-name ${super_name}"
        local fallback_image_args=""
        for img in "${extract_dir}"/*.img; do
            local name
            name=$(${BB} basename "${img}" .img)
            local size
            size=$(${BB} stat -c%s "${img}" 2>/dev/null)
            fallback_cmd="${fallback_cmd} --partition ${name}:none:${size}:default"
            fallback_image_args="${fallback_image_args} --image ${name}=${img}"
        done
        fallback_cmd="${fallback_cmd}${fallback_image_args}"
        log "Fallback: ${fallback_cmd}"
        ${fallback_cmd} --output "${new_super}" 2>&1 | log || {
            log "lpmake failed on SD card paths, retrying with internal storage..."
            local local_img_dir="/data/local/tmp/superrw/lpmake_images"
            rm -rf "${local_img_dir}"
            mkdir -p "${local_img_dir}"
            cp "${extract_dir}"/*.img "${local_img_dir}/" < /dev/null 2>&1 | log || true
            local local_cmd="lpmake --device-size ${total_size} --metadata-size 65536 --metadata-slots 3 --block-size 4096 --super-name ${super_name}"
            for img in "${local_img_dir}"/*.img; do
                local name
                name=$(${BB} basename "${img}" .img)
                local size
                size=$(${BB} stat -c%s "${img}" 2>/dev/null)
                local_cmd="${local_cmd} --partition ${name}:none:${size}:default --image ${name}=${img}"
            done
            log "Local lpmake: ${local_cmd}"
            ${local_cmd} --output "${new_super}" 2>&1 | log || die "lpmake failed even with local images"
        }
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

    log "============================================"
    log "  RO2RW - Super Partition Conversion"
    log "============================================"

    # Dump super
    local super_img
    super_img=$(ro2rw_dump_super)

    # Backup original
    local backup_img="${BACKUPDIR}/super_backup.img"
    log "Backing up original super to ${backup_img}..."
    cp "${super_img}" "${backup_img}"
    log "Backup created"

    # Get metadata
    local metadata
    metadata=$(ro2rw_get_lp_metadata "${super_img}")

    # Extract partitions
    local extract_dir
    extract_dir=$(ro2rw_extract_partitions "${super_img}")

    # Convert to RW (and optionally DFE)
    ro2rw_convert_to_rw "${extract_dir}" "${do_dfe}"

    # If DFE was requested, patch boot images too
    if [ "${do_dfe}" = "1" ]; then
        dfe_patch_boot_images
        dfe_hide_encrypted_flag
    fi

    # Build new super
    local new_super
    new_super=$(ro2rw_build_new_super "${extract_dir}" "${metadata}")

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
            ro2rw_convert "0" "0"
            log "RO2RW completed. Flash the new super and reboot."
            ;;
        3)
            log "Starting DFE + RO2RW..."
            ro2rw_convert "0" "1"
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
