/*------------------------------------------------------------------------------
 * File          : process_mem.sv
 * Project       : RTL
 * Author        : epabab
 * Creation date : Jul 20, 2024
 * Description   : In-flight transaction tracker (regular + special).
 *
 * 1. Occupancy Bitmap: Uses `bitmap_val_q` and lowest-bit selection for fast O(1) allocation/deletion.
 * 2. Generation Ticketing: Replaces the Age Matrix. Transactions get a generation `ticket`. 
 *    A new DIVERT increments the generation tag (`div_count`). We drain generations in order 
 *    (`oldest_ticket`). When a generation empties, we release the next DIVERT.
 * 3. Registered Outputs: Buffer critical signals to fix timing.
 *------------------------------------------------------------------------------*/

import pkg::*;

module process_mem
 	(
	input	logic		clk,
	input	logic		rst_n,

	input 	logic [PID_WIDTH - 1:0]	awid, 		//address channel
	input 	logic 		awvalid,
	input   logic		awready,
	input 	logic [PAWUSER_WIDTH - 1:0] awuser,

	input	logic [PID_WIDTH - 1:0]	wid, 		//data channel
	input	logic 		wvalid,
	input	logic 		wready,
	input	logic 		wlast,

	input 	logic	 	bready, 				//response channel
	input 	logic	 	bvalid,
	input 	logic [PID_WIDTH - 1:0]	bid,

	input	logic		release_ready,			//special memory
	input	logic		to_block,			   //router

	output 	logic	 	full_q,
	output	logic		empty_q,
	output 	logic 		block_fin,
	output 	logic 		spec_release_q,
	output	logic		block_data

	);

localparam PCW = $clog2(SLOT_AMOUNT) + 1 ;   // proc_count width: 0..SLOT_AMOUNT
// Ticket width. Sized with an extra bit to safely handle counter wrap-around.
// Active window (oldest_ticket..div_count) == #DIVERTs currently in special_memory:
//   div_count++ per divert alloc, oldest_ticket++ per release_ready => window = diverts in flight.
// So it is bounded by SPEC_SLOT_AMOUNT, NOT SLOT_AMOUNT. ap_window below proves this in sim.
localparam DSW = $clog2(SPEC_SLOT_AMOUNT) + 1 ;

// ---- occupancy bitmap + per-slot state (one entry per slot) ----
logic [SLOT_AMOUNT-1:0]                 bitmap_val_q ;  // bit k = slot k live (== special_memory.bitmap_val_q)
logic [SLOT_AMOUNT-1:0][PID_WIDTH-1:0]  id_q        ;   // per-slot AWID
logic [SLOT_AMOUNT-1:0]                 done_q      ;   // per-slot: write side finished
logic [SLOT_AMOUNT-1:0]                 block_vec   ;   // per-slot: tran_type == BLOCK
logic [SLOT_AMOUNT-1:0][DSW-1:0]        ticket    ;   // per-slot: generation tag (a DIVERT opens a new one)

logic [DSW-1:0]  div_count ;     // highest generation opened (a DIVERT opens a new one)
logic [DSW-1:0]  oldest_ticket ; // generation currently being drained (++ on release handshake)
logic [PCW-1:0]  proc_count ;
logic [PID_WIDTH-1:0] bid_q ;

