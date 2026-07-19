---
name: feedback-session-continuity
description: "User wants all progress silently logged to memory as-we-go, not just at session end, so any session can resume after an accidental termination"
metadata:
  type: feedback
---

Pari asked (2026-07-19) to always log progress to memory silently (no need to announce each save) as work happens, not batched at the end of a session.

**Why:** Sessions have terminated unexpectedly mid-project before (see [[project_fpga_gmsk_plan]]) and Pari wants any future Claude Code session — not just this one — to be able to pick up exactly where things left off, including hardware state (what's been JTAG-programmed, what's been verified working, credentials discovered) not just code diffs.

**How to apply:** During hands-on/hardware sessions (FPGA builds, board bring-up, SSH sessions to the SDR boards), update the relevant project memory file (e.g. [[project_fpga_gmsk_plan]], [[project_sdr_devices]]) after each meaningful step or discovery — not just at the end of the conversation. Don't wait to be asked. Keep it silent/terse — a brief note in the response is fine, but don't make a ceremony out of announcing the save.
