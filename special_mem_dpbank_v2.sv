/*------------------------------------------------------------------------------
 * File          : special_mem_dpbank_v2.sv
 * Project       : RTL
 * Author        : Barak Ariely
 * Creation date : 2026-05-23
 * Description   : Alternative payload bank for special_memory built from
 *                 single-port spram16x64 instances.
 *
 *                 Strategy: one SRAM column per slot, so a write to slot A
 *                 and a read from slot B (the only case special_memory can
 *                 produce simultaneously) target physically different SRAMs
 *                 and do not contend.
 *
 *                 spram16x64_cb = 16-bit WIDE x 64-deep (lab naming = width x
 *                 depth, same as dpram72x128_cb in special_mem_dpbank).
 *
 *                 Per slot: 19 spram16x64_cb instances
 *                   - 16 for the 256-bit data    (16 x 16)
 *                   -  3 for strb(32)+parity(8)+isRuined(8) = 48 bits (3 x 16)
 *                 Total: 16 slots * 19 = 304 spram16x64_cb instances.
 *
 *                 Each SRAM is 64-deep; we use the low 8 entries (one per
 *                 transfer in an 8-beat burst, PLENGTH_WIDTH=3).
 *------------------------------------------------------------------------------*/


module special_mem_dpbank_v2 (
	input  logic         clk,

	// Writer port (logical view kept identical to special_mem_dpbank)
	input  logic         wr_en,
	input  logic [6:0]   wr_addr,    // {slot_idx[3:0], xfer_idx[2:0]}
	input  logic [255:0] wr_data,
	input  logic [31:0]  wr_strb,
	input  logic [7:0]   wr_parity,
	input  logic [7:0]   wr_isRuined,

	// Reader port (logical view kept identical to special_mem_dpbank)
	input  logic         rd_en,
	input  logic [6:0]   rd_addr,    // {slot_idx[3:0], xfer_idx[2:0]}
	output logic [255:0] rd_data,
	output logic [31:0]  rd_strb,
	output logic [7:0]   rd_parity,
	output logic [7:0]   rd_isRuined
);

	localparam int SLOTS      = 16;
	// spram16x64_cb is 16-bit WIDE x 64-deep (lab naming = width x depth, like dpram72x128_cb).
	localparam int DATA_RAMS  = 16;  // 16 * 16 = 256 bits of data per transfer
	localparam int SB_RAMS    = 3;   // 3 * 16 = 48 bits: strb(32)+parity(8)+isRuined(8)

	// Address split
	logic [3:0] wr_slot_idx;
	logic [2:0] wr_xfer_idx;
	logic [3:0] rd_slot_idx;
	logic [2:0] rd_xfer_idx;

	assign {wr_slot_idx, wr_xfer_idx} = wr_addr;
	assign {rd_slot_idx, rd_xfer_idx} = rd_addr;

	// One-hot per-slot enables. wr and rd are guaranteed to target
	// different slots (a slot is either being filled or being drained,
	// gated by spec_mem[*].done in special_memory.sv).
	logic [SLOTS-1:0] slot_wr_en;
	logic [SLOTS-1:0] slot_rd_en;

	always_comb begin
		slot_wr_en = '0;
		slot_rd_en = '0;
		if (wr_en) slot_wr_en[wr_slot_idx] = 1'b1;
		if (rd_en) slot_rd_en[rd_slot_idx] = 1'b1;
	end

	// Per-slot read outputs, muxed to module outputs after the SRAM read latency
	logic [SLOTS-1:0][255:0] slot_rd_data;
	logic [SLOTS-1:0][31:0]  slot_rd_strb;
	logic [SLOTS-1:0][7:0]   slot_rd_parity;
	logic [SLOTS-1:0][7:0]   slot_rd_isRuined;

	genvar s, b;
	generate
		for (s = 0; s < SLOTS; s++) begin : g_slot

			// Shared single-port arbitration (wr and rd into the SAME slot
			// in the same cycle cannot occur by construction).
			logic        port_en;
			logic        port_we;
			logic [5:0]  port_addr;          // 64-deep -> 6-bit address (use low 8 entries)
			logic        csb, web, oeb;

			assign port_en   = slot_wr_en[s] | slot_rd_en[s];
			assign port_we   = slot_wr_en[s];
			assign port_addr = {3'b000, port_we ? wr_xfer_idx : rd_xfer_idx};

			assign csb = ~port_en;     // chip select, active low
			assign web = ~port_we;     // write enable, active low
			assign oeb = ~slot_rd_en[s]; // output enable on reads only

			// Data: 16 x spram16x64_cb (16-bit wide) -> 256 bits
			for (b = 0; b < DATA_RAMS; b++) begin : g_data
				spram16x64_cb u_data (
					.A   (port_addr),
					.I   (wr_data[b*16 +: 16]),
					.O   (slot_rd_data[s][b*16 +: 16]),
					.CEB (clk),
					.WEB (web),
					.CSB (csb),
					.OEB (oeb)
				);
			end

			// Sideband: strb(32) + parity(8) + isRuined(8) = 48 bits = 3 x spram16x64_cb
			logic [47:0] sb_in;
			logic [47:0] sb_out;

			assign sb_in = {wr_isRuined, wr_parity, wr_strb};   // 8 + 8 + 32 = 48
			assign slot_rd_strb[s]     = sb_out[31:0];
			assign slot_rd_parity[s]   = sb_out[39:32];
			assign slot_rd_isRuined[s] = sb_out[47:40];

			for (b = 0; b < SB_RAMS; b++) begin : g_sb
				spram16x64_cb u_sbp (
					.A   (port_addr),
					.I   (sb_in[b*16 +: 16]),
					.O   (sb_out[b*16 +: 16]),
					.CEB (clk),
					.WEB (web),
					.CSB (csb),
					.OEB (oeb)
				);
			end

		end
	endgenerate

	// The spram16x64 macros read on negedge CEB (CEB=clk) and hold their output
	// for the full cycle -- same model as dpram72x128_cb in special_mem_dpbank (v1).
	// So, exactly like v1, the bank adds NO internal register: route the read-slot's
	// SRAM outputs straight out, selected by the CURRENT rd_slot_idx. special_memory's
	// rd_stg1 registers + half-cycle posedge/negedge crossing own the read timing.
	// (A delayed select would mux a stale/idle slot on the first beat -> X parity.)
	assign rd_data     = slot_rd_data    [rd_slot_idx];
	assign rd_strb     = slot_rd_strb    [rd_slot_idx];
	assign rd_parity   = slot_rd_parity  [rd_slot_idx];
	assign rd_isRuined = slot_rd_isRuined[rd_slot_idx];

endmodule
