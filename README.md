# DFE + RO2RW Universal Script

A universal shell script designed for rooted Android 10+ devices to **Disable Force Encryption (DFE)** and convert **Read-Only (RO) dynamic super partitions to Read-Write (RW)**.

This tool aims to simplify the process of making system partitions modifiable and disabling data encryption by handling the extraction, conversion, patching, and repacking of dynamic partitions automatically directly on the device.

---

## ⚠️ Disclaimer
**Use this script at your own risk.** Modifying the `super` partition or disabling encryption can result in bootloops, data loss, or a soft-bricked device. Always ensure you have a fallback method to recover your device (e.g., Fastboot, Custom Recovery, or a stock ROM flashing tool) and backup your important data before proceeding.

---

## Features

- **Disable Force Encryption (DFE)**: 
  - Live patching of `fstab` and `.rc` files across `vendor`, `system`, and other partitions.
  - Automatically patches boot image ramdisks (`boot`, `vendor_boot`, `init_boot`).
  - Hides encrypted flags to prevent the system from re-encrypting `/data`.
- **RO2RW (Read-Only to Read-Write)**: 
  - Dumps the existing `super` partition.
  - Extracts logical partitions (e.g., `system`, `vendor`, `product`).
  - Converts modern read-only file systems like **EROFS** and **F2FS** into read-write **EXT4** images.
  - Automatically handles EXT4 tuning if the partition is already EXT4 but mounted read-only.
  - Repacks a new read-write capable `super` partition image.
- **Combined DFE + RO2RW**: Run both procedures seamlessly in one go.
- **Standalone Execution**: Comes bundled with necessary binaries (`lpdump`, `lpmake`, `lpunpack`, `magiskboot`, `make_ext4fs`, `erofs`, etc.) to run natively on Android via shell.
- **Workspace Flexibility**: Select your working directory (Internal `/data`, Internal Storage `/sdcard`, or an external MicroSD card) to ensure you have enough free space for operations.
- **Built-in Backup & Restore**: Automatically backs up the original `super` image and provides an easy way to restore it if needed.

---

## Requirements

1. **Root Access**: Magisk or KernelSU must be installed.
2. **Android 10+**: Device must utilize dynamic partitions (`super` partition block).
3. **Architecture**: Supports `arm64` and `arm32` devices (ensure the respective `arm64`/`arm32` directories containing the binaries are placed next to the script).
4. **Storage Space**: You will need sufficient free storage to dump and rebuild the `super` partition. Usually, at least **10GB to 15GB** of free space is recommended, depending on your device's `super` partition size.

---

## Usage Instructions

1. **Transfer Files to Device**: 
   Push the `dfe_ro2rw.sh` script and the accompanying `arm64`/`arm32` directories to your device. Using `/data/local/tmp` is highly recommended for speed and permission stability.
   ```bash
   adb push . /data/local/tmp/dfe_ro2rw
   adb shell
   ```

2. **Execute as Root**:
   Gain root privileges and run the script.
   ```bash
   su
   cd /data/local/tmp/dfe_ro2rw
   sh dfe_ro2rw.sh
   ```

3. **Follow the Interactive Menu**:
   First, you will be prompted to choose a workspace storage location. Pick the one with the most free space.
   
   Then, you will see the main menu:
   ```text
   ============================================
     DFE + RO2RW Tool
   ============================================
     1) Disable Force Encryption (DFE only)
     2) RO2RW (convert super to read-write)
     3) DFE + RO2RW (both)
     4) Flash existing RW super image
     5) Restore original super from backup
     6) Exit
   ============================================
   ```
   Select your desired option. 

### Menu Options Explained

- **Option 1 (DFE only)**: Modifies your currently booted system to disable encryption. Reboots are recommended after completion. You may need to format data via recovery if you are transitioning from encrypted to decrypted for the first time.
- **Option 2 (RO2RW)**: Creates a new `super_rw.img` file but does not modify encryption. Once built, you can flash the image using Option 4 or manually via Fastboot (`fastboot flash super super_rw.img`).
- **Option 3 (DFE + RO2RW)**: Converts your system to RW and applies DFE patches simultaneously to the newly built image.
- **Option 4 (Flash image)**: Scans the workspace for generated `super_rw.img` files and attempts to flash it via `dd`. *(Note: If `dd` fails due to locked partitions, you must reboot to fastboot/bootloader and flash manually).*
- **Option 5 (Restore)**: Restores the `super_backup.img` created during Option 2 or 3.

---

## Troubleshooting

- **"Could not find super partition block device"**: Your device might not use standard dynamic partitions or the block mapping is non-standard.
- **Out of Space/No space left on device**: The process requires dumping the entire super partition (often 4GB-8GB) and rebuilding it. Use an external MicroSD card as the workspace if internal storage is full.
- **Bootloop after flashing**: 
  - Ensure you wiped `/data` (Format Data) if you applied DFE on a previously encrypted device.
  - Re-flash the original super partition backup via Fastboot: `fastboot flash super super_backup.img`.

---

## Credits & Acknowledgements

This script utilizes concepts and tools from various community projects:
- **DFE-NEO v2** by leegarchat
- **SystemRW / RO2RW** by lebigmac1
- **SuperRW** by munjeni
- Utilities like `magiskboot` (topjohnwu), `lpmake`/`lpunpack` (AOSP/LonelyHacking), and standard Android build tools.
