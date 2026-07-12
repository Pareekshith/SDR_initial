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
- OS: Yocto/ADI Linux (systemd, dhcpcd)

**Pluto+** (Chinese clone of ADALM-PLUTO, Zynq-7010 + AD9361, has Ethernet + SD card)
- IP (Ethernet): 192.168.1.102 (static via fw_setenv ipaddr_eth)
- IP (USB tunnel): 192.168.2.1 (always available when USB connected)
- MAC: 00:0a:35:00:01:22
- SSH: root@192.168.1.102 or root@192.168.2.1, password: analog
- OS: Buildroot (sysvinit, udhcpc), ADI firmware

**Why:** Set up during first session. Both boards had the same default Xilinx MAC (00:0a:35:00:01:22) causing ARP conflicts — ZedBoard's MAC was overridden at the OS layer.

**How to apply:** Use these IPs when connecting via SSH, iio_info, GNU Radio IIO blocks, or libiio. Verify with sdr_devices.txt in /home/pari/SDR_Link/.
