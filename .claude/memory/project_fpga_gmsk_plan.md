---
name: project-fpga-gmsk-plan
description: Decision and roadmap to implement 10 Mbps GMSK modulator in Zynq FPGA fabric using ADI HDL reference design
metadata: 
  node_type: memory
  type: project
  originSessionId: df9496d7-bdd8-4c94-b90e-ccb77c595764
---

## Decision

Pari decided (2026-07-12) to implement a GMSK modulator in FPGA HDL (Verilog/VHDL) running in the Zynq PL on the ZedBoard. This is the only path to 10 Mbps — the software/libiio approach has a hard ceiling around 500 kbps.

**Why FPGA:** Gaussian filter + phase accumulator + IQ output run at the AD9361 sample clock in the PL. Zero CPU involvement on the hot path. This is how production radios do it.

## Toolchain to install (on Win11 / WSL)

- **Vivado ML Standard** (WebPACK license, free) — supports Zynq-7020 on ZedBoard
- **Critical:** Check [ADI HDL repo README](https://github.com/analogdevicesinc/hdl) for the exact supported Vivado version BEFORE downloading. ADI pins to a specific release (2022.2 or 2023.2 as of mid-2026). Wrong version = nothing builds.
- Download is ~50 GB.

## JTAG on ZedBoard

No external programmer needed. The ZedBoard has an **onboard Digilent JTAG-SMT2**.
- Connect the **PROG/JTAG micro-USB port** (labeled on the board, separate from the UART USB port).
- Vivado installs Digilent cable drivers automatically.

## Milestone sequence (DO NOT SKIP STEPS)

### Step 1 — Get ADI HDL building
```bash
git clone https://github.com/analogdevicesinc/hdl
cd hdl/projects/adrv9361z7035/zed   # check exact path for ZedBoard + AD9361
make                                  # 30–60 min first time
```
Program the resulting `.bit` via Vivado Hardware Manager. Verify `tx_dma_fsk` still works against it. This proves you can build and replace the bitstream.

**Why this first:** You are NOT starting from scratch. The ADI design already has the AD9361 LVDS interface, DMA engines, AXI interconnect. The GMSK block plugs into the existing AXI-Stream TX path.

### Step 2 — Understand the block design
Open the Vivado project. Look at the block diagram (IP Integrator). Understand:
- Where DMA hands off IQ samples to the AD9361 TX path
- The AXI-Stream handshake (TVALID/TREADY/TDATA/TLAST)
- How the DDS core is bypassed when DMA data is present

### Step 3 — Write the GMSK IP block (~200 lines Verilog)
Custom AXI-Stream IP that sits between the PS DMA output and the AD9361 TX path:
- Input: raw bits (1-bit AXI-Stream from DMA)
- Gaussian FIR filter (small, ~5 taps, fixed-point coefficients)
- FM phase accumulator (running sum of Gaussian-filtered phase increments)
- Output: IQ samples (signed 12-bit, AXI-Stream to AD9361 TX FIFO)

### Step 4 — Integrate and test
Wire the GMSK IP into the ADI block design. Rebuild bitstream. Test at increasing data rates.

## Realistic timeline

| Milestone | Time estimate |
|---|---|
| Vivado installed, opens without crashing | 1 day |
| ADI HDL compiles, programs via JTAG, tx_dma_fsk works | 2–4 days |
| Block design understood, ready to add custom IP | 3–5 days |
| Working GMSK modulator block | 1–2 weeks |

## Key concept to remember

The bottleneck is **NOT the GMSK math** — it's learning Vivado's IP Integrator and the AXI-Stream protocol. That is the actual learning curve. The Gaussian filter math and phase accumulation are straightforward once the plumbing is understood.

## Context for Win11/WSL setup

Pari is moving from Ubuntu (where SDR_Link was developed) to Win11 with WSL. The SDR_Link source is at `/home/pari/SDR_Link/` on the Ubuntu machine. On Win11/WSL, Vivado should be installed natively on Windows (not inside WSL) — Vivado's GUI and cable drivers don't work well from WSL. Use WSL only for git/text editing; launch Vivado from the Windows Start menu.
