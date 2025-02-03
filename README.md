# AXI Write Order Module

## Project Overview  
The **AXI Write Order Module** is designed to optimize **write transaction ordering** in an **AXI3 bus architecture**. The module ensures **correct dependency management, data integrity, and policy enforcement** while maintaining **high performance**.  

This project was developed as part of the **Spring 2024** semester by:  
- **Bar Arama**  
- **Barak Ariely**  
- Supervisor: **Gil Stoler** (Amazon)  

---

## Features  
✔️ **Supports AXI3 INCR Transactions**  
✔️ **Handles Narrow Transactions** (correctness guaranteed)  
✔️ **Supports up to 8 outstanding transactions**  
✔️ **Supports interleaving transactions**  
✔️ **Enables parallel data flow across different channels**  
✔️ **Configurable burst size** (default: 256 bytes)  
✔️ **Dynamic ordering rules**  
✔️ **Integrated storage using registers**  
✔️ **Post-synthesis timing analysis**  

---

## Functional Description  
The module:  
- **Reorders transactions dynamically** based on dependency policies.  
- **Maintains system performance** while enforcing ordering where necessary.  
- **Uses specialized storage** for handling "special" transactions.  

---

## System Specifications  
- **Interface**: AXI3 (Address, Data, Response Channels)  
- **Toolchain**:  
  - **HDL Implementation**: SystemVerilog  
  - **Simulation**: Ncsim/VCS  
  - **Synthesis**: Design Compiler  
  - **Layout Design**: Cadence/Synopsys  

---

## Implementation Details  
The module behaves like a **highway traffic system** 🚦:  

### Key Components  
🔹 **Process Memory ("The Camera")**  
- FIFO structure for **tracking transactions**.  
- Monitors transactions in the system.  
- Decides when to **release transactions** from the **"Pull-off Area"**.  

🔹 **Routers ("Exit & Merge Lanes")**  
- Dynamically **directs transactions**.  
- Merges or diverts traffic as needed.  

🔹 **Special Memory ("Pull-off Area")**  
- **Classifies** incoming transactions.  
- **Stores transactions** if needed.  
- Implements **"Unlucky Transaction"** handling.  
- Uses an **upgraded FIFO structure** with priority-based release.
- **Interfaces with masters and slaves** via the AXI protocol

---

## Transaction Types & Dependencies  
The module classifies write transactions into three main types:  

1. **Regular Transactions** – Can proceed without restrictions.  
2. **Blocked Transactions** – Blocks incoming transactions **until completion**.  
3. **Special Transactions** – Delayed **until all previous transactions end**.  
🔹 **Unlucky Transactions** – A none - Special transaction from the same master as a Special Transaction. Delays are required to preserve AXI protocol correctness (maintaining order of transactions from the same master).  

