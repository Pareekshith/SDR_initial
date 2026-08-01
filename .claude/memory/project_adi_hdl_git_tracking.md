---
name: project-adi-hdl-git-tracking
description: "ADI_hdl (sibling dir to SDR_initial) is now git-tracked on a local branch + pushed to its own GitHub repo, since ADI's own .gitignore hides the actual project state"
metadata:
  type: project
  originSessionId: 52a39ff6-64f3-461c-ad8f-93cf825d7f3a
---

## Setup (2026-07-27)

`ADI_hdl` (the sibling directory holding the Vivado `fmcomms2_zed` project — see [[project_fpga_gmsk_plan]]) is a clone of ADI's public hdl repo. Discovered that despite months of Step 0/Step 1 hardware work, **`git log` showed zero local commits** — everything was sitting uncommitted on top of ADI's `hdl_2026_r1` branch, invisible to `git status` because ADI's own `.gitignore` blanket-ignores `*.xpr`, `*.srcs` (contains `system.bd`, the actual IP Integrator block design with all manual wiring), and `component.xml`. That ignore file assumes a "regenerate everything from tracked Tcl scripts" workflow, which isn't how this project has been worked (heavy interactive GUI/Connection-Automation wiring).

**Why:** Pari wants ordinary git traceability for Vivado project changes (block design wiring, IP packaging, timing fixes) without a scripted Tcl-export pipeline — a normal `git add -A && git commit` workflow, same as [[project_fpga_gmsk_plan]]'s SDR_initial habits.

**What was done:**
- New local branch `zed-gmsk-work` created off `hdl_2026_r1` (keeps local work off ADI's own branch name).
- Added a **nested** `.gitignore` at `ADI_hdl/projects/fmcomms2/zed/.gitignore` (scoped to just this one project dir, doesn't touch the top-level repo-wide `.gitignore` that governs ADI's other ~100 projects) that un-ignores `fmcomms2_zed.xpr` and the `fmcomms2_zed.srcs/` tree (block design, `.xci` IP customizations, wrapper verilog), while still excluding genuinely regenerable output: `.runs/`, `.sim/`, `.cache/`, `.Xil/`, `.ip_user_files/`, and the ATF-imported synthesis checkpoint (`utils_1/imports/synth_1/*.dcp`).
- First commit made capturing the state as of Step 0 + Step 1 (discriminator wiring, both timing fixes) — 50 files, block design + all `.xci` + `.xpr`.
- New **private** GitHub repo created by Pari: `github.com/Pareekshith/AD9361_FPGA_Rx_GMSK_test` — added as remote **`mine`** (HTTPS, not SSH — no SSH keypair/known_hosts set up on this machine; `origin` stays on ADI's upstream HTTPS URL for pulling future ADI updates). `zed-gmsk-work` pushed and tracks `mine/zed-gmsk-work`.
- Note: pushing a branch here pushes ADI's *entire* history including their LFS-tracked doc images (~6MB) — expected, not something we added, trivial against GitHub's free LFS quota.

**How to apply:** From now on, after any meaningful Vivado checkpoint (wiring change, successful bitstream build, IP repackage) in `ADI_hdl`, do a normal `git add -A && git commit` on the `zed-gmsk-work` branch — no Tcl-export ceremony. Push to `mine` periodically for backup (confirm with Pari before each push, per standing git-safety practice). If the nested `.gitignore` needs adjusting later (e.g. a new heavy generated subfolder shows up under `.srcs`), edit `ADI_hdl/projects/fmcomms2/zed/.gitignore` directly rather than touching the repo-wide one.
