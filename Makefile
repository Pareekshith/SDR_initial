# SDR_Link Makefile
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │  BUILD STRATEGY                                                         │
# │                                                                         │
# │  tx.c  → ZedBoard (192.168.1.110)                                       │
# │          Has native gcc 10.2.1 + libiio 0.26.  Upload source, compile  │
# │          on the board, run there.  No cross-compiler needed.            │
# │                                                                         │
# │  rx.c  → Pluto+ (192.168.1.102)                                         │
# │          No gcc on device.  Cross-compile on the laptop using           │
# │          arm-linux-gnueabihf-gcc against the shared ARM sysroot.        │
# │          Deploy binary via cat-over-SSH (Pluto+ has no sftp-server).    │
# │                                                                         │
# │  ARM SYSROOT (arm-sysroot → ../AD9361_FM_radio/arm-sysroot)            │
# │    lib/arm-linux-gnueabihf/libiio.so.0.26   — runtime .so (ARM)        │
# │    usr/lib/arm-linux-gnueabihf/crt*.o        — C startup objects       │
# │    usr/include/iio.h                          — libiio 0.26 headers     │
# │    lib/arm-linux-gnueabihf/libc-2.31.so       — glibc 2.31 (Pluto+)    │
# └─────────────────────────────────────────────────────────────────────────┘

# ── Device addresses ─────────────────────────────────────────────────────────
ZEDBOARD_IP  = 192.168.1.110
PLUTO_IP     = 192.168.1.102
PLUTO_SSH    = ssh -i ~/.ssh/id_rsa_pluto -o StrictHostKeyChecking=no \
                   -o PubkeyAcceptedAlgorithms=+ssh-rsa

# ── ARM cross-compiler (apt install gcc-arm-linux-gnueabihf) ─────────────────
CROSS_CC     = arm-linux-gnueabihf-gcc
SYSROOT      = $(CURDIR)/arm-sysroot
GCC_LIBDIR   = $(shell $(CROSS_CC) --print-libgcc-file-name | xargs dirname)

# ── C runtime startup/shutdown objects from sysroot ──────────────────────────
#
# With -nostdlib the compiler links zero default startup code.
# We must supply these explicitly from the SYSROOT — not from the host —
# so the glibc version matches the Pluto+ firmware (glibc 2.31, not 2.39+).
#
SYSROOT_CRT  = $(SYSROOT)/usr/lib/arm-linux-gnueabihf/crt1.o \
               $(SYSROOT)/usr/lib/arm-linux-gnueabihf/crti.o
SYSROOT_FINI = $(SYSROOT)/usr/lib/arm-linux-gnueabihf/crtn.o

# ── Cross-compile flags for Pluto+ ───────────────────────────────────────────
#
# -D_TIME_BITS=32: Pluto+ firmware (2020 Buildroot) uses 32-bit time_t.
#   Ubuntu 26.04 defaults to 64-bit time_t.  Mismatched time_t changes the
#   size of struct iio_data_format and causes silent crashes on iio_create_*().
#
PLUTO_CFLAGS  = -Wall -O2 -std=c11 \
                -D_TIME_BITS=32 \
                --sysroot=$(SYSROOT) \
                -I$(SYSROOT)/usr/include \
                -I$(CURDIR)/common

# ── Linker flags for Pluto+ ──────────────────────────────────────────────────
#
# -nostdlib: do NOT link against the host's glibc (2.39).  We manage every
#   library explicitly so only sysroot glibc (2.31) ends up in the binary.
#
# -l:libiio.so.0 (colon): link by exact filename, resolves to libiio.so.0.26
#   in the sysroot.  Pluto+ will load libiio.so.0.26 at runtime.
#
# --allow-shlib-undefined: libiio.so.0 depends on libusb, libxml2, libavahi,
#   libserialport.  Those exist on the Pluto+ but not in our minimal sysroot.
#   The target's dynamic linker resolves them at runtime — correct behaviour.
#
# -rpath,/usr/lib: tells the Pluto+ dynamic linker where to find libiio.so.0
#   at runtime (it lives at /usr/lib/ on Pluto+).
#
PLUTO_LDFLAGS = -nostdlib \
                -L$(SYSROOT)/lib/arm-linux-gnueabihf \
                -L$(SYSROOT)/usr/lib/arm-linux-gnueabihf \
                -L$(GCC_LIBDIR) \
                -l:libiio.so.0 -lm -lc -lgcc \
                -Wl,--allow-shlib-undefined \
                -Wl,-rpath,/usr/lib

# ── ZedBoard native compile flags ────────────────────────────────────────────
ZED_CC       = gcc
ZED_CFLAGS   = -Wall -O2 -std=c11
ZED_LDFLAGS  = -liio -lm -lrt

# ─────────────────────────────────────────────────────────────────────────────

.PHONY: all help check-sysroot tx-build tx-run rx-build rx-deploy rx-run \
        rx-deploy-via-zed setup-pluto-ssh

all: help

# ── Sysroot sanity check ──────────────────────────────────────────────────────
check-sysroot:
	@test -f $(SYSROOT)/usr/include/iio.h || \
	    { echo "ERROR: sysroot missing — run: ln -sf ../AD9361_FM_radio/arm-sysroot arm-sysroot"; exit 1; }
	@test -f $(SYSROOT)/lib/arm-linux-gnueabihf/libiio.so.0.26 || \
	    { echo "ERROR: libiio.so.0.26 not in sysroot"; exit 1; }
	@test -f $(SYSROOT)/usr/lib/arm-linux-gnueabihf/crt1.o || \
	    { echo "ERROR: CRT startup objects missing from sysroot"; exit 1; }
	@echo "  Sysroot OK: $(SYSROOT)"

