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

## Toolchain (actual, as installed 2026-07-12)

- **Vivado 2025.2** installed natively on Windows (`C:\Users\Parit\AppData\Local\Xilinx` area). This is one minor version ahead of the newest ADI-supported release.
- **ADI hdl repo**: latest release branch is `hdl_2026_r1`, which targets **Vivado 2025.1** (per https://analogdevicesinc.github.io/hdl/user_guide/releases.html — check this page again if picking up this work much later, versions move on). No ADI release yet targets 2025.2.
- **Decision:** proceed with `hdl_2026_r1` on the 2025.2 install rather than installing 2025.1 side-by-side. Vivado usually auto-upgrades project files across one minor version; watch for IP core / constraint compatibility issues since ADI hasn't tested on 2025.2.
- **Cloned to:** `C:\Users\Parit\Documents\Projects\ADI_hdl` — a **sibling directory to SDR_initial**, NOT inside it (deliberate choice: keeps ADI's large history/IP out of the SDR_initial repo; Vivado projects reference it by path).
  - `git clone --branch hdl_2026_r1 --single-branch https://github.com/analogdevicesinc/hdl.git ADI_hdl`

## Vivado version-check gotcha (important — causes silent Vivado GUI close)

`hdl_2026_r1`'s `projects/scripts/adi_project_xilinx.tcl` (`adi_project_create` proc, ~line 199) hard-checks the Vivado version against `required_vivado_version` (2025.1). On mismatch it does NOT just warn — it calls Tcl `exit 2`, which kills the entire Vivado process (GUI vanishes with no dialog). This bit us running `adi_project` in the Tcl console on Vivado 2025.2.

**Fix:** before sourcing anything, set `IGNORE_VERSION_CHECK 1` in the Tcl console (GUI flow) — or the `ADI_IGNORE_VERSION_CHECK=1` env var (`make`/batch flow) — which downgrades it to a printed "CRITICAL WARNING" instead of exiting. `project-xilinx.mk` does NOT set this automatically, so the background `make` build kicked off before this fix was found almost certainly died the same way and needs a retry with the env var set.

## Missing IP packaging when skipping `make` (important)

ADI's per-project Makefile (e.g. `projects/fmcomms2/zed/Makefile`) lists `LIB_DEPS` — custom IP cores (axi_ad9361, axi_dmac, axi_clkgen, axi_hdmi_tx, axi_i2s_adi, axi_spdif_tx, axi_sysid, sysid_rom, util_i2c_mixer, util_pack/util_cpack2, util_pack/util_upack2, util_rfifo, util_tdd_sync, util_wfifo, xilinx/util_clkdiv for fmcomms2/zed) that get packaged into Vivado's IP catalog (`component.xml` with a VLNV) via `make` BEFORE the block design (`system_bd.tcl`) ever runs. If you build the project by hand in the Vivado Tcl console (skipping `make`), these IPs are never packaged — block design creation fails with e.g. `ERROR: [BD 41-74] Please specify VLNV when creating IP cell sys_i2c_mixer` the first time it tries to instantiate one.

**Fix used (confirmed working 2026-07-12):** package each `LIB_DEPS` entry directly via Vivado batch mode, one at a time, from inside that library's own directory: `call vivado -mode batch -source <libname>_ip.tcl` (with `ADI_IGNORE_VERSION_CHECK=1` set). This produces `component.xml` in place. All 15 fmcomms2/zed deps (axi_ad9361, axi_clkgen, axi_dmac, axi_hdmi_tx, axi_i2s_adi, axi_spdif_tx, axi_sysid, sysid_rom, util_i2c_mixer, util_pack/util_cpack2, util_pack/util_upack2, util_rfifo, util_tdd_sync, util_wfifo, xilinx/util_clkdiv) packaged successfully this way. Script saved at the session scratchpad as `package_libs.bat` — recreate similarly for other boards/projects by reading their Makefile's `LIB_DEPS` list.

**Transitive LIB_DEPS gotcha:** the top-level project Makefile's `LIB_DEPS` list is NOT the full dependency closure — some libraries have their own `XILINX_LIB_DEPS` in their per-library Makefile that aren't repeated at the project level, because `make` resolves these recursively. For fmcomms2/zed, `axi_dmac` itself needs `util_axis_fifo` and `util_cdc` (see `library/axi_dmac/Makefile`), which caused `create_bd_cell` to fail on `analog.com:user:util_axis_fifo:1.0` subcore even after all 15 top-level LIB_DEPS were packaged. Fix: after packaging the top-level list, `grep -r "XILINX_LIB_DEPS +=" library/` (or just check each dep's own Makefile) to find hidden transitive deps, and package those too before retrying `adi_project`.

**Batch-script gotcha:** `vivado` on Windows resolves to `vivado.bat`. Calling a `.bat` from inside another `.bat` WITHOUT `call` transfers control permanently — the parent script never resumes afterward (it silently exits with the child's exit code once the child finishes). Inside a `for %%D in (...) do (...)` loop this means only the FIRST iteration runs and the loop silently stops, even though the overall script reports exit code 0. Always use `call vivado ...`, not bare `vivado ...`, inside a batch script.

**Also important:** the top-level `make` build (the one kicked off directly, not via the GUI) resolves these same LIB_DEPS through a Makefile rule that shells out to `flock ... sh -c ...`. **`flock.exe` does not exist anywhere on this Windows machine** (not bundled with Vivado, not with Git for Windows) — so plain `make` on this Windows setup will likely hang or fail once it reaches library packaging, even after the Vivado-version-check fix. The Tcl-console / manual-packaging route above is the reliable path on this machine until/unless a `flock`-providing environment (e.g. full WSL) is used instead.

## Git-on-Windows gotcha

Git for Windows was installed mid-session but new PowerShell tool invocations don't pick up the updated PATH automatically (each PowerShell call is a fresh process; only cwd persists, not env vars). Fix: prepend `$env:PATH = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")` at the start of any command that needs a just-installed tool, in the SAME command block that uses it.

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

## Milestone reached (2026-07-12): block design builds clean

After packaging all `LIB_DEPS` + transitive deps (see above), `adi_project fmcomms2_zed` + `adi_project_files` completed with no errors — every IP Integrator block generated (`sys_i2c_mixer`, `axi_hdmi_dma`, `axi_ad9361`, DMA/pack/unpack cores, etc.), `system_wrapper.v` generated and imported cleanly. Remaining warnings (DDR DQS skew, AXI ID width mismatches on HP interconnects, EMIO SPI SSIN note) are normal/expected for this reference design, not blockers.

**A real, reopenable Vivado project now exists at:**
`C:\Users\Parit\Documents\Projects\ADI_hdl\projects\fmcomms2\zed\fmcomms2_zed.xpr`
Just double-click it / `File → Open Project` next session — no need to redo the Tcl setup sequence unless the project is deleted/regenerated.

**Next step (in progress):** Flow Navigator → Run Synthesis → Run Implementation → Generate Bitstream, on the now-clean project.

## First bitstream built (2026-07-12) — but with hold-timing violations

First full build succeeded mechanically (`system_top.bit`, ~3.86MB, in `fmcomms2_zed.runs/impl_1/`), setup timing passed (WNS +0.239ns), but **hold timing failed**: WHS -0.031ns, 11 failing endpoints, "Timing constraints are not met."

**Root cause:** our manual Tcl-console project creation only pasted the `adi_project`/`adi_project_files` lines from `system_project.tcl`, skipping two lines that matter for timing closure on THIS specific project:
```tcl
set ADI_POST_ROUTE_SCRIPT [file normalize $ad_hdl_dir/projects/scripts/auto_timing_fix_xilinx.tcl]
set_property strategy Congestion_SpreadLogic_high [get_runs impl_1]
```
`auto_timing_fix_xilinx.tcl` is ADI's own automated hold-fix (`phys_opt_design -hold_fix` loop + a `route_design` re-run workaround), added specifically because of a **known Vivado 2024.x/2025.x hold-timing regression** (see comments in that script, links to AMD/Xilinx forum threads). This is a known/expected issue for THIS Vivado version, not something we caused.

**Fix (applied via Tcl console, not yet confirmed successful as of last check):**
```tcl
add_files -fileset utils_1 -norecurse [file normalize "$ad_hdl_dir/projects/scripts/auto_timing_fix_xilinx.tcl"]
set_property strategy Congestion_SpreadLogic_high [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.TCL.POST [get_files auto_timing_fix_xilinx.tcl -of [get_fileset utils_1]] [get_runs impl_1]
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream
wait_on_run impl_1
```
**Result (confirmed 2026-07-12): timing closure achieved.** After wiring in `auto_timing_fix_xilinx.tcl` + `Congestion_SpreadLogic_high` strategy and re-running `impl_1`, the ATF's `route_design`-workaround alone fixed it (0 phys_opt_design attempts needed): WNS +0.249ns, WHS improved from -0.031ns (FAILED, 11 endpoints) to **+0.012ns (PASS, 0 endpoints)**. `write_bitstream completed successfully` ran immediately after against this fixed checkpoint (`ATF_success_system_top_routed.dcp`) — confirmed via `runme.log`. First fully clean bitstream for fmcomms2/zed exists at `fmcomms2_zed.runs/impl_1/system_top.bit`.

**Reporting gotcha:** `system_top_timing_summary_routed.rpt` (the standard post-route report) is NOT overwritten by the ATF post-route script — it stays frozen at the pre-fix (failing) numbers. The real final result lives in `ATF_<n>_final_timing_summary.txt` and `runme.log` ("Auto Timing Fix SUCCESS/FAILURE" line). Always check those, not the plain `_routed.rpt` file, when ADI_POST_ROUTE_SCRIPT is in use.

**Lesson for next manual project recreation:** paste the FULL body of `system_project.tcl` (including the `ADI_POST_ROUTE_SCRIPT`/strategy lines), not just the `adi_project`/`adi_project_files` calls — those two lines matter for timing closure on boards/projects known to have hold-violation issues, and skipping them isn't obvious until you check the timing summary report after implementation.

## Architecture pivot (2026-07-19): board roles swapped, target IP is now RX demodulator not TX modulator

Pari decided to swap TX/RX roles from the original SDR_Link setup:
- **TX now = Pluto+**, staying pure software/C (libiio, precompute-buffer + `iio_buffer_push()`, same technique as `tx_dma_fsk`). No HDL needed on Pluto+.
- **RX now = ZedBoard**, and the custom FPGA IP target shifts from a TX-path GMSK **modulator** to an RX-path GMSK **demodulator** (matched filter + timing recovery (Gardner/Mueller-style) + symbol decision), inserted in the `cf-ad9361-lpc` (RX capture) AXI-Stream path instead of `cf-ad9361-dds-core-lpc` (TX DMA path).

**Why this split:** TX modulation is a batch/precompute problem — the AD9361 DAC clocks out a pre-filled buffer in hardware, decoupled from CPU scheduler jitter, so software TX is tractable even at high rates as long as a frame can be precomputed before its playback deadline. RX demodulation is a genuinely real-time streaming problem — incoming ADC samples must be matched-filtered/timing-recovered/decided continuously with no ability to precompute ahead, which a Cortex-A9 under Linux cannot sustain at high sample rates. This asymmetry (not just "RX has more math") is why RX specifically needs PL and TX doesn't.

**Why ZedBoard gets the HDL work:** JTAG access is currently only available for the ZedBoard, and all the Vivado/ADI HDL environment work already done (fmcomms2/zed project, IP packaging workarounds, timing-closure fix, verified-working bitstream — see below) is built against it. Pluto+ has no JTAG access right now, so it stays as a pure userspace box running its stock bitstream.

**Implication for the milestone plan above:** Steps 2–4 (understand block design → write custom IP → integrate/test) still apply, but Step 3's IP is now a **GMSK demodulator on the RX AXI-Stream path**, not a modulator on TX. The Gaussian-filter-plus-phase-accumulator TX design sketched earlier in this file is deprioritized/moot for the FPGA work — that logic will likely live in the Pluto+ C program instead.

## Bitstream verified live on hardware (2026-07-19)

Sequence: power-cycled ZedBoard, then JTAG-programmed `fmcomms2_zed.runs\impl_1\system_top.bit` via Vivado Hardware Manager (onboard Digilent JTAG-SMT2, PROG/JTAG micro-USB port), no reboot since. DONE LED lit.

SSH'd in (`root@192.168.1.110`, password redacted here — see [[project_sdr_devices]]) via `plink -ssh -pw <redacted> -hostkey "SHA256:z4z2L1uAyEimv/jaraHlLzKdlgMnQ+rLiQ32QbePPVs" -batch root@192.168.1.110 "..."` since this Windows box has no `sshpass`, only PuTTY's `plink.exe` (`C:\Program Files\PuTTY\plink`). Board uptime was only ~5 min (from the power-cycle), confirming no later reboot occurred that would've reloaded the OLD bitstream from the SD card's `BOOT.BIN`.

`iio_info -s` shows all expected contexts/devices intact against the new PL image: `ad9361-phy`, `cf-ad9361-dds-core-lpc`, `cf-ad9361-lpc`, `xadc`, `ad7291`, `e000b000ethernet...`. Kernel `6.1.70`. No driver errors in `dmesg`.

**Conclusion:** the recompiled/timing-fixed `fmcomms2_zed` bitstream is confirmed functionally equivalent to the previous stock image at the Linux/IIO level — device enumeration only, not yet a TX-path data test.

**Not yet confirmed:** whether `tx_dma_fsk` (or `tx_cw`) actually transmits correctly against this new bitstream — device enumeration succeeding doesn't prove the DMA/AXI-Stream TX datapath works end-to-end. That's the next validation step before moving to Step 2 (studying the block design) / Step 3 (writing the GMSK IP).

## TX/RX role-swap validated end-to-end (2026-07-19)

After the ZedBoard SD card replacement (see [[project_sdr_devices]]) and re-establishing network access, ran the actual role-swap validation: **TX moved to Pluto+, RX moved to ZedBoard**, reusing the existing `tx_dma_fsk.c`/`rx.c` C apps unmodified (both use `iio_create_local_context()`, no code changes needed — see the architecture-pivot note above for why this split makes sense).

**Method:** compiled both `tx_dma_fsk.c` and `rx.c` natively on the ZedBoard (has gcc; Windows laptop has no ARM cross-compiler), then copied the TX binary over to Pluto+ via `cat`-over-SSH (`rx-deploy-via-zed`-style trick — Pluto+ has no sftp-server so pscp doesn't work, plain cat-over-ssh pipe preserves binary integrity fine). Ran RX in the background on ZedBoard, TX in the background on Pluto+.

**Gotcha hit: `pkill -f <name>` can kill its own SSH session.** `pkill -f rx_arm` matches against the FULL command line of every process, including the invoking shell's own `sh -c "pkill -f rx_arm; ..."` line (which itself contains the string "rx_arm") — it killed itself/the session before the rest of the command could run (symptom: plink exits 128, zero output, even from an unrelated later `echo`). Fix: use `killall rx_arm` (matches process name only) instead of `pkill -f` for this kind of remote one-liner.

**First attempt received only noise** (ΔP flipping small-magnitude and incoherently every ~1ms tick, stuck in `[IDLE|HUNT]` forever) — root cause was **forgetting to physically swap the antennas** to match the new roles. The AD9361/FMCOMMS2 boards have separate TX and RX SMA ports; the antennas were still on the ports matching the OLD roles. Fix: move each board's antenna to the port matching its CURRENT role (Pluto+ → TX port, ZedBoard → RX port).

**After swapping antennas: confirmed working end-to-end.** Clean ΔP swings (~+20dB / ~-20dB, matching real modulation, not noise), full frame sync achieved (preamble → 0xD5 SYNC → LEN → data), decoded payload correctly twice in a row: `>>> HELLO SDR`. TX→RX role swap is validated — Pluto+ transmitting, ZedBoard receiving.

**Also note:** `/tmp` on both boards is RAM-backed (tmpfs) — power-cycling either board wipes any compiled binaries there and they need to be re-uploaded/recompiled from source (source files on the laptop are the durable copy, as expected).

## Step 0 (infrastructure proof) — in progress, build running (2026-07-19)

Following the finer-grained testable-step breakdown (see the published diagram artifact below), started actual HDL work with **Step 0**: a trivial custom AXI4-Lite IP with zero DSP, whose only purpose is to prove the Verilog -> IP-packaging -> block-design -> bitstream -> JTAG -> Linux-readback loop works end to end, fully decoupled from any discriminator/timing-recovery correctness question.

**Diagram artifact (architecture + finer-grained testable build sequence):** https://claude.ai/code/artifact/d6c9f6e5-c4d4-4965-a345-9dd27554dd57 — vertical schematic, Step 0 through Step 6, each with its own SIM/HW test gate. Republish the same scratchpad file path in a fresh session to update it further; a session that didn't publish it needs the URL passed explicitly to update in place.

### Files (in SDR_initial repo, git-tracked, NOT the ADI_hdl sibling repo)

- `hdl/gmsk_step0_regs/gmsk_step0_regs.v` — the module. Three registers, each proving something distinct:
  - `0x0 ID` (read-only) = `32'h474D_534B` ("GMSK" ASCII-hex) — proves address decode routes to *this* IP specifically.
  - `0x4 SCRATCH` (read/write) — write-then-read-back proves the AXI-Lite write path, not just reads.
  - `0x8 COUNTER` (read-only, free-running, increments every `S_AXI_ACLK`) — proves the fabric clock is really driving sequential logic, not just static wiring.
  - Standard/correct AXI4-Lite slave handshake pattern (matches Xilinx's own generated template structure) — written from scratch, not copy-pasted from a wizard.
- `hdl/gmsk_step0_regs/package_ip.tcl` — packaging script. **Known-fixed version**: does NOT call `ipx::create_xgui_document` (see gotcha below).
- `hdl/gmsk_step0_regs/ip_repo/gmsk_step0_regs/` — packaged IP output (`component.xml` etc.), confirmed complete and valid (31KB, properly closed, checksums present, 66 `S_AXI` references, correct name tag).

### Gotchas hit packaging + integrating this IP (useful for the next custom IP too)

1. **Tcl `set` is not batch `set`.** `set ADI_IGNORE_VERSION_CHECK=1` inside Vivado's interactive Tcl Shell throws `can't read "ADI_IGNORE_VERSION_CHECK=1": no such variable` — that's cmd.exe/batch syntax, not Tcl. Tcl reaches OS env vars via the `env` array: `set ::env(ADI_IGNORE_VERSION_CHECK) 1`. Also: if Vivado's Tcl Shell is already running interactively, don't re-invoke `vivado -mode batch -source ...` — just `source <script>.tcl` directly in the session you're already in.
2. **`ipx::create_xgui_document` may not exist as a valid command** in this Vivado session/mode (`invalid command name` error) — it only builds the cosmetic "re-customize IP" GUI page and isn't needed for an IP with no configurable parameters. `package_ip.tcl` was fixed to skip it; packaging completes fine via just `ipx::update_checksums` + `ipx::save_core`.
3. **Vivado's Tcl console echoes commands interleaved with their output**, which can look like a crash/failure when it isn't (e.g. `current_project fmcomms2_zed` appearing to "break" a sequence was actually just an echoed return value). **Ground truth is always the filesystem** — check whether `component.xml` (or whatever the expected output file is) actually exists and is well-formed (non-truncated, has the right tags/checksums) rather than trusting a garbled pasted transcript.
4. **`update_ip_catalog` fails while a block design is open**: `Cannot update IP catalog while a BD design is open`. Fix: `close_bd_design [current_bd_design]` -> `update_ip_catalog` -> reopen the `.bd` file.
5. **The hold-timing fix properties persist correctly** across new IP integration work — `get_property strategy [get_runs impl_1]` still returned `Congestion_SpreadLogic_high` and `STEPS.ROUTE_DESIGN.TCL.POST` still pointed at `auto_timing_fix_xilinx.tcl` without needing to redo any of that setup. These are saved per-run in the project, not something a block-design edit touches.

### Current status: build running, not yet confirmed

- IP repo path registered on the **real** `fmcomms2_zed` project (not a throwaway packaging project): `set_property ip_repo_paths {c:/Users/Parit/Documents/Projects/ADI_hdl/library C:/Users/Parit/Documents/Projects/SDR_initial/hdl/gmsk_step0_regs/ip_repo/gmsk_step0_regs} [current_project]`
- IP instantiated in the `system.bd` block design, Connection Automation wired `S_AXI` into the PS AXI-Lite interconnect.
- **Address assigned by Vivado's Address Editor: base `0x40000000`, 4K window**, in the `/sys_ps7/Data` address space — same address space as all of ADI's own peripherals (`axi_ad9361` at `0x79020000`, `axi_sysid_0` at `0x45000000`, etc.), confirmed via `AddressSegments.csv`. Our IP is now a first-class peripheral in this design's address map.
- `validate_bd_design` passed clean — the only warnings were pre-existing/expected ones (SPI EMIO SSIN note, clk_wiz INFO), nothing named our IP, which is the good sign (validate_bd_design names cells explicitly when something about their connections is wrong).
- `generate_target all [get_files */system.bd]` run, `reset_run synth_1`, then `launch_runs impl_1 -to_step write_bitstream -jobs 4` kicked off at **2026-07-19 ~22:53**. As of last check it was still running (`wait_on_run impl_1` blocking the console; Design Runs panel in the GUI shows live progress). Expected total time 15-45+ min for this design size + the ATF hold-timing pass, based on how long the equivalent first build took.

**Register map once this bitstream is programmed (base 0x40000000):**
| Register | Address | Test |
|---|---|---|
| ID | `0x40000000` | `devmem 0x40000000` -> expect `0x474d534b` |
| SCRATCH | `0x40000004` | `devmem 0x40000004 32 0xdeadbeef` then `devmem 0x40000004` -> expect `0xdeadbeef` back |
| COUNTER | `0x40000008` | `devmem 0x40000008`, wait, `devmem 0x40000008` again -> second read should be larger |

**Next steps once the build finishes (this is exactly where to resume if the session drops):**
1. Check `runme.log` for the ATF result — NOT the plain `system_top_timing_summary_routed.rpt` (stays frozen at pre-fix numbers): `exec grep -r "Auto Timing Fix" .../fmcomms2_zed.runs/impl_1/runme.log` (look for SUCCESS).
2. JTAG-program the new `system_top.bit` (`fmcomms2_zed.runs/impl_1/system_top.bit`) via Vivado Hardware Manager, same process as before (ZedBoard's PROG/JTAG micro-USB port).
3. SSH to the ZedBoard (IP may have changed again after reboot — check via serial/ARP as done previously) and run the three `devmem` tests above.
4. All three passing = **Step 0 done.** Move to Step 1 (frequency discriminator) per the diagram artifact's build sequence.

## Step 0 CONFIRMED PASSING on hardware (2026-07-25)

ATF result in `runme.log`: "Auto Timing Fix SUCCESS after 0 attempts - final WNS is 0.027 ns." `system_top.bit` (4,045,686 bytes) JTAG-programmed onto the ZedBoard via Vivado Hardware Manager, DONE LED lit, board back up.

**Gotcha: `devmem` binary not found on this rootfs.** The fresh Kuiper image (from the 2026-07-19 SD card reflash) doesn't ship a standalone `/usr/bin/devmem` — only busybox's multi-call binary provides it. Fix: prefix every call with `busybox`, e.g. `busybox devmem 0x40000000` instead of bare `devmem 0x40000000` (which gives `command not found`, exit 127). Remember this for any future register-poke test on this board/image.

**ZedBoard IP at time of test:** `192.168.1.106` (still DHCP-assigned from the reflash, unchanged since 2026-07-19 — static-IP config still not restored, see [[project_sdr_devices]] outstanding item #1). SSH password for this fresh rootfs: (redacted — ask Pari; confirmed working 2026-07-25, differs from the old rootfs's password).

**All three register tests passed:**
| Register | Address | Result |
|---|---|---|
| ID | `0x40000000` | `0x474D534B` — exact match |
| SCRATCH | `0x40000004` | wrote `0xDEADBEEF`, read back `0xDEADBEEF` |
| COUNTER | `0x40000008` | `0x6B154766` → `0x711C28E0` after 1s — incrementing |

**Step 0 is DONE.** The full Verilog → IP-packaging → block-design → bitstream → JTAG → Linux-readback loop is proven end-to-end on real hardware, fully decoupled from GMSK correctness questions. Per the diagram artifact's build sequence, **next is Step 1: frequency discriminator** (first real DSP block on the RX AXI-Stream path, per the architecture pivot — see the section above on the TX/RX role swap).

## Step 1 (frequency discriminator) — SIM gate PASSED (2026-07-25)

Implemented `hdl/gmsk_step1_discriminator/gmsk_step1_discriminator.v` per the design doc (`docs/step1_discriminator.html`): delay-and-conjugate-multiply quadrature FM demodulator, AXI4-Stream in/out, one sample per clock, no rate change. Only computes `Im{z[n]*conj(z[n-1])} = Q[n]*I[n-1] - I[n]*Q[n-1]` (2 multiplies, not the full 4-multiply complex product) since the real part is never consumed downstream.

**Interface convention (assumed, not yet confirmed against real hardware):** TDATA packs `{Q[15:0], I[15:0]}`, IQ_WIDTH=16 to match the AD9361 RX chain's native sign-extended word width, OUT_WIDTH=18 (truncates the 33-bit full-precision product down by keeping the top 18 bits). `s_axis_tready` tied high — this is a fixed-rate fabric pipeline with no realistic backpressure scenario, so no stall logic was built. **Must be verified against `axi_ad9361`'s actual output width when this gets wired into the real block design (Step 4 integration)** — this was written and simulated standalone, before that wiring exists.

**SIM gate:** `hdl/gmsk_step1_discriminator/sim/` — `gen_test_vectors.awk` synthesizes a continuous-phase two-tone test stream (MARK=150kHz/SPACE=50kHz per `rf_params.h`, alternating 1,0,1,0,... bit pattern, phase never reset at bit boundaries, matching real continuous-phase FSK) into `test_vectors.hex` ($readmemh format, regenerate via `awk -f gen_test_vectors.awk > test_vectors.hex` — this .hex is gitignored, not committed, since it's trivially regenerable). `tb_gmsk_step1_discriminator.v` feeds it through the DUT and self-checks: each bit segment's output should settle to a clean, consistent level, and MARK's level should be clearly separated from SPACE's (>2x).

**Ran via Vivado's standalone simulator (no project needed):** `xvlog` → `xelab ... -s tb_sim` → `xsim tb_sim -runall`, binaries at `C:\AMDDesignTools\2025.2\Vivado\bin\` (not on PATH — invoke with full path). **Result: TEST PASSED.** MARK segments settled at 4855.0, SPACE at 1658.9 (ratio 2.93x) — matches hand-calculated expected values (`AMPLITUDE^2 * sin(2*pi*f/Fs)`, truncated to OUT_WIDTH) almost exactly, confirming both the Verilog and the small-angle approximation the design doc relies on.

**Fixed after first packaging attempt:** Vivado's IP packager rejected the original `OUT_WIDTH=18` — AXI4-Stream's `TDATA` logical port must be a multiple of 8 bits (`CRITICAL WARNING: [IP_Flow 19-3834]`). Changed `OUT_WIDTH` default to 16 (matches `IQ_WIDTH`, still comfortably separates the two levels: MARK settles at 1213.0, SPACE at 414.0, same 2.93x ratio as before) and re-ran the SIM gate — still TEST PASSED. **Lesson for any future AXI-Stream IP on this project: TDATA width must always be byte-aligned (8/16/24/32/...), unlike AXI4-Lite registers.**

**IP packaged (2026-07-25):** `hdl/gmsk_step1_discriminator/package_ip.tcl` (mirrors Step 0's script) → `hdl/gmsk_step1_discriminator/ip_repo/gmsk_step1_discriminator/component.xml`, confirmed non-truncated (379 lines, properly closed `</spirit:component>`, 16.9KB). Vivado auto-inferred both `S_AXIS`/`M_AXIS` bus interfaces and the `aclk`/`aresetn` clock/reset interfaces cleanly from the standard lowercase port-naming convention — no manual interface definition needed. Remaining packaging warnings (description "not meaningful", missing Product Guide, no `FREQ_HZ` on aclk) are cosmetic, same class of benign warning Step 0 saw.

**Not yet done:** hardware integration — block-design wiring into the real `fmcomms2_zed` project (register this IP's repo path alongside `gmsk_step0_regs`'s, instantiate in `system.bd`, wire `s_axis`/`m_axis` into the RX AXI-Stream path after `cf-ad9361-lpc`), bitstream rebuild, JTAG, on-air capture per the design doc's HW test plan. SIM gate + IP packaging are the checkpoints reached so far, per the diagram artifact's per-step SIM/HW gate structure. **This is exactly where to resume if the session drops.**

**Clock/reset wiring, traced from the real `system.bd` (2026-07-26) — use this instead of re-deriving it:**
- AD9361's RX sample clock/frame/data arrive at the FPGA as genuine LVDS differential pairs (`rx_clk_in_p/n` etc., real board-level differential traces from the AD9361 IC, not just a naming convention). Inside `axi_ad9361_lvds_if.v` → `ad_data_clk.v` (`library/xilinx/common/`), a Xilinx `IBUFGDS` primitive (real dedicated differential-input silicon at the pin) converts it to single-ended, then `BUFG` puts it on a global clock net. That recovered clock is exposed as `axi_ad9361`'s `l_clk` **output**.
- In the existing block design, `l_clk` is wired back into `axi_ad9361`'s own `clk` **input** (which becomes `adc_clk` internally — the domain `adc_data_i0`/`adc_valid_i0`/`adc_data_q0`/`adc_valid_q0` are synchronous to) via a net literally named **`axi_ad9361_l_clk`**, which also feeds `util_ad9361_divclk`, `util_ad9361_adc_fifo/din_clk`, `axi_ad9361_dac_fifo/dout_clk`. **This is the net `gmsk_step1_discriminator`'s `aclk` must connect to.**
- `axi_ad9361`'s `rst` port is an **output** (a locally-generated reset for this clock domain, not tied to the AXI-Lite `aresetn`), on a net named `axi_ad9361_rst`, feeding `util_ad9361_adc_fifo/din_rst` and `axi_ad9361_dac_fifo/dout_rst` — note no trailing `n`, i.e. **active-HIGH**, confirmed by contrast with this same design's active-low `..._rstn` ports elsewhere. Our module's `aresetn` is active-LOW (Vivado's packager auto-inferred `POLARITY=ACTIVE_LOW` from the name). **Do not wire `axi_ad9361_rst` straight into `aresetn`** — it needs a `Utility Vector Logic` IP (`C_OPERATION=not`) in between. The design already has exactly this pattern once (`sys_logic_inv` block), so this isn't a new hack, just reusing the existing convention.

**Connection Automation investigation (2026-07-26):** confirmed (via `axi_ad9361_ip.tcl`, ADI's own Xilinx packaging script) that `axi_ad9361`'s `l_clk`/`rst` are formally packaged as Vivado clock/reset bus interfaces, `rst` explicitly `POLARITY=ACTIVE_HIGH` — matching our IP's auto-inferred interfaces on the other end. So renaming ports was never the right lever; **the actual gap was a metadata property**: packaging log showed `aclk`'s `ASSOCIATED_BUSIF` only listed `m_axis`, not `s_axis`, which is what Connection Automation reads to know both stream interfaces share a clock. Fixed in `package_ip.tcl` (`set_property value {s_axis:m_axis} ...`), re-packaged, confirmed `s_axis:m_axis` present in the regenerated `component.xml`. **Expectation set correctly for next session: Connection Automation should now be able to auto-wire `aclk`/`aresetn` (including inserting the polarity-fixing NOT gate) when run on this IP instance. It still CANNOT auto-wire `s_axis` itself** — `axi_ad9361`'s `adc_data_i0`/`adc_valid_i0`/etc. are plain scalar ports, not part of any declared AXI4-Stream bus interface, so there's nothing for automation to match against; the Concat-then-manual-wire step for the I/Q data path is unavoidable regardless of naming. **In practice, even the fixed metadata didn't make Connection Automation auto-popup for this IP on placement** (unlike Step 0's `gmsk_step0_regs`, which has an AXI4-Lite slave interface — Vivado eagerly auto-detects "new AXI4-Lite peripheral needs a PS connection" as a flagship pattern; a pure AXI4-Stream+clock/reset-only IP with no valid stream counterpart doesn't trigger the same eagerness). Wired everything manually instead — see below, confirmed correct.

**Hardware wiring DONE and verified correct (2026-07-26)**, traced directly from the saved `system.bd` net list (ground truth, more reliable than reading the schematic PDF export):
- `aclk` → `axi_ad9361_l_clk` net (alongside `axi_ad9361/clk`, `util_ad9361_divclk/clk`, `util_ad9361_adc_fifo/din_clk`, `axi_ad9361_dac_fifo/dout_clk`, and now also `system_ila_0/clk`).
- `aresetn` → `util_vector_logic_0/Res` (a NOT gate, `C_OPERATION=not`, `C_SIZE=1`), whose input `Op1` is fed from `axi_ad9361/rst` (the `axi_ad9361_rst` net, confirmed active-high).
- `s_axis_tvalid` → `axi_ad9361/adc_valid_i0` directly.
- `s_axis_tdata` → `xlconcat_0/dout`. Verified the Concat's input mapping is correct: `In0`(16-bit)=`adc_data_i0`, `In1`(16-bit)=`adc_data_q0` — Xilinx's Concat places `In0` at the low bits, so `dout={Q,I}`, exactly matching the module's expected packing (not accidentally swapped).
- `m_axis_tready` → `xlconstant_0/dout` (default config: width=1, value=1).
- `m_axis_tdata` and `m_axis_tvalid` → `system_ila_0` probe0/probe1 (`C_NUM_OF_PROBES=2`), for JTAG waveform capture — not routed into the datapath anywhere, matching the design doc's ILA-based test plan.

**Generate Output Products (2026-07-26) succeeded with zero errors** — only pre-existing/expected AXI-ID-width warnings on the HP interconnects (same ones seen since the original fmcomms2_zed build, unrelated to this IP) and two benign "drive strength cannot be preserved... marked for debug" notes (expected side effect of Mark Debug on `m_axis_tdata`/`m_axis_tvalid`). IP-level OOC synthesis launched clean for `gmsk_step1_discrimin_0`, `system_ila_0`, `util_vector_logic_0`.

**First bitstream attempt: TIMING FAILED (2026-07-26)** — `WARNING: ATF: Auto Timing Fix FAILURE after 5 attempts - final WNS is -0.870 ns`. This is a genuinely different problem from Step 0's earlier hold-timing regression (which ATF's `route_design` workaround fixed) — this is a **setup** violation, and ATF's fix doesn't target this class of issue. Root cause, read directly from `system_top_timing_summary_routed.rpt`'s worst path:
```
Source:      axi_ad9361/.../adc_data_q0_int_reg[15]/C   (plain register)
Destination: gmsk_step1_discrimin_0/.../mult_qi_reg/A[20]  (DSP48E1 -- Vivado did infer the dedicated multiplier, that wasn't the issue)
Slack: -0.868ns, Logic Levels: 0, Data Path Delay: 1.145ns of a 4.000ns budget
```
**`rx_clk` (the `axi_ad9361_l_clk` net) runs at 250 MHz**, not the 2.304 Msps sample rate as originally assumed — the LVDS interface clock runs far above the actual per-channel sample rate. With "Logic Levels: 0" and a tiny 1.145ns data-path delay, the failure wasn't logic speed — it was **clock network delay** consuming the 4ns budget on a same-cycle hop from `axi_ad9361`'s output register straight into our DSP48, because our RTL multiplied this cycle's *raw* `s_axis_tdata` (a bare wire, zero pipeline stage of our own) against a registered `i_prev`/`q_prev`. One operand had no register stage cushioning the physical distance between the two flip-flops.

**Fix applied:** added a second delay-line stage so BOTH multiply operands come from registers (`i_d1/q_d1` = z[n-1], `i_d2/q_d2` = z[n-2], multiply is now `q_d1*i_d2 - i_d1*q_d2`) instead of one raw wire + one register. Standard technique for feeding a DSP48 at high frequency — gives the placer/DSP48 input pipeline a full cycle at each hop. Costs exactly one extra cycle of latency (3->4), irrelevant to this fixed-rate streaming design. **Re-ran the SIM gate after the change: still TEST PASSED, identical output values (MARK 1213.0 / SPACE 414.0, ratio 2.93x)** — confirms the fix is purely a timing/pipelining change, zero functional difference. Re-packaged the IP (`ip_repo/gmsk_step1_discriminator/component.xml` regenerated).

**Second bitstream attempt: WNS improved to -0.110ns, still FAILED.** The two-register-stage fix worked — the discriminator's own path was no longer in the violated-paths list at all. New worst path was entirely inside `dbg_hub` (Xilinx's auto-inserted JTAG-to-ILA debug bridge, `xilinx.com:ip:xsdbm:3.0`), which had ended up clocked from our fast `rx_clk` (250 MHz) by default instead of a slower clock — `dbg_hub` only needs to talk to the JTAG host, no reason it needs the fast sample-domain clock. **Fix:** `open_run synth_1` → `connect_debug_port dbg_hub/clk [get_nets i_system_wrapper/system_i/sys_cpu_clk]` → `save_constraints -force` (this is a constraint, not a netlist edit, so it must be saved or the next `impl_1` run won't see it) — reassigned it to the same `sys_cpu_clk` net that `gmsk_step0_regs`'s `S_AXI_ACLK` and a dozen other AXI-Lite peripherals already use comfortably.

**Third bitstream attempt: WNS -0.056ns / -0.012ns, still technically FAILED but only inside Xilinx's own encrypted `system_ila_0` netlist** (`<hidden>` path segments — can't be edited). Both our discriminator and `dbg_hub` are now completely clean. Accepted this as low-risk since it's debug-only infrastructure (worst case: an occasionally corrupted *waveform sample*, not a functional risk to the real datapath) rather than sinking another 15-45 min rebuild into shrinking ILA depth further. **Vivado still writes a `.bit` file despite an ATF FAILURE message** — bitstream existing is not the same as timing having closed; always check `runme.log` for the actual WNS line, not just file presence.

## Step 1 hardware bring-up — inconclusive after extensive debugging (2026-07-26/27), pivoting to smaller increments

Wiring was independently re-verified correct by reading the live `system.bd` net list directly (not assumed) — `aclk`, `aresetn`/NOT-gate, `s_axis_tvalid`, `s_axis_tdata` via `xlconcat_0` (confirmed correct `{Q,I}` bit order), `m_axis_tready` tie-off, and both ILA probes are all exactly as intended. **This rules out an accidental disconnection as the explanation for anything below** — whatever's wrong, it isn't the block-design wiring.

**Persistent Linux DMA failure, isolated to our bitstream specifically.** `iio_buffer_refill()` on `cf-ad9361-lpc` reliably fails with `-110` (ETIMEDOUT), reproducibly, on the very first attempt after a genuinely fresh Linux boot (`uptime` confirmed `up 0 min`) immediately followed by JTAG-programming our bitstream — no "stale driver state" history possible. Controlled comparison on the same clean boot: **stock bitstream → DMA works instantly. Our bitstream (JTAG-swapped in) → same `-110` every single time.** This is a real, reproducible signal tied to our custom bitstream specifically — root mechanism still unknown. Two live variables never isolated from each other: (a) something about our design/routing congestion genuinely disturbing the DMA path despite intact wiring, vs. (b) live-JTAG-swapping *any* custom bitstream into an already-booted kernel being inherently unreliable for DMA, regardless of design content (would require a persistent `BOOT.BIN` with our bitstream to test a true cold boot against it — not yet built).

**Driver-level interventions tried, all unproductive and behaviorally inconsistent:**
- Unbind/rebind `cf_axi_adc` (the `79020000.cf-ad9361-lpc` consumer) alone — quick, clean, no effect on the failure.
- Unbind/rebind all three `dma-axi-dmac` provider devices (`7c420000.dma`, `7c400000.dma`, `43000000.dma`) plus `cf_axi_adc` — **operations hung unpredictably**: same exact step took ~20s the first time, was instant on a later attempt, then a *different* step (the rebind of `7c420000.dma`) hung past 90s on a deliberate repeat. Not tied to a consistent step. Board stayed responsive throughout (never a true hard lock, `loadavg` stayed sane, no `D`-state processes) — never required a hardware reset to recover, just very slow/unpredictable sysfs writes.
- **"Zero Linux involvement" test** (fresh power-cycle, JTAG-program directly, no software touched at all) — saw *no* ILA activity whatsoever. Concluded this is likely inconclusive rather than meaningful: AD9361 needs SPI-driven ENSM/calibration (i.e., software) to enter an RX-active conversion state — it doesn't free-run purely from power-up, so absence of activity here doesn't distinguish "design is broken" from "AD9361 was never told to start."
- **Live-watched the ILA during `rx.c`'s few-second active window** (PHY config succeeds, then it crashes on refill) — nothing observed.
- Pari recalled seeing periodic `m_axis_tvalid` pulses with `m_axis_tdata` toggling only between `0x0000`/`0xFFFF` (garbage-looking, non-periodic in value) during an earlier round of unbind/rebind experiments. **Deliberately reproduced the identical sequence, narrating each step live while Pari watched continuously** — including re-triggering the exact rebind step that had hung 45s+ before (this time hanging 90s+). **Saw nothing, even during the reproduced hang.** This strongly suggests the earlier "garbage periodic" observation was a one-off, not a stable/reproducible signal — most likely a transient artifact of the kernel driver's `probe()`/`remove()` code itself poking hardware registers while stuck, not real captured RF data. Not worth chasing further as a lead.

**The important negative conclusion, agreed with Pari at session close: across this entire multi-hour debugging session, we never once obtained a confirmed-successful ILA capture of *anything* — not real AD9361 data, not even a reproducible version of the earlier garbage pattern.** We were trying to validate two entangled unknowns simultaneously (does the discriminator+ILA+dbg_hub debug-capture chain work *at all*? AND does real AD9361 RF data actually flow through Linux's broken-looking DMA path?) without ever isolating them from each other. Every failed attempt is equally consistent with either "the debug infrastructure itself is broken" or "there's no real data to capture" — we have no evidence distinguishing the two.

**Agreed next step — decompose Step 1 hardware validation into much smaller increments, building directly on Step 0's already-proven infrastructure, instead of attempting the full discriminator+ILA+AD9361+Linux-DMA stack at once:**

The very next increment (start of next session): get something **trivially simple, deterministic, and with zero dependency on AD9361/RF/DMA/Linux** observable via the ILA/JTAG path — e.g. a free-running counter (same idea as Step 0's `COUNTER` register, but observed via ILA streaming instead of AXI-Lite polling), or literally just probing `rx_clk`/`data_clk` itself toggling. This isolates the untested variable cleanly:
- If a trivial counter shows up cleanly on the ILA → the debug-capture chain (ILA, `dbg_hub`, trigger setup, probe wiring) is proven sound, and the entire investigation can refocus purely on the AD9361/DMA mystery with confidence the observation tool itself works.
- If even a trivial counter shows *nothing* → the problem has been in the debug-capture infrastructure this whole time, a much smaller and more tractable thing to debug than anything AD9361/RF-related, and every AD9361-focused theory from this session becomes moot.

**This is exactly where to resume next session.** Do not jump back into AD9361/DMA debugging or attempt the full discriminator hardware test again until this baseline is confirmed either way.

**Step0 sanity re-check (2026-07-27): PASSED cleanly, still on the current (combined, has-all-of-Step1) bitstream.** No rebuild needed — `gmsk_step0_regs` was never touched, still present at `0x40000000`. `busybox devmem` ID/SCRATCH/COUNTER all passed exactly as originally on 2026-07-25 (COUNTER `0x83718906` -> `0xBBF7CC16` after 1s). **Meaningful result: everything added for Step1 (discriminator, Concat, constant, NOT gate, ILA, dbg_hub reassignment, both timing fixes) has NOT destabilized or corrupted the basic AXI-Lite/JTAG/Linux round-trip in any detectable way.** Whatever is wrong with the AD9361/DMA path is not broad collateral damage from our changes — it's something narrower. No need for the more expensive "surgically strip Step1 and rebuild a pure Step0-only bitstream" option unless this quick check had failed.

### START HERE NEXT SESSION — Step 1a: ILA proof-of-life (agreed plan, not yet implemented, 2026-07-27)

Goal: isolate whether the ILA/`dbg_hub` debug-capture chain itself actually works, completely independent of the AD9361/DMA mystery above — we never once got a confirmed-successful capture of anything all last session, so the observation tool itself is still an open suspect.

**What to build:** a new, tiny (~15 line) module — a free-running counter, nothing else. No AXI-Stream input, no dependency on `axi_ad9361`/`s_axis`/real data at all. It just increments every `aclk`.

**Critical detail — must reuse the exact same suspect path, not an easier one:**
- Clock/reset: same `aclk`/`aresetn` as `gmsk_step1_discriminator` today, i.e. still wired to the `axi_ad9361_l_clk` net + the `util_vector_logic_0` NOT-gate off `axi_ad9361_rst`. **Do not test on `sys_cpu_clk` instead** — that would prove the ILA works in general, not on the specific `rx_clk` domain that's been showing nothing.
- Probe target: reuse `system_ila_0`'s existing `probe0`/`probe1` (currently `m_axis_tdata`/`m_axis_tvalid` from the discriminator) — swap the source to the new counter's output + a simple always-1 "valid" (or just probe the counter directly with no valid concept needed, it's always meaningful).
- Same `dbg_hub` clock reassignment (`sys_cpu_clk`) stays as-is — not being retested, already proven fine as a mechanism (Step0's registers use that same domain successfully).

**Package/build/wire it exactly like `gmsk_step1_discriminator`**: write `.v`, SIM-gate it trivially (a counter is self-evidently correct, but simulate anyway per this project's convention), `package_ip.tcl`, register the repo path, drop it in the block design in place of (or alongside, wired to spare ILA probes) the discriminator's outputs, rebuild, JTAG-program, trigger.

**Interpreting the result:**
- ILA shows a cleanly incrementing counter → the entire capture chain (ILA, `dbg_hub`, trigger, JTAG readback) is proven sound on `rx_clk`. All suspicion moves cleanly onto "is real AD9361 data available at all" — a much narrower, separate question from here on.
- ILA still shows **nothing** → the problem has been in the debug infrastructure itself the whole time (trigger condition, probe wiring, `dbg_hub` setup), not AD9361/DMA at all — a smaller, far more tractable thing to debug, and it retroactively means every AD9361-focused theory from the previous session was untestable noise until this is fixed first.

Do not jump back into AD9361/DMA debugging (unbind/rebind tricks, PHY config timing, etc.) until this is resolved either way — it was explicitly agreed to stop entangling those two unknowns.

### Step 1a implementation progress (2026-08-01)

`gmsk_step1a_ila_counter.v` written (16-bit free-running counter, synchronous active-low reset, no AXI-Stream — deliberately just `aclk`/`aresetn`/`count`, to avoid reintroducing components this test is trying to rule out). SIM gate **PASSED** (held at 0 through reset, increments by exactly 1/clock, clears on mid-stream reset re-assertion). Packaged cleanly as an IP (`hdl/gmsk_step1a_ila_counter/ip_repo/gmsk_step1a_ila_counter/component.xml`, 10.3KB, same benign warning class as the other two IPs — cosmetic description, missing product guide, no `FREQ_HZ`). Files also now tracked by ADI_hdl's own git setup — see [[project_adi_hdl_git_tracking]].

**Block-design wiring done (2026-08-01):**
- `aclk`/`aresetn` wired to the same suspect nets as the discriminator (`axi_ad9361_l_clk`, `util_vector_logic_0` NOT-gate off `axi_ad9361_rst`) — reusing the exact same clock/reset path, not an easier one.
- `system_ila_0` probe0 → `count[15:0]` (full 16-bit counter, was the discriminator's `m_axis_tdata`).
- `system_ila_0` probe1 → `aresetn` (not `count[15]` as originally planned — Vivado's IP Integrator can't drag-connect a single bit out of a multi-bit bus without an explicit `xlslice` utility IP in between, so direct-connect to `count[15]` wasn't possible in the GUI). `aresetn` is an equally-good substitute: confirms the reset path itself isn't stuck low, independent of whether the counter is toggling. No ILA reconfiguration needed either way (both are 1-bit, matching the existing probe1 width).

**Not yet done — exactly where to resume if the session drops:** Generate Output Products on the modified `system.bd` → rebuild bitstream → JTAG-program → open ILA dashboard in Hardware Manager, "Run Trigger Immediate" (no trigger condition needed for a free-running signal) → check probe0 for a clean monotonic ramp and probe1 steady high. This is the actual Step 1a hardware test the whole plan above was building up to.

### Step 1a hardware result (2026-08-01) — debug chain PROVEN SOUND, root cause narrowed to a software-gated reset

First attempt after rebuild: ILA showed constant 0 on both probes. **Turned out to be a false alarm from an idle/never-triggered capture**, not a real result — Capture status read "Window sample 0 of 16384" (0 of 16384 samples actually captured), because the configured trigger condition (`util_vector_logic_0_Res == 0`, a level condition that was likely already true before arming) never fired. Lesson: always check Capture status reads `Full` / `N of N samples` before trusting anything the waveform pane shows — a flat display can just mean "never captured," not "signal is flat."

**Re-ran with trigger condition removed ("don't care") — got a genuine `Full`, `16384 of 16384` capture.** This alone answers Step 1a's core question: **the ILA/dbg_hub capture chain is proven sound on the `rx_clk` (`axi_ad9361_l_clk`) domain.** Reasoning: `system_ila_0`'s own sampling clock sits on that exact same net — if the clock weren't toggling, the ILA could never have advanced its buffer to a completed 16384-sample capture at all. So every AD9361-focused theory from the previous session's dead end is back on the table with confidence the observation tool itself works — the entire multi-hour "did we ever get a real capture" ambiguity from 2026-07-26/27 is resolved.

**What the real capture showed:** `gmsk_step1a_ila_coun_0_count` = constant `0000`, `util_vector_logic_0_Res` (i.e. `aresetn`) = constant `0`, across all 16384 real samples. The counter isn't broken — it's correctly held in reset. `axi_ad9361_rst` (the signal `util_vector_logic_0` inverts to make our `aresetn`) is an **internally-generated reset output of the `axi_ad9361` IP core itself**, which per ADI's driver model is normally released during AD9361 PHY bring-up (SPI/ENSM config) — i.e. it's gated by software having run, not something that self-releases on power-up.

**Tested the hypothesis directly:** copied `rx.c`/`rf_params.h` to the ZedBoard (`192.168.1.104`, current IP as of today — see [[project_sdr_devices]]), compiled natively (`gcc -O2 -liio -lm`), ran it. **Reproduced last session's exact behavior: PHY config step ("Configuring AD9361 RF front-end...", RX LO/buffer creation) completed successfully, then it failed at the same `iio_buffer_refill error: -110`, process exited cleanly (exit code 0).** Re-checked the ILA afterward with a genuine `Full`/`16384 of 16384` capture (not the earlier never-triggered false alarm) — `Res` still read a flat 0. **Conclusion: `rx.c`'s PHY config does NOT release `axi_ad9361_rst`.** It only talks to the SPI-based `ad9361-phy` chip config — a different register space entirely from the FPGA-side `axi_ad9361` core's own control block.

**Root cause found by reading the RTL directly** (`library/axi_ad9361/axi_ad9361_rx.v` → `library/common/up_adc_common.v:239,578`): `assign adc_rst = ~adc_rst_n`, where `adc_rst_n` is a cross-clock-domain copy of a register bit literally named `up_resetn` (`up_adc_common.v:239`, `up_wdata[0]` of an ADI `up_xfer_cntrl`-transferred control register) — a **deliberately software-gated reset** per the RTL's own comment: *"De-assert adc_rst together with an updated control set... important at start-up when a stable set of controls is required."* This bit is normally written once by the **Linux `cf_axi_adc` kernel driver's `probe()`**, not by anything userspace/libiio touches.

**`dmesg` explained why it was never written for our bitstream:** `cf_axi_adc 79020000.cf-ad9361-lpc` probed successfully at `[ 3.217308]` — 3.2 seconds into boot, i.e. against the bitstream loaded from the SD card's `BOOT.BIN` at boot time, NOT our custom `hdl_2026_r1` build (which loads later, live, via JTAG). **Loading a new bitstream via JTAG reinitializes every fabric flip-flop to its power-on value, silently wiping `up_resetn` back to 0 — invisible to Linux, so nothing re-triggers the driver's `probe()`.** This coherently explains everything: why Step 0's `devmem` registers always worked fine (we write fresh values ourselves, no dependency on stale pre-JTAG state), why `cf_axi_adc`'s dmesg line looked like success (it was, just against the wrong/earlier bitstream), and very plausibly the original `-110` DMA mystery itself (a reset-held ADC datapath produces no data for DMA to complete on).

**Fix confirmed live on hardware (2026-08-01):** `echo 79020000.cf-ad9361-lpc > /sys/bus/platform/drivers/cf_axi_adc/unbind` then `.../bind` (same technique tried last session, but that attempt had no way to confirm whether it worked — this time the ILA proved it directly). Unbind and bind both completed in well under a second, no hang (unlike last session's unpredictable 20–90s hangs on similar operations). Fresh `dmesg` line confirmed a real re-probe at `[9758.012153]` (vs. the original `[3.217308]`). **ILA capture (`iladata.csv`, exported by Vivado, landed in `hdl/gmsk_step1a_ila_counter/ip_repo/gmsk_step1a_ila_counter/`, gitignored — not source, safe to leave/delete) caught the exact transition on sample 8192:** `Res` flips 0→1 (TRIGGER marker fires on this exact sample), `count` reads `0000` that cycle then `0001, 0002, 0003...` incrementing by exactly 1 every single subsequent cycle with zero glitches through to `1fff` at the last sample (16383). **This is unambiguous, hardware-confirmed proof of the entire chain:** the counter/clock/reset wiring/ILA/dbg_hub are all completely correct, `axi_ad9361_rst` really is gated by `up_resetn`, and `cf_axi_adc` unbind/rebind really does re-release it.

**Step 1a is essentially answered and then some** — not only is the debug-capture chain proven sound (the original goal), the exercise surfaced and hardware-confirmed the actual root cause of Step 1's original DMA mystery. Re-ran `rx.c` after the `cf_axi_adc` rebind: **`-110` still occurred.** `up_resetn` release alone wasn't sufficient — real progress though, since it hardware-eliminates `axi_ad9361`'s own reset as the (sole) cause and narrows the remaining suspect to the DMA engine itself.

**`axi_dmac` has an exactly analogous software-gated mechanism.** `library/axi_dmac/axi_dmac_reset_manager.v` has a `ctrl_enable` input driving a multi-clock-domain (`dest_clk`/`src_clk`/`sg_clk`) enable/reset sequencer — same pattern as `axi_ad9361`'s `up_resetn`, normally written once by the Linux `dma-axi-dmac` driver's `probe()`. Same theory: JTAG-swapping the bitstream after boot wipes this too, and nothing re-triggers a re-probe.

**Attempted unbind/rebind of the three `dma-axi-dmac` instances (`7c420000.dma`, `7c400000.dma`, `43000000.dma`) — hit a real kernel bug, not just slowness.** First instance unbound instantly (0.003s). Second (`7c400000.dma`) triggered a **NULL-pointer kernel oops**:
```
Register r11/r12 information: NULL pointer
dma_channel_rebalance from dma_async_device_unregister+0x6c/0x114
dma_async_device_unregister from axi_dmac_remove+0x2c/0x48
axi_dmac_remove from platform_remove+0x40/0x5c
```
This is a genuine bug inside the Linux dmaengine framework's `dma_channel_rebalance()`, hit via `axi_dmac`'s `.remove()` path — a materially different, more serious class of problem than last session's "slow but always recovers" unbind/rebind hangs on `cf_axi_adc`. The third instance (`43000000.dma`) was almost certainly never reached — the shell process running the loop (`bash pid 20414`) appears to have been the one killed by the oops. **Conclusion: do not unbind/rebind `dma-axi-dmac` instances directly — this can crash the kernel.** `cf_axi_adc` unbind/rebind (the `axi_ad9361` fix) remains safe; this is specific to `axi_dmac`'s driver.

**Board power-cycled to recover (2026-08-01).** Confirmed clean boot afterward: no `mmcblk0` errors, no oops/panic residue, all IIO contexts enumerate correctly — the crash didn't leave lasting damage, a reboot fully clears it. **Re-tested `rx.c` against the fresh stock bitstream (not yet re-JTAG'd): ran the full 15s with continuous successful `iio_buffer_refill` calls, real ΔP readings streaming throughout, zero DMA errors.** This conclusively isolates the entire problem to our custom bitstream's post-JTAG-reprogram register state — the SD card, kernel, and board are all completely healthy.

**Where this leaves the investigation:** the robust fix is almost certainly to stop live-JTAG-swapping the bitstream into an already-booted kernel altogether, and instead bake `system_top.bit` into a persistent `BOOT.BIN` (via a matching FSBL export + `bootgen`) so it's present in the fabric from cold boot, before any driver ever probes — eliminating this entire class of "driver configured against stale/wrong bitstream state" bug for both `axi_ad9361` and `axi_dmac` at once, permanently. This has been an outstanding TODO since 2026-07-19 (see [[project_sdr_devices]] item 2).

## Persistent BOOT.BIN built and deployed — DMA mystery fully resolved (2026-08-01)

Chose the permanent fix over the faster/narrower `devmem`-poke alternative. Built end-to-end in one session using tooling already installed alongside Vivado 2025.2 (`C:\AMDDesignTools\2025.2\Vitis`, confirmed present — `bootgen.bat`/`xsct.bat` under `Vitis/bin`). Recipe lives at `hdl/boot_build/` (git-tracked: `export_hw.tcl`, `build_fsbl.py`, `boot.bif`; the generated `.xsa`/`.bin`/FSBL build tree are gitignored — regenerable, not source).

**Steps (each independently verified before moving on):**
1. **`.xsa` export**: `vivado -mode batch -source export_hw.tcl` → `write_hw_platform -fixed -include_bit -force` on the `fmcomms2_zed` project. Succeeded cleanly, ~1MB `.xsa` bundling `system_top.bit`.
2. **U-Boot reuse, no rebuild needed**: no standalone `u-boot.elf` was available anywhere locally. Instead: copied the *current working* `/boot/BOOT.BIN` off the board, ran `bootgen -arch zynq -read BOOT.BIN.orig` to dump its partition header table (word-based offsets/lengths), and `dd`-extracted the `u-boot_zynq_zed.elf` partition's raw bytes directly (offset `0xa06d0` words = byte 2628416, length `0x1fb62` words = 519560 bytes — sanity-checked: `2628416+519560` = exact file size, confirming it's the last partition, extraction correct). This raw blob gets referenced in the new `.bif` as `[load=0x04000000, startup=0x04000000] uboot_extracted.bin` — bootgen accepts a flat binary with explicit load/startup addresses just as well as an `.elf`.
3. **FSBL build via Vitis's modern Python API** (`xsct`'s classic Tcl `platform`/`app` commands are deprecated in 2025.2 and its `platform create` hung/timed out trying to spawn a backend — pivot to `vitis -s <script>.py` instead, using the `vitis` Python module). Key discovery: `client.create_platform_component(os="standalone", cpu="ps7_cortexa9_0", ...)` for a Zynq PS design **auto-generates a `zynq_fsbl` boot domain as part of platform creation** — no separate `create_app_component` call needed (an attempt at that failed: `AttributeError: 'Platform' object has no attribute 'startswith'`, since it expects a platform *name string*, not the object, and the FSBL sources already exist by then anyway). Just `platform.build()` compiles it. Output: `fsbl_ws/fsbl_platform/zynq_fsbl/build/fsbl.elf`. Hit one workspace-lock error from a crashed prior attempt (`.wsdata/.lock` + orphaned `java.exe` backend processes) — killed the stale processes, deleted the lock, retried clean.
4. **`bootgen`** combined all three into the new `BOOT.BIN` (`.bif`: `[bootloader] fsbl.elf`, bare `system_top.bit`, and the load/startup-addressed `uboot_extracted.bin`). `-read` on the output confirmed all three partitions present by name. 4.7MB vs the original 3.1MB (our bitstream is bigger uncompressed — not a concern).
5. **Deployed via the already-live `/boot` mount** (no SD card swap needed — it's mounted `rw` on the running Linux the whole time): backed up the original to `/boot/BOOT.BIN.stock_backup` on-board (plus a local copy already saved as `BOOT.BIN.orig`), `pscp`'d the new one over `/boot/BOOT.BIN`, `sync`'d, rebooted.

**Verified on the actual cold boot:** `busybox devmem 0x40000000` → `0x474D534B` (Step 0's ID register, confirming our custom bitstream — not the stock one — was in the fabric from power-on) and the counter incrementing. `dmesg` showed `cf_axi_adc` probing at `[3.224560]` **against our fabric this time**, not a stale/earlier one. **Ran `rx.c`: full 15 seconds, continuous real ΔP readings, zero `-110` errors** — identical clean behavior to the stock-bitstream test, but now on our custom design, loaded the "right" way (cold boot, not live JTAG swap).

**This fully resolves the multi-session DMA investigation.** Root cause confirmed end-to-end: live-JTAG-swapping a bitstream into an already-booted kernel silently wipes software-gated reset state (`up_resetn` in `axi_ad9361`, and whatever `axi_dmac`'s `ctrl_enable`-driven reset-manager needed too) that drivers only ever write once, at their own `probe()` time — invisible to Linux, no automatic re-probe. Baking the bitstream into `BOOT.BIN` sidesteps the entire class of bug, permanently, for every core in the design at once — not just the two we happened to isolate. **No more manual `cf_axi_adc` unbind/rebind needed before RX software going forward** — DMA now just works, every boot.

**Where this leaves Step 1 hardware validation:** the infrastructure blocker (DMA reliability) that stalled the whole investigation since 2026-07-26 is gone. The remaining gap is unrelated to any of this: `gmsk_step1_discriminator` was removed from the block design earlier in this same session (noted 2026-08-01, while wiring Step 1a) and never re-added. **Next step, exactly where to resume:** re-add and rewire `gmsk_step1_discriminator` into the block design (same clock/reset/AXI-Stream wiring documented earlier in this file), rebuild, and — since `BOOT.BIN` is now the deployment path — either JTAG-program for a quick iteration (fine for one-off testing, just remember the old caveats don't apply to a *final* baked-in build) or rebuild+redeploy `BOOT.BIN` for a durable test, then run `rx.c` against real transmitted FSK data and check the discriminator's output on the ILA per the original Step 1 hardware test plan.

## Key concept to remember

The bottleneck is **NOT the GMSK math** — it's learning Vivado's IP Integrator and the AXI-Stream protocol. That is the actual learning curve. The Gaussian filter math and phase accumulation are straightforward once the plumbing is understood.

## Future option noted (not yet decided, 2026-08-01): no-OS bare-metal Vitis app instead of Linux

Pari has a local clone of ADI's `no-OS` repo at `C:\Users\Parit\Documents\Projects\Non-OS Ad9361\no-OS`. It has a ready-made `projects/ad9361` example with a `boards/iio/zed.conf` matching this exact board+design combo (`CONFIG_XILINX_HDL_DESIGN="fmcomms2"`), plus `dma-example`/`dma-irq-example` variants.

**Why it's appealing:** a no-OS build is a bare-metal Vitis app — no Linux, no kernel driver `probe()` timing, no `dmaengine` framework — so it sidesteps the entire class of bug this session fought (stale driver state after a live JTAG swap, the `dma_channel_rebalance` kernel oops). Talks to `axi_ad9361`/`axi_dmac` directly via register access instead.

**The tradeoff:** it's a different stack from everything built so far (`rx.c`, the SSH/`dmesg`/`devmem` debug workflow) — moving to no-OS means Linux stops booting on this board entirely; FSK/GMSK demod logic would need porting to no-OS's C API rather than reusing `rx.c` as-is.

**Checked no-OS's own network support for remote access without Linux:** its `network/lwip_raw_socket/netdevs/` only covers ADI's own SPI-based Ethernet chips (`adin1110`, `w5500`) — nothing for the ZedBoard's onboard native Gigabit Ethernet (Zynq's GEM + Marvell 88E1510 PHY, `xemacps`, which doesn't appear anywhere in the current no-OS working tree). The realistic path for networking on a bare-metal ZedBoard app would be **Xilinx's own Vitis lwIP library** (bundled with Vitis, added as a platform library component using `xemacps`) — separate infrastructure from no-OS's own network folder.

**Decision deferred until after Step 1 hardware validation succeeds on the current Linux/`BOOT.BIN` stack** — not pursuing this now, just recorded as a real option worth revisiting.

## Discriminator re-added, real-hardware bug found and fixed (2026-08-01)

Re-added `gmsk_step1_discriminator` to the block design after Step 1a removed it, rewired identically to before (`aclk`/`aresetn` on the same nets, `s_axis_tvalid`←`adc_valid_i0`, `s_axis_tdata`←`xlconcat_0`, `m_axis_tready`←`xlconstant_0`, `probe0`/`probe1`←`m_axis_tdata`/`m_axis_tvalid`) — verified correct by reading `system.bd` directly before rebuilding. Rebuild's ATF hit `WNS -0.335ns` (worse than the earlier accepted `-0.012ns`), but the worst path is entirely inside `system_ila_0`'s own encrypted netlist (debug-only, same low-risk category as before) — deployed anyway via the `BOOT.BIN` recipe (regenerate `.bif` unchanged since it references the same `system_top.bit` path, `bootgen`, `pscp` to `/boot/BOOT.BIN`, reboot). Confirmed on cold boot: Step 0 ID register correct, `cf_axi_adc` probed clean.

**Live RF test set up:** `tx_dma_fsk` cross-compiled on the ZedBoard (has `gcc`; Pluto+'s Buildroot image doesn't) and relayed to Pluto+ via cat-over-SSH (no SFTP server there), running in the background transmitting `HELLO SDR` continuously. `rx.c` run on the ZedBoard confirmed clean reception (~±20dB ΔP swings, UART bytes decoding) — the RF link itself was never in question.

**Found and fixed a real bug via direct ILA data analysis, not just eyeballing the waveform.** First capture at RX gain=40dB showed `m_axis_tdata` swinging only 0–4 — traced this to the discriminator's fixed 17-bit output truncation combined with real (non-full-scale) AD9361 sample amplitude (~1000, vs. the sim's near-full-scale synthetic test vectors) — a legitimate gain/precision mismatch, not a bug. Bumped RX gain live via sysfs (`in_voltage0_hardwaregain`, range `[-1, 73]` dB) from 40→50 without restarting `rx.c` (it only sets gain once at startup, so a live sysfs write sticks). Values got visibly bigger, user reported "it is working" — **but pulling the actual capture CSV and cross-tabulating by `tvalid` showed something different: all 4,096 samples where `tvalid=1` were exactly 0, and the nonzero values (27, -2, 26...) the user was seeing only occurred when `tvalid=0`** (invalid/don't-care samples). Ground-truth data contradicted the visual impression.

**Root cause, traced through the RTL:** the delay-line's `i_d2 <= i_d1` shift was gated by a separately-delayed `valid_d0`, firing exactly one cycle after `i_d1` itself had *already* updated to that same new sample — so `i_d2` duplicated `i_d1` instead of holding the genuinely previous sample, whenever idle cycles separated valid pulses (which real AD9361 data always has — sparse ~2.3 Msps strobes within a 250 MHz fabric clock). Two identical I/Q pairs cancel exactly to zero in `Q[n-1]*I[n-2] - I[n-1]*Q[n-2]`, matching the hardware symptom precisely. **The simulation testbench never caught this because it drove `s_axis_tvalid` high on every single clock with zero gaps** — a fundamentally different stimulus pattern than real hardware, which fully masked the bug through every prior SIM-gate pass.

**Fix:** made the `i_d1`→`i_d2` shift atomic (single condition, both updates in the same always-block branch, so `i_d2` captures `i_d1`'s pre-update value per Verilog non-blocking-assignment semantics) instead of splitting it across two cycles via the separate `valid_d0` flop. Latency dropped from 4 cycles to 3 as a side effect. **Also rewrote the testbench** to drive gapped valid pulses (`GAP_CYCLES=3` between samples, not back-to-back) and self-synchronize its capture loop to `m_axis_tvalid` pulses rather than a fixed cycle-latency offset — so this class of bug will get caught in sim next time, not just via real-hardware ILA forensics. Re-ran the SIM gate: identical clean result (MARK 1213.0 / SPACE 414.0, ratio 2.93) now genuinely validated under gapped stimulus. Repackaged the IP.

**Lesson reinforced for this whole project:** always cross-tabulate captured data by its own valid/trigger signal before trusting a visual read of a waveform — this is the second time in one session (after the Idle/`0 of N` false-triggered-capture issue) that "it looks like it's working" turned out to need the raw exported CSV to actually confirm or refute.

**Redeployed and re-tested (2026-08-01) — fix confirmed on real hardware.** Rebuilt (this time timing closed cleanly, `WNS +0.016ns`, SUCCESS after 0 ATF attempts — better than before the fix, suggesting the atomic-shift RTL change also helped placement/routing), redeployed via the `BOOT.BIN` recipe.

**Built two new debug tools to get a clean, unambiguous test signal, both in git:**
- `tx/tx_gmsk_debug.c` — continuous Gaussian-shaped `1,0,1,0,...` transmitter, same MARK/SPACE tones as `tx_dma_fsk.c` (so everything already calibrated against those tones stays valid), precomputes one full period as a phase-continuous buffer and plays it via a libiio **cyclic** buffer (hardware repeats it forever, zero further CPU/DMA involvement) — a genuine "LUT" in the sense the user asked for. Circular convolution (not plain) is required for a glitch-free loop: an equal +1/-1 NRZ count integrates to exactly zero net phase over one period, so the hardware wrap-around is phase-continuous. `GMSK_BT` controls smoothing (**inversely** — higher BT = narrower kernel = less smoothing = more dwell time at the true tones; this is the opposite of what "BT" sounds like it should do, tripped up an initial "lower BT to reduce smoothing" request). Settled on `BT=4` after starting at `0.8` (too smoothed — kernel half-width was ~0.66 bit periods, meaning the signal never really settled anywhere for a maximally-alternating pattern); `BT=4` narrows that to ~0.13 bit periods.
- `rx/rx_spectrum_check.c` — framing-free MARK/SPACE Goertzel power check (reuses `rx.c`'s exact Goertzel code, strips out all the UART/frame state machine, which has nothing to lock onto against this bare unframed pattern anyway). Averages over ~1s and prints once/second — a clean software-side signal, independent of both `rx.c`'s framing assumptions and the FPGA discriminator.

**Cross-rootfs deployment gotcha:** binaries built on the ZedBoard's Kuiper/Yocto image and relayed to Pluto+'s Buildroot image can hit `GLIBC_2.29 not found` at runtime if they use certain newer-versioned libm symbols — hit this specifically with `exp()` (traced via `objdump -T <binary> | grep GLIBC`, confirmed only `exp` needed 2.29, nothing else). Fix: `expf()` instead of `exp()` for anything that doesn't need double precision (a Gaussian smoothing kernel doesn't) — dropped the max required version to `GLIBC_2.27`, which Pluto+ has. `tx_dma_fsk.c` never hit this because it only ever used `cos`/`sin`/`atan2`/`lrint`, which happen to not be affected.

**`rx_spectrum_check` first showed a large, consistent SPACE-dominant bias (`-13` to `-17dB`, never crossing to MARK) at `BT=0.8`.** Verified the TX signal generation itself was NOT the cause by re-running the filter/frequency math standalone (no hardware touched) — confirmed `filtered[]` symmetric (min `-0.995`/max `+0.995`/mean `0.000000`), frequency range spanning nearly the full `50–150kHz` target, and samples above/below center split exactly `50/50`. The bias was a measurement/signal mismatch: Goertzel is a narrowband steady-state estimator, but at `BT=0.8` the signal was continuously sweeping rather than settling at either tone, which a steady-state estimator isn't well suited to reading cleanly. **Bumping to `BT=4` cut the bias roughly in half** (`-5` to `-7.6dB`), consistent with the hypothesis. The small residual bias is plausible normal zero-IF receiver behavior (SPACE at 50kHz sits closer to DC/LO-leakage than MARK at 150kHz) rather than a bug anywhere in this chain.

**Final ILA capture against the `BT=4` signal, valid-gated (`iladata4.csv`): genuinely bimodal, matching physical expectation** — 2,659 samples clustered near SPACE (0–6, matching the earlier ~3–4 baseline calibration), 862 clustered near MARK (13+, roughly 3–4x the SPACE level — consistent with the ~2.93x MARK/SPACE ratio from the original simulation), 575 in a mid-sweep transition band (expected for a continuously Gaussian-swept signal, not two discrete levels). **This confirms the discriminator fix end-to-end on real hardware with a real modulated signal** — genuine, non-zero, non-flat, physically-consistent output.

**Where this leaves things:** the discriminator IP itself is now validated correct on real hardware. Not yet done: testing against the *original* framed `tx_dma_fsk.c`/`rx.c` signal (ASCII data, not the bare debug pattern) to confirm the fix holds for the actual intended use case, and beginning Step 2 (block-design integration planning) / Step 3 (the actual GMSK demodulator logic beyond just the discriminator) per the milestone sequence at the top of this file.

## Fast-bitrate debug mode, a real phase-glitch bug, and a dynamic-range fix (2026-08-02)

Pari wanted to actually see several MARK/SPACE transitions within a single ILA capture (65.5us) instead of the ~3% of one 2ms bit the original slow signal covered — added `SAMPLES_PER_BIT=4` (~576kbps) to `tx_gmsk_debug.c` as a debug-only override, with `PATTERN_BIT_PAIRS` bumped to 72 (576 samples/period) specifically to keep `total_samples` a multiple of 576 — see [[project_fpga_gmsk_plan]]'s existing note on why that matters: it's the condition for the center frequency's phase to land on a whole multiple of 2*pi over one period, i.e. a glitch-free cyclic-buffer loop. Caught a real bug here: at `PATTERN_BIT_PAIRS=16` (128 samples), that condition silently broke, producing a genuine phase-discontinuity glitch at every wrap — with a period that short (~55.6us, close to the capture window itself) it would have shown up in nearly every ILA capture, easily mistaken for real signal. Turned the previously-cosmetic "net phase" diagnostic into an actual check that refuses to transmit if the wrap isn't clean (>0.01 rad tolerance).

**Verified interactively, not just by eye.** Built a Chart.js widget with an autocorrelation-based period estimate plus a scrubber (window start/size sliders) over the full 4096 valid-gated samples, since a static plot wasn't enough to confidently answer "is this actually periodic." This is a good general pattern for future ILA-data verification in this project — plot it, don't just eyeball the Vivado waveform pane.

**Pari's diagnosis of the resulting weak/noisy-looking periodicity was correct and led to a real fix, not just cosmetics.** Increased TX power (`tx_gmsk_debug.c`'s `DEBUG_TX_ATTENUATION_MDB`: -20dB → -3dB, near max) and widened RX bandwidth (`rx_spectrum_check.c` and `tx_gmsk_debug.c` both already had `DEBUG_RF_BANDWIDTH_HZ=4MHz` in source, but a deploy mistake — forgetting to `pscp` the edited `rx_spectrum_check.c` before rebuilding on the board — meant the RX side kept running on stale 400kHz bandwidth for a while; always verify a live sysfs value after a "rebuild", a recompile of stale source silently succeeds). **Result: valid-gated dynamic range roughly doubled, `-2..25` (range 27) → `-5..51` (range 56)**, with visibly cleaner, better-separated peaks. Per [[feedback_debug_tools_freedom]], went well past `rf_params.h`'s original values (400kHz BW, -20dB TX atten) without hesitation since this is standalone debug tooling, not the real link.

**Where this leaves things:** dynamic range has headroom before the 16-bit signed ceiling if more is wanted (e.g. a further RX gain bump now that a real baseline exists). This debug-signal work (fast bitrate, phase-continuity, TX/RX power tuning) is separate from and doesn't block the discriminator-fix validation above — both are done and confirmed working together on the same live hardware.

## Context for Win11/WSL setup

Pari is moving from Ubuntu (where SDR_Link was developed) to Win11 with WSL. The SDR_Link source is at `/home/pari/SDR_Link/` on the Ubuntu machine. On Win11/WSL, Vivado should be installed natively on Windows (not inside WSL) — Vivado's GUI and cable drivers don't work well from WSL. Use WSL only for git/text editing; launch Vivado from the Windows Start menu.