// ---- lowest_set: The old trick everyone know (x & -x). Picks the first free/matching slot. ----
function automatic logic [SLOT_AMOUNT-1:0] lowest_set (input logic [SLOT_AMOUNT-1:0] x);
	lowest_set = x & (~x + {{(SLOT_AMOUNT-1){1'b0}}, 1'b1}) ;
endfunction

// ---- handshakes ----
logic new_tran, bshake, bshake_q, w_done ;
logic is_div_new, is_block_new ;
assign bshake       = bvalid & bready ;                         // a B-response (tran completion) accepted this cycle
assign new_tran     = awvalid & awready & ~full_q & ~to_block ; // a new tran allocated this cycle
assign w_done       = wvalid & wready & wlast ;                 // last data beat of a burst accepted
assign is_div_new   = (awuser == DIVERT) & ~empty_q ;   // a DIVERT with older trans (else it passes through as regular)
assign is_block_new = (awuser == BLOCK)  ;

// ---- Generation bump: A new DIVERT increments the generation tag (gen_next). Regulars inherit current tag. ----
logic            div_opens ;
logic [DSW-1:0]  gen_next ;
assign div_opens = new_tran & is_div_new ;
assign gen_next  = div_count + (div_opens ? DSW'(1) : DSW'(0)) ;

// ---- allocate: fill the lowest free slot (one-hot) ----
logic [SLOT_AMOUNT-1:0] free_mask, alloc_oh ;
assign free_mask = ~bitmap_val_q ;                          // 1 = slot free
assign alloc_oh  = new_tran ? lowest_set(free_mask) : '0 ;  // _oh: the one slot we fill this cycle

// ---- per-slot combinational match vectors (one bit per slot) ----
logic [SLOT_AMOUNT-1:0] b_match, b_match_block ; // b_match[j]: when live id == bid.  b_match_block: The same but tran is "block"
logic [SLOT_AMOUNT-1:0] w_match ;       // wid match: when live id == wid and not done (data channel input)
logic [SLOT_AMOUNT-1:0] eq_oldest ;       // ticket == oldest_ticket (slot belongs to the generation being drained)
always_comb begin
	for (int j = 0; j < SLOT_AMOUNT; j++) begin
		b_match[j]     = bitmap_val_q[j] & (id_q[j] == bid_q) ;   // <- registered bid (cut 1)
		b_match_block[j] = b_match[j] & block_vec[j] ;
		w_match[j]     = bitmap_val_q[j] & (id_q[j] == wid) & ~done_q[j] ;  // wid is NOT registered: block_data must stay same-cycle
		eq_oldest[j]     = (ticket[j] == oldest_ticket) ;
	end
end

// ---- Delete slot: free the lowest matching slot ----
// We prefer freeing BLOCK slots over DIVERTs to keep `block_fin` accurate.
// del_oh: the exactly one slot to free.
// del_en: triggers the free this cycle.
logic [SLOT_AMOUNT-1:0] del_oh ;   // which slot to free (one-hot)
logic                   del_en ;   // a free happens this cycle
assign del_oh = (|b_match_block) ? lowest_set(b_match_block) : lowest_set(b_match) ;
assign del_en = bshake_q & (|b_match) ;   // <- registered bshake (cut 1)

// ---- wlast -> done: set one (lowest) not-done matching slot ----
logic [SLOT_AMOUNT-1:0] done_set_oh ;
logic                   done_en ;
assign done_set_oh = lowest_set(w_match) ;
assign done_en     = w_done & (|w_match) ;

// ---- spec_release: generation drain (fires when oldest generation empties and a later DIVERT exists) ----
logic [SLOT_AMOUNT-1:0] older_remaining ;
logic                   div_pending, spec_fire ;
assign older_remaining = bitmap_val_q & eq_oldest ;          // still-alive predecessors of the next divert
assign div_pending     = (div_count != oldest_ticket) ;      // a divert opened a later generation
assign spec_fire       = div_pending & ~(|older_remaining) ; // predecessor generation drained

// ---- counters / full / empty ----
logic [PCW-1:0] count_next ;
assign count_next = proc_count + (new_tran ? 1'b1 : 1'b0) - (del_en ? 1'b1 : 1'b0) ;
assign block_data = ~(wvalid & (|w_match)) ;
assign block_fin  = del_en & (|(del_oh & block_vec)) ;

always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		bitmap_val_q   <= '0 ;
		done_q         <= '0 ;
		block_vec      <= '0 ;
		bid_q          <= '0 ;
		bshake_q       <= 1'b0 ;
		proc_count     <= '0 ;
		full_q         <= 1'b0 ;
		empty_q        <= 1'b1 ;
		div_count      <= '0 ;
		oldest_ticket  <= '0 ;
		spec_release_q <= 1'b0 ;
		for (int i = 0; i < SLOT_AMOUNT; i++) begin
			id_q[i]   <= '0 ;
			ticket[i] <= '0 ;
		end
	end else begin
		// ---- Registered B-response ----
		bshake_q <= bshake ;
		if (bshake) bid_q <= bid ;

		// ---- occupancy / per-slot state ----
		for (int i = 0; i < SLOT_AMOUNT; i++) begin
			bitmap_val_q[i] <= (bitmap_val_q[i] | (new_tran & alloc_oh[i])) & ~(del_en & del_oh[i]) ;

			if (new_tran & alloc_oh[i]) begin
				id_q[i]      <= awid ;
				ticket[i]    <= gen_next ;
				block_vec[i] <= is_block_new ;
				done_q[i]    <= 1'b0 ;
			end else begin
				if (del_en & del_oh[i]) begin
					block_vec[i] <= 1'b0 ;
					done_q[i]    <= 1'b0 ;
				end else if (done_en & done_set_oh[i]) begin
					done_q[i] <= 1'b1 ;
				end
			end
		end

		// ---- generation counter / drain pointer ----
		div_count <= gen_next ;
		if (release_ready) oldest_ticket <= oldest_ticket + DSW'(1) ;

		// ---- spec_release handshake ----
		if (release_ready)   spec_release_q <= 1'b0 ;
		else if (spec_fire)  spec_release_q <= 1'b1 ;



		// ---- counters / full / empty ----
		proc_count <= count_next ;
		full_q     <= (count_next == PCW'(SLOT_AMOUNT)) ;
		empty_q    <= (count_next == '0) ;
	end
end


// synthesis translate_off
//==============================================================================
// Assertions
//==============================================================================
// occupancy bitmap matches the running count
ap_count: assert property (@(posedge clk) disable iff (!rst_n)
	proc_count == $countones(bitmap_val_q))
	else $fatal("proc_count (%0d) != popcount(bitmap_val_q) (%0d)", proc_count, $countones(bitmap_val_q));

// delete/done pick exactly one slot
ap_del_oh:  assert property (@(posedge clk) disable iff (!rst_n) $onehot0(del_oh))
	else $fatal("del_oh not one-hot");
ap_done_oh: assert property (@(posedge clk) disable iff (!rst_n) $onehot0(done_set_oh))
	else $fatal("done_set_oh not one-hot");

// live-divert window == #DIVERTs in special_memory, so it must stay <= SPEC_SLOT_AMOUNT
// (and below 2^DSW or ticket==oldest_ticket equality would alias). This proves the SPEC bound.
ap_window: assert property (@(posedge clk) disable iff (!rst_n)
	(div_count - oldest_ticket) < DSW'(SPEC_SLOT_AMOUNT))
	else $fatal("divert window (%0d) too large -> ticket aliasing; widen DSW", div_count - oldest_ticket);

// spec_release implies a divert is pending and nothing older than it remains
ap_spec: assert property (@(posedge clk) disable iff (!rst_n)
	spec_release_q |-> (div_pending & ~(|older_remaining)))
	else $fatal("spec_release asserted with older trans still pending");

// no X on control nets
ap_x: assert property (@(posedge clk) disable iff (!rst_n)
	!$isunknown({new_tran, del_en, done_en, spec_release_q, block_fin, oldest_ticket, div_count}))
	else $fatal("process_mem control net is X");

//==============================================================================
// Deadlock watchdog
//==============================================================================
wire pm_progress = new_tran | bshake | spec_release_q | release_ready;
integer pm_idle_cnt;
always @(posedge clk or negedge rst_n) begin
	if (!rst_n)                                pm_idle_cnt <= 0;
	else if (pm_progress | (proc_count == 0)) pm_idle_cnt <= 0;
	else                                       pm_idle_cnt <= pm_idle_cnt + 1;
end

always @(posedge clk) begin
	if (rst_n && pm_idle_cnt == 450) begin
		$display("==========================================================================");
		$display("[PROCMEM WATCHDOG @%0t] STUCK proc_count=%0d div_count=%0d oldest_ticket=%0d", $time, proc_count, div_count, oldest_ticket);
		$display("  full=%b empty=%b to_block=%b block_data=%b block_fin=%b", full_q, empty_q, to_block, block_data, block_fin);
		$display("  spec_release=%b release_ready=%b div_pending=%b older_remaining=%b", spec_release_q, release_ready, div_pending, |older_remaining);
		$display("  bvalid=%b bready=%b bid=%0d  awvalid=%b awready=%b awid=%0d awuser=%b", bvalid, bready, bid, awvalid, awready, awid, awuser);
		for (int k = 0; k < SLOT_AMOUNT; k++)
			if (bitmap_val_q[k])
				$display("    slot[%0d] id=%0d blk=%b done=%b ticket=%0d", k, id_q[k], block_vec[k], done_q[k], ticket[k]);
		$display("==========================================================================");
	end
end
// synthesis translate_on


endmodule