# ── TX: compile on the ZedBoard ──────────────────────────────────────────────
tx-build:
	@echo "────────────────────────────────────────────────────"
	@echo "  Uploading TX source to ZedBoard ($(ZEDBOARD_IP))..."
	@echo "────────────────────────────────────────────────────"
	ssh root@$(ZEDBOARD_IP) 'mkdir -p /tmp/sdrlink/common'
	cat tx/tx.c            | ssh root@$(ZEDBOARD_IP) 'cat > /tmp/sdrlink/tx.c'
	cat common/rf_params.h | ssh root@$(ZEDBOARD_IP) 'cat > /tmp/sdrlink/common/rf_params.h'
	@echo ""
	@echo "  Compiling on ZedBoard..."
	ssh root@$(ZEDBOARD_IP) \
	    'cd /tmp/sdrlink && $(ZED_CC) $(ZED_CFLAGS) -I./common -o /usr/local/bin/tx tx.c $(ZED_LDFLAGS) \
	     && echo "  OK: /usr/local/bin/tx" && file /usr/local/bin/tx'

tx-run:
	@echo "  Starting tone transmitter on ZedBoard..."
	ssh -t root@$(ZEDBOARD_IP) '/usr/local/bin/tx'

# ── RX: cross-compile for Pluto+ on the laptop ───────────────────────────────
rx-build: check-sysroot
	@echo "────────────────────────────────────────────────────"
	@echo "  Cross-compiling RX for Pluto+ (ARMv7 hard-float)..."
	@echo "────────────────────────────────────────────────────"
	$(CROSS_CC) $(PLUTO_CFLAGS) \
	    $(SYSROOT_CRT) \
	    -o rx/rx rx/rx.c \
	    $(PLUTO_LDFLAGS) \
	    $(SYSROOT_FINI)
	@echo "  OK: rx/rx"
	@file rx/rx
	@arm-linux-gnueabihf-readelf -d rx/rx | grep -E "NEEDED|RPATH"

rx-deploy: rx-build
	@echo "  Deploying to Pluto+ ($(PLUTO_IP))..."
	$(PLUTO_SSH) root@$(PLUTO_IP) 'killall rx 2>/dev/null; true'
	cat rx/rx | $(PLUTO_SSH) root@$(PLUTO_IP) 'cat > /tmp/rx && chmod +x /tmp/rx'
	@echo "  Deployed: /tmp/rx on Pluto+"

rx-run:
	@echo "  Starting signal-strength meter on Pluto+..."
	$(PLUTO_SSH) -t root@$(PLUTO_IP) '/tmp/rx'

# ── RX: fallback — compile on ZedBoard (same ARM glibc), deploy to Pluto+ ────
#
# Use this if the laptop cross-compile fails with runtime glibc errors.
# ZedBoard (same Cortex-A9 ARMv7) + same ADI firmware generation → binary
# runs natively on both boards without sysroot gymnastics.
#
rx-deploy-via-zed:
	@echo "────────────────────────────────────────────────────"
	@echo "  Compiling RX on ZedBoard (fallback path)..."
	@echo "────────────────────────────────────────────────────"
	ssh root@$(ZEDBOARD_IP) 'mkdir -p /tmp/sdrlink/rx /tmp/sdrlink/common'
	cat rx/rx.c            | ssh root@$(ZEDBOARD_IP) 'cat > /tmp/sdrlink/rx/rx.c'
	cat common/rf_params.h | ssh root@$(ZEDBOARD_IP) 'cat > /tmp/sdrlink/common/rf_params.h'
	ssh root@$(ZEDBOARD_IP) \
	    'cd /tmp/sdrlink/rx && $(ZED_CC) $(ZED_CFLAGS) -I../common -o /tmp/rx_arm rx.c $(ZED_LDFLAGS) \
	     && echo "  OK: compiled on ZedBoard" && file /tmp/rx_arm'
	ssh root@$(ZEDBOARD_IP) 'cat /tmp/rx_arm' > rx/rx
	@file rx/rx
	@echo "  Deploying to Pluto+..."
	$(PLUTO_SSH) root@$(PLUTO_IP) 'killall rx 2>/dev/null; true'
	cat rx/rx | $(PLUTO_SSH) root@$(PLUTO_IP) 'cat > /tmp/rx && chmod +x /tmp/rx'
	@echo "  Deployed: /tmp/rx on Pluto+"

# ── One-time: set up passwordless SSH to Pluto+ ──────────────────────────────
setup-pluto-ssh:
	@echo "  Copying SSH key to Pluto+ (password: analog)..."
	ssh-copy-id -i ~/.ssh/id_rsa_pluto.pub \
	    -o PubkeyAcceptedAlgorithms=+ssh-rsa root@$(PLUTO_IP)
	@echo "  Done."

help:
	@echo ""
	@echo "  SDR_Link"
	@echo "  ────────────────────────────────────────────────────────────────"
	@echo "  First time:"
	@echo "    make setup-pluto-ssh      # passwordless SSH to Pluto+"
	@echo ""
	@echo "  Build & deploy:"
	@echo "    make tx-build             # compile tx.c ON ZedBoard (native gcc)"
	@echo "    make rx-deploy            # cross-compile rx.c on laptop → Pluto+"
	@echo "    make rx-deploy-via-zed    # fallback: compile on ZedBoard → Pluto+"
	@echo ""
	@echo "  Run (open two terminals):"
	@echo "    make tx-run               # ZedBoard transmits 434.020 MHz tone"
	@echo "    make rx-run               # Pluto+ shows signal-strength bar"
	@echo ""
	@echo "  Devices:"
	@echo "    ZedBoard : $(ZEDBOARD_IP)   (TX)"
	@echo "    Pluto+   : $(PLUTO_IP)  (RX)"
	@echo ""
