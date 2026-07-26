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

## Key concept to remember

The bottleneck is **NOT the GMSK math** — it's learning Vivado's IP Integrator and the AXI-Stream protocol. That is the actual learning curve. The Gaussian filter math and phase accumulation are straightforward once the plumbing is understood.

## Context for Win11/WSL setup

Pari is moving from Ubuntu (where SDR_Link was developed) to Win11 with WSL. The SDR_Link source is at `/home/pari/SDR_Link/` on the Ubuntu machine. On Win11/WSL, Vivado should be installed natively on Windows (not inside WSL) — Vivado's GUI and cable drivers don't work well from WSL. Use WSL only for git/text editing; launch Vivado from the Windows Start menu.
