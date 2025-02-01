Project Overview
The AXI Write Order Module is designed to optimize the write transaction ordering in an AXI3 bus architecture. The module ensures correct dependency management, data integrity, and policy enforcement while maintaining high performance.

This project was developed as part of the Spring 2024 semester by:

Bar Arama
Barak Ariely
Supervisor: Gil Stoler (Amazon)

Features
✔️ Supports AXI3 INCR Transactions
✔️ Handles Narrow Transactions (correctness guaranteed)
✔️ Supports Up to 8 Outstanding Transactions
✔️ Configurable Burst Size (default: 256 bytes)
✔️ Dynamic Ordering Rules
✔️ Integrated Storage Using Registers
✔️ Post-Synthesis Timing Analysis (not yet)


Functional Description
The module:
Reorders transactions dynamically based on dependency policies.
Maintains system performance while enforcing order where necessary.
Uses specialized storage for handling "special" transactions.

System Specifications:
Interface: AXI3 (Address, Data, Response Channels)
Toolchain:
HDL Implementation: SystemVerilog
Simulation: Ncsim/VCS
Synthesis: Design Compiler
Layout Design: Cadence/Synopsys
Implementation Details


The module behaves like a highway traffic system. 
Using Traffic Flow Analogy 🚦 The module consists of the following key components:
🔹 Process Memory ("The Camera")
FIFO structure for transaction tracking.
Monitor when to release diverted transactions.
🔹 Routers ("Exit & Merge Lanes")
Dynamically directs transactions.
Merges or diverts traffic as needed.
🔹 Special Memory ("Pull-off Area")
classifies incoming transactions.
Stores special transactions.
Implements "Unlucky Transaction" handling.
Uses an upgraded FIFO structure with priority release.


Transaction Types & Dependencies
The module classifies write transactions into three main types:

1. Regular Transactions – Can proceed without restrictions.
2. Block Transactions – Blocks incoming transactions until ended.
3. Special Transactions – Delayed until all previous Transactions ends.
*  Unlucky Transactions - a transaction from the same master as a Special transaction.
Delay is required for perserving AXI protocol correctness.
