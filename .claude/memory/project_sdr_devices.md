---
name: project-sdr-devices
description: "IP addresses, MACs, and access methods for the two SDR boards in the lab"
metadata: 
  node_type: memory
  type: project
  originSessionId: ff255f27-aaa3-4d32-92b8-9ecb337f101b
---

Two SDR boards on the home LAN (192.168.1.0/24, TP-Link router at 192.168.1.1):

**ZedBoard** (Zynq-7000 + AD9361)
- IP: 192.168.1.110 (static via dhcpcd.conf)
- MAC: 00:0a:35:00:01:23 (overridden via /etc/systemd/network/10-eth0-mac.link; hardware MAC is 00:0a:35:00:01:22)
- Serial: /dev/ttyACM0, 115200 8N1, already logged in as root
- SSH: root@192.168.1.110, password: (redacted — same as Pluto+, ask Pari; no SSH key set up as of 2026-07-19)
- OS: Yocto/ADI Linux (systemd, dhcpcd)

**Pluto+** (Chinese clone of ADALM-PLUTO, Zynq-7010 + AD9361, has Ethernet + SD card)
- IP (Ethernet): 192.168.1.50 (static via fw_setenv ipaddr_eth — changed 2026-08-01, was .102, see conflict note below)
- IP (USB tunnel): 192.168.2.1 (always available when USB connected)
- MAC: 00:0a:35:00:01:22
- SSH: root@192.168.1.50 or root@192.168.2.1, password confirmed working 2026-08-01 (same as ZedBoard's Kuiper rootfs — ask Pari; not stored here, see [[project_adi_hdl_git_tracking]] for why)
- SSH host key: `SHA256:ZfuqQpjXt2HRRUfiSrc4uNLBZ/ScacJW+fMgTnG/VmE` (same on both interfaces — confirms it's genuinely Pluto+ on both)
- OS: Buildroot (sysvinit, udhcpc), ADI firmware

**IP conflict discovered and fixed (2026-08-01):** `192.168.1.102` (Pluto+'s old static IP) was silently being answered by a **different device** on the LAN — Windows's ARP table showed it mapped to MAC `7a-7a-db-da-39-bf`, nothing like Pluto+'s real MAC. The router's DHCP pool was handing that same address out to some other device with no awareness of Pluto+'s static claim outside DHCP. Every ping/SSH attempt to `.102` was silently hitting the wrong device (ping succeeded, SSH got a real TCP RST — both from the impostor, not Pluto+). **Diagnosed via the USB tunnel** (`192.168.2.1`, always reachable independent of this bug) — confirmed `eth0` itself was correctly configured (`ip addr show` matched expected IP/MAC, `dropbear` listening on `0.0.0.0:22`), so the bug was purely an LAN-level address collision, not anything wrong on the board. **Fix:** moved to `192.168.1.50` (below the `.100+` range we've seen the router actually hand out via DHCP to the ZedBoard), applied live (`ip addr flush/add`) and persisted (`fw_setenv ipaddr_eth`). Verified via matching SSH host key fingerprint on both the new Ethernet IP and the known-good USB tunnel IP. **If Pluto+ ever becomes unreachable again, don't assume it's the board** — check `arp -a` on the Windows side first for a MAC mismatch before touching any board config, and use the USB tunnel (`192.168.2.1`) as a fallback path to diagnose from inside.

**Why:** Set up during first session. Both boards had the same default Xilinx MAC (00:0a:35:00:01:22) causing ARP conflicts — ZedBoard's MAC was overridden at the OS layer.

## ZedBoard SD card failing (discovered 2026-07-19) — check before trusting any ZedBoard test result

`dmesg` on the ZedBoard shows widespread I/O errors on `mmcblk0` (the SD card) across many unrelated sectors (e.g. 13072997-13073004, 13073024-13073031, 13117288-13117297, 19602284-19602293, 12997290-12997295), not a single bad-block event. Symptoms observed: `/tmp` got kernel-remounted read-only, a plain `mount` command segfaulted, and a background shell command we ran also segfaulted (SIGSEGV) — consistent with corrupted binaries/libraries being read off the failing card, not a code or JTAG-bitstream issue.

**This happened AFTER we had already successfully JTAG-programmed and validated `system_top.bit` via `iio_info -s`** (see [[project_fpga_gmsk_plan]]) and successfully compiled `tx_dma_fsk` and `rx.c` natively on the board — so the card degraded/failed sometime during that same working session, not because of anything we did.

**Status as of last check:** not yet resolved. Next step was to power-cycle and re-check `dmesg` for a clean boot (rules out transient contact issue) — if errors return, the SD card likely needs re-imaging/replacement before further ZedBoard work (Linux/libiio side; the Vivado/JTAG bitstream flow is independent of this card and unaffected).

**How to apply:** Before trusting ANY ZedBoard test result (RX demod validation, TX/RX role-swap test, future GMSK IP bring-up), first check `dmesg | tail -60` on 192.168.1.110 for fresh `I/O error, dev mmcblk0` lines. If present, stop and address the SD card first — do not attribute software/RF failures to code bugs until storage health is confirmed.

**Pari has seen this exact failure before** and fixed it by reflashing the SD card — recurring, so worth tracking. Plan (as of 2026-07-19): replace with a **SanDisk High Endurance or Industrial** card (not a plain consumer card — scattered bad-sector I/O errors like this are a classic symptom of consumer/counterfeit cards under embedded Linux's constant small journal/log writes). 8-32GB is plenty for the Yocto rootfs.

**If it recurs a third time after a good-quality card**, stop assuming "just a bad card" and check: (1) power supply — voltage sag during SD writes (especially concurrent with RF/AD9361 activity) can corrupt writes without the card being at fault, make sure the original ADI/Digilent-rated adapter is used; (2) physically reseat/clean the microSD slot contacts — worn/dusty contacts produce identical intermittent-I/O-error symptoms.

**Reflashing does NOT affect the Vivado/JTAG side of the FPGA GMSK project** ([[project_fpga_gmsk_plan]]) — the SD card only holds the base ADI Yocto image + stock bitstream; our custom `system_top.bit` is delivered via JTAG on top regardless of what's on the card, since no persistent `BOOT.BIN` has been built yet. Just re-run the JTAG program step after reflashing. Important: use an ADI Yocto image release that matches/is compatible with `hdl_2026_r1`'s expected kernel/FSBL generation to avoid version-mismatch symptoms that look unrelated to the card.

### Reflash executed (2026-07-19)

- New card: **SanDisk Extreme 256GB microSDXC** (V30/U3/A2) — genuine, high-quality, confirmed adequate.
- Image: ADI's official **Kuiper universal image**, `2025-03-18-ADI-Kuiper-full.img` (~9.6GB), from `C:\Users\Parit\Downloads\image_2025-03-18-ADI-Kuiper-full\`. One shared rootfs/image across many ADI eval boards (Zynq, ZynqMP, Cyclone, Arria, Versal, even Raspberry Pi) with per-board subfolders on the FAT boot partition.
- **BalenaEtcher gotcha:** hit a known Etcher bug — `Error: (0, h.requestMetadata) is not a function` when opening the raw `.img` (an Etcher-internal regression, not a corrupt download — re-downloading doesn't help). **Switched to Rufus instead**, using **DD Image mode** (not ISO mode — ISO mode would misinterpret the raw disk image). Rufus wrote it successfully.
- Flashed card mounts on Windows as **D:\** (FAT boot partition only — the ext4 rootfs partition, `/dev/mmcblk0p2`, isn't Windows-readable).
- **Board-specific setup required after flashing (Kuiper images always need this):** copy the right board's `BOOT.BIN` + `devicetree.dtb` from the per-board subfolder into the root of the boot partition. For this ZedBoard (AD9361, `fmcomms2/zed` design), the matching folder was `zynq-zed-adv7511-ad936x-fmcomms2-3-4` (top level has `BOOT.BIN` shared across AD9361/AD9364 variants; the AD9361-specific `devicetree.dtb` is one level deeper in `zynq-zed-adv7511-ad9361-fmcomms2-3\`). Do **not** use the `ad9364-fmcomms4` subfolder — that's for Pluto+-style AD9364 hardware, not this ZedBoard.
- Copied `D:\zynq-zed-adv7511-ad936x-fmcomms2-3-4\BOOT.BIN` → `D:\BOOT.BIN` and `D:\zynq-zed-adv7511-ad936x-fmcomms2-3-4\zynq-zed-adv7511-ad9361-fmcomms2-3\devicetree.dtb` → `D:\devicetree.dtb`.
- Verified `D:\uEnv.txt` (`adi_sdboot`) loads `${kernel_image}`/`${devicetree_image}`/`${ramdisk_image}` from the FAT partition by u-boot env variable name (defaults baked into this `BOOT.BIN`, expected to resolve to `devicetree.dtb` — the filename we placed), and boots rootfs from `bootargs=... root=/dev/mmcblk0p2 ... rootfstype=ext4` — consistent with the DD-mode write.
### Reflash confirmed working, board back up (2026-07-19)

**Boot problem hit first, now resolved:** after the reflash, the board dropped to the `Zynq>` U-Boot prompt instead of booting Linux. Root cause: the Kuiper image's board-specific folder (`zynq-zed-adv7511-ad936x-fmcomms2-3-4`) only supplies `BOOT.BIN` + `devicetree.dtb` — those alone aren't enough. `adi_sdboot` (in `uEnv.txt`) also needs a generic Zynq kernel file named `uImage` at the FAT partition root, which lives in the separate **`zynq-common/`** folder and must be copied over too. This is a general Kuiper-image gotcha, not specific to this board — worth remembering for any future ADI Kuiper card setup (Pluto+, other Zynq boards, etc.): copy `<board-folder>/BOOT.BIN` + `<board-folder>/<chip-subfolder>/devicetree.dtb` **and** `zynq-common/uImage` (or the matching `<arch>-common` kernel) to the boot partition root.

**Fixed live over the serial console (COM5, 115200 8N1) without needing to eject the card**, using U-Boot's own `fatload`/`fatwrite` commands: loaded `zynq-common/uImage` into RAM then wrote it back out to the FAT root as `uImage`. `run adi_sdboot` afterward booted cleanly to a full Linux prompt.

**Confirmed clean boot — SD card fix worked:** no `mmcblk0` I/O errors anywhere in the full boot log, root ext4 filesystem (`mmcblk0p2`) mounted without error. The SanDisk Extreme 256GB card is healthy. (One cosmetic red herring: "Failed to start Load Kernel Modules" appears in the log — this also appeared on the OLD failing card, so it's an unrelated generic config issue, not a disk-health symptom — don't mistake it for one again.)

**MAC conflict confirmed as the actual root cause of the "duplicate IP" symptom Pari saw:** this fresh Kuiper rootfs has no `/etc/systemd/network/10-eth0-mac.link` override (that lived on the old, now-replaced rootfs) — so `eth0` came up on the stock hardware MAC `00:0a:35:00:01:22`, identical to Pluto+'s MAC. The "192.168.1.104" IP Pari found on the TP-Link page was the live ZedBoard itself under this shared MAC, not a stale lease. **Fixed:** recreated `/etc/systemd/network/10-eth0-mac.link` (same content as before — match `...:22`, override to `...:23`) for persistence across reboots, AND applied it live via `ip link set dev eth0 down/address/up` + `dhclient -r`/`dhclient` so it took effect immediately without a reboot.

**Current ZedBoard IP is now 192.168.1.106** (DHCP-assigned, distinct MAC `00:0a:35:00:01:23`) — **not** the old static `192.168.1.110** anymore, since the dhcpcd static-IP config from the old rootfs doesn't exist on this fresh image. Update SSH commands/scripts to use `.106` until/unless a static IP is reconfigured. Pluto+ remains at `192.168.1.102`, unaffected.

**Verified via SSH (2026-07-19):** `root@192.168.1.106`, password (redacted — see correction below), new SSH host key `SHA256:BNeiBArC949eFL23J+no8BfYq6rHikzDuaLiaiMuIzo` (fresh image regenerates host keys, expect a "key not cached" prompt once). `iio_info -s` confirms `ad9361-phy`, `cf-ad9361-dds-core-lpc`, `cf-ad9361-lpc`, `ad7291`, `xadc` all present and healthy.

**Password correction (2026-07-25):** the fresh Kuiper rootfs's root password is actually DIFFERENT from the old rootfs/Pluto+ password noted above — confirmed working via plink during Step 0 register-test verification (redacted here too — ask Pari). Don't assume "same as Pluto+" for this board anymore.

**ZedBoard IP changed again (2026-07-26): now `192.168.1.104`**, confirmed by matching its known overridden MAC `00:0a:35:00:01:23` in the ARP table after a subnet ping-sweep (`.106` stopped responding after today's JTAG reprogram + power cycles — exactly the "will likely change again on next reboot" outcome outstanding item #1 already warned about). SSH host key and password unchanged, just the IP. Pluto+ unaffected, still `192.168.1.102`. **This will keep happening on every reboot until static IP is configured (still outstanding) — always verify the current IP via ARP/MAC match rather than assuming the last-recorded one still holds.**

**Still outstanding:**
1. Consider restoring a static-IP config (dhcpcd.conf, matching the old `.110` setup) for consistency across future reboots — not yet done, DHCP IP keeps changing on every reboot (`.106` → `.104` as of 2026-07-26).
2. **Re-run the JTAG program step** (`fmcomms2_zed.runs\impl_1\system_top.bit` via Vivado Hardware Manager) — this fresh Kuiper image's stock `BOOT.BIN` bitstream is `hdl_2023_r2` (per `axi_sysid`, built 2024-11-01), NOT our timing-fixed custom `hdl_2026_r1` build. Confirmed via serial: `ad9361-phy`, `cf-ad9361-dds-core-lpc`, `cf-ad9361-lpc` all already probe fine on this stock bitstream, so the board is fully usable for the TX/RX role-swap software test right away — the JTAG reprogram is only needed before resuming the custom GMSK IP work.
3. Resume the TX/RX role-swap test (build `tx_dma_fsk` on ZedBoard → deploy to Pluto+, build+run `rx.c` on ZedBoard) that was interrupted by the original card failure — now unblocked.

**How to apply:** Use these IPs when connecting via SSH, iio_info, GNU Radio IIO blocks, or libiio. Verify with sdr_devices.txt in /home/pari/SDR_Link/.

**ZedBoard SSH password confirmed working (2026-08-01), IP `192.168.1.104`.** Not recorded here in plaintext — these `.claude/memory/*.md` files are git-tracked and already pushed to GitHub ([[project_adi_hdl_git_tracking]]), so a literal credential here would end up committed to a remote host. Ask Pari directly each session; re-verify IP via ARP/MAC match first (see note above — it changes every reboot).
