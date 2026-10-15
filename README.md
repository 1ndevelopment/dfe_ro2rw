# DFE + RO2RW Universal Script

A universal shell script for rooted Android 10+ devices that **disables force encryption (DFE)** and converts **read-only (RO) dynamic super partitions to read-write (RW)**.

It handles extraction, conversion, patching, and repacking of dynamic partitions automatically, directly on the device.

---

## ⚠️ Disclaimer

**Use this script at your own risk.** Modifying the `super` partition or disabling encryption can cause bootloops, data loss, or a soft-bricked device. Make sure you have a way to recover (e.g., Fastboot, custom recovery, or a stock ROM flashing tool) and back up important data before proceeding.

---

## Features

- **Disable Force Encryption (DFE):**
  - Live-patches `fstab` and `.rc` files across `vendor`, `system`, and other partitions.
  - Patches boot image ramdisks (`boot`, `vendor_boot`, `init_boot`).
  - Hides encryption flags so the system does not re-encrypt `/data`.
- **RO2RW (read-only to read-write):**
  - Dumps the existing `super` partition.
  - Extracts logical partitions (e.g., `system`, `vendor`, `product`).
  - Converts read-only filesystems such as **EROFS** and **F2FS** into read-write **EXT4** images.
  - Tunes EXT4 partitions that are already EXT4 but mounted read-only.
  - Repacks a new read-write capable `super` partition image.
- **Combined DFE + RO2RW:** runs both procedures in one go.
- **Standalone execution:** ships with the required binaries (`lpdump`, `lpmake`, `lpunpack`, `magiskboot`, `make_ext4fs`, `erofs`, etc.) and runs natively on Android via shell.
- **Workspace flexibility:** choose the working directory (internal `/data`, internal storage `/sdcard`, or an external MicroSD card) so you have enough free space.
- **Built-in backup and restore:** automatically backs up the original `super` image and can restore it if needed.

---

## Requirements

1. **Root access:** Magisk or KernelSU must be installed.
2. **Android 10+:** the device must use dynamic partitions (`super` partition).
3. **Architecture:** supports `arm64` and `arm32` devices (place the matching `arm64`/`arm32` directory with binaries next to the script). Also runs on Termux and regular `x86_64` Linux shells (uses host system tools where bundled binaries are absent; Android-only steps such as live DFE and direct flashing are skipped with a message there — use image-file mode, see below).
4. **Storage space:** you need enough free storage to dump and rebuild the `super` partition. At least **10GB to 15GB** free is recommended, depending on your device's `super` partition size.

---

## Usage Instructions

1. **Transfer files to the device:**
   Push the `dfe_ro2rw.sh` script and the accompanying `arm64`/`arm32` directories to the device. `/data/local/tmp` is recommended for speed and permission stability.
   ```bash
   adb push . /data/local/tmp/dfe_ro2rw
   adb shell
   ```

2. **Run as root:**
   ```bash
   su
   cd /data/local/tmp/dfe_ro2rw
   sh dfe_ro2rw.sh
   ```

3. **Follow the interactive menu:**
   First choose a workspace storage location — pick the one with the most free space.

   Then the main menu appears:
   ```text
     DFE + RO2RW Tool
     ==========================================

       1) Disable Force Encryption (DFE only)
       2) RO2RW (convert super to read-write)
       3) DFE + RO2RW (both)

       4) Flash existing RW super image
       5) Restore original super from backup

       6) Exit
   ```
   Select the option you want.

### Running on Termux / regular Linux (image-file mode)

On non-Android shells there are no `/dev/block` devices, so point the script
at a dumped super image instead of a block device:

```bash
sh dfe_ro2rw.sh /path/to/super.img
# equivalent: SUPERRW_SUPER_IMG=/path/to/super.img sh dfe_ro2rw.sh
```

Optional environment overrides:

| Variable | Effect |
|---|---|
| `SUPERRW_TMPDIR` | Workspace root (default: `/data/local/tmp/superrw` on Android, `$PREFIX/tmp/superrw` on Termux, `/tmp/superrw` on Linux) |
| `SUPERRW_SUPER_IMG` | Super image file to work on (same as passing it as the first argument) |
| `SUPERRW_SUPER_BLOCK` | Explicit super block device (Android) |
| `SUPERRW_NONINTERACTIVE` | Skip the interactive workspace prompt, use defaults |

Notes: root is only required on Android (Linux warns and continues).
Android-only steps (live DFE, boot-image patching, direct `dd` flashing)
are skipped off-device — flash the produced image with
`fastboot flash super super_rw.img` instead.

### Menu Options Explained

- **Option 1 (DFE only):** modifies the currently booted system to disable encryption. Reboot after completion. If the device was previously encrypted, you may need to format data via recovery first.
- **Option 2 (RO2RW):** builds a new `super_rw.img` file without changing encryption. Flash it with Option 4 or manually via Fastboot (`fastboot flash super super_rw.img`).
- **Option 3 (DFE + RO2RW):** converts the system to RW and applies DFE patches to the newly built image at the same time.
- **Option 4 (Flash image):** scans the workspace for generated `super_rw.img` files and flashes via `dd`. *(If `dd` fails because partitions are locked, reboot to fastboot/bootloader and flash manually.)*
- **Option 5 (Restore):** restores the `super_backup.img` created during Option 2 or 3.

---

## Flashing the Patched Super

The build step only creates the image — it does not flash it. The result is
`<workspace>/output/super_rw.img`, with the original kept at
`<workspace>/backup/super_backup.img` (workspace depends on what you picked,
e.g. `/data/local/tmp/superrw`, `/sdcard/superrw`, or `<sdcard>/superrw`).

Pick one method:

### 1. On-device flash (Option 4)

1. Run the script again and choose **4) Flash existing RW super image**.
2. Select the `super_rw.img` from the list (it scans `<workspace>/output/super_rw*.img`).
3. Confirm the overwrite prompt (`[y/N]`). The script sets the super block
   read-write if possible and writes with `dd`.
4. If `dd` fails (locked partition), fall back to Fastboot below.

To revert, choose **5) Restore original super from backup** — it flashes
`super_backup.img` through the same path.

### 2. Manual Fastboot flash (required off-device, fallback on-device)

Use this when `dd` fails, or when you built the image on Termux / Linux.
Copy `super_rw.img` to your PC first (`adb pull` / USB), then:

```bash
fastboot flash super super_rw.img
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
fastboot reboot
```

The `vbmeta` step matches what the script prints when patching boot images
with verification enabled — skip it only if you know your setup does not
need it. After flashing, wipe `/data` (Format Data in recovery) if this is
your first boot with DFE on a previously encrypted device, then reboot.

---

## Troubleshooting

- **"Could not find super partition block device":** the device may not use standard dynamic partitions, or the block mapping is non-standard.
- **Out of space / No space left on device:** dumping and rebuilding the `super` partition takes 4GB–8GB or more. Use an external MicroSD card as the workspace if internal storage is full.
- **Bootloop after flashing:**
  - If you applied DFE on a previously encrypted device, wipe `/data` (Format Data).
  - Re-flash the original super backup via Fastboot: `fastboot flash super super_backup.img`.

---

## Credits & Acknowledgements

This script builds on concepts and tools from community projects:
- **DFE-NEO v2** by leegarchat
- **SystemRW / RO2RW** by lebigmac1
- **SuperRW** by munjeni
- Utilities such as `magiskboot` (topjohnwu), `lpmake`/`lpunpack` (AOSP/LonelyHacking), and standard Android build tools.
