---
name: project-sdrlink-state
description: "SDR_Link project: what was built, the software ceiling hit, and why we stopped at 20 bps FSK"
metadata: 
  node_type: memory
  type: project
  originSessionId: df9496d7-bdd8-4c94-b90e-ccb77c595764
---

## What SDR_Link is

A from-scratch RF data link between two SDR boards:
- **TX**: ZedBoard (Zynq-7000 + AD9361), IP 192.168.1.110, native gcc, runs as root
- **RX**: Pluto+ (Zynq-7010 + AD9361), IP 192.168.1.102, cross-compiled from laptop

Both use `libiio` userspace API to talk to the AD9361. Source lives at `/home/pari/SDR_Link/`.

## What was built (in order)

1. **OOK at 10 bps** — DDS tone on/off via IIO attribute writes, timed with `usleep()`. RX did FFT power measurement per buffer.
2. **2-FSK at 20 bps** — Two DDS tones (MARK=150 kHz, SPACE=50 kHz above LO at 433.920 MHz). Still using `usleep()` timing.
3. **Sample-timed DMA FSK** (`tx_dma_fsk.c`) — Eliminated `usleep()`. Each bit = one 115,200-sample IIO buffer pushed via `iio_buffer_push()`. Timing now governed by the AD9361 sample clock, not the OS scheduler. Phase-continuous IQ using complex phasor rotation.
4. **RF framing** — Added preamble (0x55 × 4) + SYNC byte (0xD5) + length field. RX can now lock to a frame mid-stream.

## Current parameters (`common/rf_params.h`)

- Carrier: 433.920 MHz (ISM band)
- Sample rate: 2.304 Msps (AD9361 minimum stable)
- RF bandwidth: 400 kHz
- FSK MARK: 150 kHz above LO, SPACE: 50 kHz above LO
- Bit rate: 20 bps (50 ms/bit = 115,200 samples/bit)
- TX attenuation: −20 dB (~25 µW, indoor lab use)

## The wall we hit

Goal was 10 Mbps GMSK. It is not achievable with the current software-only stack.

**Why:**
- 10 Mbps GMSK needs ~20–40 Msps sample rate (2–4 samples/symbol)
- At 40 Msps: 160 MB/s of IQ data to push through `iio_buffer_push()`
- Each bit at 10 Mbps = 100 ns. Linux scheduler jitter is ~1–5 ms. Gap = 4 orders of magnitude.
- `libiio` is a control/lab interface, not a real-time streamer at multi-megabit rates.
- ZedBoard ARM Cortex-A9 @ 667 MHz can generate ~5–10 Msps in software — ceiling, not goal.
- ADI's own GMSK demos at this speed live entirely in FPGA fabric.

## What is currently running on the ZedBoard PL (FPGA)

The ZedBoard is running an **ADI reference bitstream** (not custom). IIO devices present:
- `ad9361-phy` — AD9361 SPI control
- `cf-ad9361-dds-core-lpc` — TX path: DMA FIFO + DDS core
- `cf-ad9361-lpc` — RX capture core
- `ad7291`, `xadc` — board sensors

Kernel: 6.1.70, ADI Yocto Linux. TX sample clock: 2.304 Msps, TX ref clock: 80 MHz.

**Why:** Understanding this matters because the GMSK work builds ON TOP of this bitstream, not replacing it from scratch.
