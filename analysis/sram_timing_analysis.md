# SRAM macro timing — analysis & frequency ceiling

**Macro:** `dpram72x128_cb` (data/strb) + `dpram16x256_cb` (parity), Tower TS18SL kit.
**Instances:** `u_ram_128x72_0..3` + `u_ram_256x16_parity` in [`special_mem_dpbank.sv`](../special_mem_dpbank.sv).
**Source numbers:** [`analysis/data/dpram72x128_cb_timingP.vhd`](data/dpram72x128_cb_timingP.vhd).

"Macro" = the SRAM hard block itself (pre-built by the memory compiler, not synthesized from gates).

## Characterized timing (from the timing package)

| Term | Value | Meaning | Generic name |
|---|---|---|---|
| `tCYC` | **2.2046 ns** | min cycle time of the SRAM | min cycle |
| `tACC0` | **1.62947 ns** | active edge → read data valid | t_pd (access) |
| `tAS / tIS / tCSS` | 0 / 0.025 / 0.294 ns | setup: addr / data-in / chip-sel | t_setup |
| `tAH / tIH / tWH` | 0.403 / 0.383 / 0.329 ns | hold: addr / data-in / write-en | t_hold |
| `tOE / tOEZ0` | 0.699 / 0.744 ns | out-enable → valid / → Z | — |
| `tOUTU` | 1.066 ns | output hold (valid until) | — |
| `tCLA / tCLP` | 0.204 / 0.363 ns | min clk pulse low / width | — |

## Key insights

### 1. Frequency ceiling: `tCYC = 2.2046 ns` → max ~453 MHz
- **500 MHz (2.0 ns) is physically impossible** — below the SRAM's own minimum cycle.
- **400 MHz (2.5 ns) is the realistic ceiling.** Adjust the project target accordingly (PDF asks 400–500; the SRAM caps it near 400).

### 2. Setup is tiny, hold is big
- Setup into the macro is near-zero (`tAS=0`, `tIS=0.025`, `tCSS=0.294`) → lots of room for logic *before* the macro on the write side.
- Hold is large (`tAH/tIH ≈ 0.4 ns`) → data must stay stable ~0.4 ns *after* the edge.
- **Consequence:** on the write/entrance side, the natural ID-match logic delay both fits (setup is free) and satisfies hold for free. A dedicated input pipe register is only needed for the half-cycle problem (see below), not for timing closure per se. If that pipe is removed, confirm the *fastest* path into the macro still exceeds ~0.4 ns hold (ID-match easily does).

### 3. The read access is the real 400 MHz wall — and it can't be pipelined away
- `tACC0 = 1.629 ns` is a combinational arc *inside* the macro (edge → output). No pipe/buffer/retime shrinks it.
- It must fit between the macro's launch edge and the capturing flop's edge.

## Why the design shows "half-cycle" paths

- `CEB` is the macro clock, wired active-low (`.CEB1(clk)`). There is **no separate clock pin**.
- Active-low → the macro's active edge is offset half a period from the rising-edge datapath flops.
- → logic into/out of the macro gets only `period/2`.
- With this phasing the read access caps frequency at:
  - `period/2 ≥ tACC0` → `period ≥ 2 × 1.629 = 3.26 ns` ≈ **~307 MHz** (before routing margin).
  - This is exactly why 4.0 ns passes and tightening below ~3.3 ns collapses.

## Options to reach 400 MHz (need macro + capture flop on the same edge)

| Option | Effect | Cost |
|---|---|---|
| `~clk` into `CEB` | full-cycle macro | inverted-clock domain → CTS + hold complexity; re-sim (phase shifts half cycle) |
| capture read on negedge flop | same full-cycle relation | same edge-domain complexity, on our side |
| `set_multicycle_path` on SRAM read (2 cyc) | access gets a full+ period, **no inverted clock** | +1 read-cycle latency (already masked by prefetch); SDC-only; reads are `done`-gated so addr is stable |
| do nothing | stays correct | hard ceiling ~307 MHz |

Preferred (no inverted clock): **multicycle-path** on the SRAM read — leverages the prefetch latency already paid for.

## Open verification

- Confirm the macro's active edge from the **behavioral** `.vhd` model (the `timingP` package has constants only). Needed before any `~clk` / multicycle change so the fix is provably correct and hold is checked.
