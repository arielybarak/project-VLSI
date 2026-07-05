# AXI Write Order Module

## Overview

An AXI3 **Write Order Control** module implemented in SystemVerilog. The module sits between AXI masters and slaves and enforces write transaction ordering policies — ensuring correct dependency management and data integrity while maintaining full throughput with no data-flow bubbles.

Developed across two semesters as a VLSI design project under the supervision of **Gil Stoler** (Amazon):

- **Project A** (Spring 2024) — baseline design and functional verification by **Bar Arama** and **Barak Ariely**.
- **Project B** (Spring 2025) — architectural scaling, storage optimization, and PPA improvements by **Barak Ariely**.

---

## Branches

| Branch | Description |
|---|---|
| [`project-A`](../../tree/project-A) | Frozen Spring 2024 baseline. Has its own README describing the original design. |
| [`project-B`](../../tree/project-B) | Spring 2025 optimized revision (default branch, you are here). |
| `main` | Original branch, retained for history. |

> To view the Project A design and its documentation, switch to the **`project-A`** branch.

---

## Transaction Types & Ordering Policies

The module classifies write transactions into three types:

1. **Regular** — no dependency, passes through freely.
2. **Block** — blocks all new transactions until it completes (DMB-like barrier).
3. **Special (Divert)** — delayed until all earlier transactions finish.

Additionally, an **Unlucky** transaction is a non-special transaction from the same master as a pending Special transaction. It must be delayed to preserve AXI same-ID ordering.

---

## Architecture

The module operates like a **highway traffic system** 🚦:

![Highway Traffic System Analogy](highway_traffic_system.png)

| Component | Role |
|---|---|
| **Process Memory** ("The Camera") | Tracks all in-flight transactions. Detects Block completion and decides when to release Special transactions from the pull-off area. |
| **Router** ("Exit & Merge Lanes") | Directs transactions — either passing them through or diverting to special storage. |
| **Special Memory** ("Pull-off Area") | Stores Special and Unlucky transactions. Manages classification, burst storage, and priority-based release. |

---

## Project A → Project B: What Changed

Project B scaled the design from 16 to 256 outstanding transactions and from 4 to 16 special slots, while significantly improving all PPA metrics.

### Architectural Changes

- **Storage optimization:** Burst payloads migrated from flip-flops to dual-port SRAM, reducing area and power.
- **Control logic redesign:** Linear shift-on-delete arrays replaced with occupancy bitmaps and age-matrix tracking, reducing maintenance complexity from O(N) to O(1).
- **Datapath pipelining:** Pipeline registers and skid buffers added to break critical timing paths without introducing data-flow bubbles.
- **End-to-end parity:** Full parity protection added across the datapath (`wuser`).

### Synthesis Results (vs. Project A Baseline)

| Metric | Project A (FF Baseline) | Project B (Final) | Change |
|---|---|---|---|
| **Frequency** | 182 MHz | 294 MHz | **+62%** |
| **Area** | 1,374,623 µm² | 986,806 µm² | **−28%** |
| **Combinational Cells** | 62,263 | 32,080 | **−48%** |
| **Dynamic Power** | 168.16 mW | 78.03 mW | **−54%** ¹ |

¹ Dynamic power figures were measured under different switching activity profiles. A rigorous comparison would require both netlists under the same annotated activity (SAIF/VCD).

---

## Repository Structure

### Environment & Licensing Note

> [!NOTE]
> This project was developed inside an academic VLSI laboratory environment. Due to IP licensing and NDA restrictions, proprietary foundry libraries, memory compilers, DesignWare primitives, and the simulation testbench environment are not included in this repository. The published source code represents the core SystemVerilog RTL architecture along with post-synthesis timing, area, and power reports.

### RTL Source (SystemVerilog)

| File | Role | New in B |
|---|---|---|
| `pkg.sv` | Parameters, structs, helper functions | |
| `axi_if.sv` | AXI3 interface definition | |
| `top.sv` | Outer wrapper with DesignWare FIFOs | |
| `WriteOrderTop.sv` | Core module — instantiates all submodules | |
| `process_mem.sv` | Transaction tracker ("Camera") | |
| `special_memory.sv` | Special/Unlucky storage ("Pull-off Area") | |
| `rout.sv` | Combinational router | |
| `age_order.sv` | Occupancy bitmap + age matrix | ✔ |
| `special_mem_dpbank.sv` | Dual-port SRAM wrapper | ✔ |
| `special_mem_dpbank_v2.sv` | Alternative SRAM wrapper | ✔ |
| `pipe_reg.sv` | Forward-registered pipeline stage | ✔ |
| `skid_buffer.sv` | AXI-compliant flow-control buffer | ✔ |
| `box_master.sv` | Burst sender (Project A only) | |

### Analysis (`analysis/`)

| Path | Contents |
|---|---|
| `analysis/results.yml` | Single source of truth for all result numbers |
| `analysis/data/` | SRAM timing characterization (`.vhd`, `.csv`) |
| `analysis/scripts/` | Python scripts for SRAM analysis |
| `analysis/plots/` | Generated SRAM comparison plots |

### Synthesis Reports (`reports/`)

Selected milestone reports from Design Compiler synthesis runs (area, power, timing).

### Toolchain (external — not included in this repo)

- **Simulation:** Ncsim / VCS
- **Synthesis:** Synopsys Design Compiler
- **Priority encoder:** DesignWare `DW_pricod`
- **SRAM primitives:** `dpram128x72`, `dpram256x16` (dual-port) — lab SRAM compiler
