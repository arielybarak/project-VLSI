# dpram72x128_cb — behavioral model notes

Distilled from the lab behavioral model `dpram72x128_cb.v` (deleted from the repo to save
space; in the lab kit). Timing numbers: [`dpram72x128_cb_timingP.vhd`](dpram72x128_cb_timingP.vhd).
Wrapper that instantiates it: [`special_mem_dpbank.sv`](../../special_mem_dpbank.sv).

## What the model is

- Dual-port sync SRAM, 128 deep × 72 bit. Port 1 = write, Port 2 = read (in our use).
- Pins: `A` addr, `I` data-in, `O` data-out, `CEB` clock(active-low), `WEB`/`CSB`/`OEB` (write/chip/output enables, active-low).
- **No separate clock pin — `CEB` is the clock.**

## The two facts that matter (confirmed from the model source)

1. **Active edge = `negedge CEB`.** The one functional block is `always @(negedge ck_state)`
   (ck_state = CEB), and every `$setup`/`$hold` is referenced to `negedge CEB`.
2. **Read output is REGISTERED, not combinational.** Inside that block:
   ```verilog
   always @(negedge ck_state) begin
       memoryAddr = address;                 // address sampled here
       if (no_sh_error) int_bus = memoryOut; // read data LATCHED (blocking '=')
   end
   assign o_state = int_bus;                 // O2 follows the latched reg
   ```
   `int_bus` holds the read data from one `negedge CEB` until the next — i.e. valid for a
   **full cycle**.

## Why this drives every timing decision

### The half-cycle wall (~307 MHz)
- We drive `CEB = clk`, so the macro works on **negedge clk** while our datapath flops are
  **posedge** — opposite edges (on purpose: see race below).
- Read address path: posedge launch → negedge capture = **½ cycle**.
- Read data path: negedge launch (`int_bus`) → posedge capture (`rd_raw_pipe`) = **½ cycle**.
- The access time `tACC0 = 1.629 ns` must fit in that half cycle:
  `period/2 ≥ 1.629` → `period ≥ 3.26 ns` ≈ **~307 MHz** (before routing). Matches why 3.6 ns
  passes and tightening below ~3.3 ns fails.

### Why `~clk` is NOT a fix (simulation race)
- `~clk` would put `negedge CEB` on our **posedge clk** (same edge as our flops).
- The macro updates its output `int_bus` with a **blocking** assign on that edge, while our
  capture flop reads it (non-blocking) on the same edge → **nondeterministic race**
  (capture gets old or new data, run/tool dependent).
- The racer is **inside the macro**, so deleting our own registers cannot fix it.
- Today it's race-free only because macro (negedge) and capture (posedge) are on **opposite
  edges**. The half-cycle is the price of that safe crossing.

### The real path to 400 MHz: multicycle read
- `int_bus` holds for a **full cycle**, so if the read **address is held stable** (reads are
  already `done`-gated) or pipelined, the data stays valid across **1.5 cycles**.
- Capture one posedge later + `set_multicycle_path 2 -setup` on the read → the access gets
  ~1.5 cycles. Then the SRAM no longer limits until `tCYC` (below).
- Keeps `CEB = clk` (edges unchanged) → **no race, sim stays correct**. Cost = +1 read-cycle
  latency, already masked by the idle-cycle prefetch in `special_memory.sv` (≈lines 395–424).

## Frequency ceilings (from `tCYC` / `tACC0`)
- `tCYC = 2.2046 ns` → SRAM max ≈ **453 MHz**. **500 MHz is physically impossible.**
- `tACC0 = 1.629 ns` access. Fits a full cycle easily; only the half-cycle phasing caps it at ~307 MHz.
- Setup tiny (`tAS=0, tIS=0.025, tCSS=0.294`), hold big (`tAH≈0.4, tIH≈0.38`): the macro is
  easy to drive directly (setup), and combinational delay before it covers the hold.

## Decision summary

| Approach | Sim | 400 MHz? |
|---|---|---|
| `~clk` | nondeterministic race | no — broken |
| delete our registers | doesn't remove the macro's internal latch | no |
| **multicycle read (hold addr + 1 extra reg + SDC)** | safe (edges unchanged) | **yes, up to ~453 MHz** |
| accept the wall | safe | no — ceiling ~307 MHz |
