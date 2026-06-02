/*------------------------------------------------------------------------------
 * File          : process_mem.sv
 * Project       : RTL
 * Author        : epabab
 * Creation date : Jul 20, 2024
 * Description   : In-flight transaction tracker (regular + special).
 *
 * Project B rewrite (Option-D, free-list): the O(N) compacted shifting array and
 * its DW_pricod are gone. Slots live in a free-list occupancy bitmap (valid_q):
 *   - allocate = set the lowest free bit, delete = clear one matching bit (O(1)).
 *   - block_fin / spec_release are REGISTERED so they no longer reach rout.to_block_d
 *     combinationally (was the 256-slot critical path).
 *
 * Ordering for spec_release uses a divert-stamp instead of an age matrix or per-divert
 * wait-masks: pending diverts are a contiguous suffix of issued diverts, so a txn is
 * "older than the oldest pending divert" iff its dstamp == base (a wrap-immune equality).
 * See analysis/plans/05-plan_s_add_skid_buffer.md (Phase 2).
 *
 * Same-AWID may be outstanding multiple times: delete/done/wlast pick ONE matching slot
 * (lowest set bit), biased to a BLOCK-typed match so block_fin attribution is correct.
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

	output 	logic	 	full,
	output	logic		empty,
	output 	logic 		block_fin,
	output 	logic 		spec_release,
	output	logic		block_data

	);

localparam PCW = $clog2(SLOT_AMOUNT) + 1 ;   // proc_count width: 0..SLOT_AMOUNT
// Divert-stamp width. base..dseq is the live-divert window; equality (dstamp==base) is
// wrap-immune as long as that window < 2^DSW. Sized to clog2(SLOT_AMOUNT)+1 (margin to 512)
// since at most SLOT_AMOUNT transactions (hence diverts) are ever concurrently outstanding.
// ap_window (below) traps any violation of that bound in simulation.
localparam DSW = $clog2(SLOT_AMOUNT) + 1 ;

// ---- free-list occupancy + per-slot state ----
logic [SLOT_AMOUNT-1:0]                 valid_q     ;
logic [SLOT_AMOUNT-1:0][PID_WIDTH-1:0]  id_q        ;
logic [SLOT_AMOUNT-1:0]                 done_q      ;   // done bitmask
logic [SLOT_AMOUNT-1:0]                 block_vec   ;   // tran_type == BLOCK
logic [SLOT_AMOUNT-1:0]                 divert_vec  ;   // tran_type == DIVERT
logic [SLOT_AMOUNT-1:0][DSW-1:0]        dstamp_q    ;   // divert-count seen at insertion

logic [DSW-1:0]  dseq_q ;     // total diverts issued (++ on divert insert)
logic [DSW-1:0]  base_q ;     // dseq of the oldest pending divert (++ on release)

logic [PCW-1:0]  proc_count ;
logic            full_q, empty_q ;
logic            spec_release_q, block_fin_q ;

assign full  = full_q ;
assign empty = empty_q ;
assign spec_release = spec_release_q ;
assign block_fin    = block_fin_q ;

// ---- lowest set bit (isolate one slot from a candidate mask) ----
function automatic logic [SLOT_AMOUNT-1:0] lowest_set (input logic [SLOT_AMOUNT-1:0] x);
	lowest_set = x & (~x + {{(SLOT_AMOUNT-1){1'b0}}, 1'b1}) ;
endfunction

// ---- handshakes ----
logic new_tran, bshake, w_done ;
logic is_div_new, is_block_new ;

assign bshake       = bvalid & bready ;
assign new_tran     = awvalid & awready & ~full_q & ~to_block ;
assign w_done       = wvalid & wready & wlast ;
assign is_div_new   = (awuser == DIVERT) ;
assign is_block_new = (awuser == BLOCK)  ;

// ---- allocate ----
logic [SLOT_AMOUNT-1:0] free_mask, alloc_oh ;
assign free_mask = ~valid_q ;
assign alloc_oh  = new_tran ? lowest_set(free_mask) : '0 ;

// ---- per-slot combinational match vectors ----
logic [SLOT_AMOUNT-1:0] b_match, b_match_blk ;
logic [SLOT_AMOUNT-1:0] w_match ;       // wid match, still pending (for done set)
logic [SLOT_AMOUNT-1:0] w_active ;      // wid match, not done (for block_data)
logic [SLOT_AMOUNT-1:0] eq_base ;       // dstamp == base
always_comb begin
	for (int j = 0; j < SLOT_AMOUNT; j++) begin
		b_match[j]     = valid_q[j] & (id_q[j] == bid) ;
		b_match_blk[j] = b_match[j] & block_vec[j] ;
		w_match[j]     = valid_q[j] & (id_q[j] == wid) & ~done_q[j] ;
		w_active[j]    = w_match[j] ;
		eq_base[j]     = (dstamp_q[j] == base_q) ;
	end
end

// ---- delete select: one matching slot, biased to a BLOCK match (block_fin accuracy) ----
logic [SLOT_AMOUNT-1:0] del_oh ;
logic                   del_en ;
assign del_oh = (|b_match_blk) ? lowest_set(b_match_blk) : lowest_set(b_match) ;
assign del_en = bshake & (|b_match) ;

// ---- wlast -> done: set one (lowest) not-done matching slot ----
logic [SLOT_AMOUNT-1:0] done_set_oh ;
logic                   done_en ;
assign done_set_oh = lowest_set(w_match) ;
assign done_en     = w_done & (|w_match) ;

// ---- block_data: 1 unless a still-pending data slot matches wid this beat ----
assign block_data = ~(wvalid & (|w_active)) ;

// ---- spec_release: divert-stamp ordering (see header) ----
logic [SLOT_AMOUNT-1:0] oldest_div_oh, older_remaining ;
logic                   div_pending, spec_fire, oldest_div_retire, base_adv ;
logic                   released_q ;       // current oldest divert already released (await its retire)
assign oldest_div_oh     = valid_q & divert_vec & eq_base ;       // one-hot: oldest pending divert
assign older_remaining   = valid_q & eq_base & ~oldest_div_oh ;   // older non-divert txns still live
assign div_pending       = (dseq_q != base_q) ;
assign spec_fire         = div_pending & (|oldest_div_oh) & ~(|older_remaining) ;
assign oldest_div_retire = del_en & (|(del_oh & oldest_div_oh)) ; // oldest pending divert leaves
// advance base when the oldest divert retires, or skip a gap stamp whose divert already
// completed out of order (its older txns provably cleared at that divert's earlier release).
assign base_adv          = oldest_div_retire | (div_pending & ~(|oldest_div_oh)) ;

// ============================ sequential ============================
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		valid_q    <= '0 ;
		done_q     <= '0 ;
		block_vec  <= '0 ;
		divert_vec <= '0 ;
		for (int i = 0; i < SLOT_AMOUNT; i++) begin
			id_q[i]     <= '0 ;
			dstamp_q[i] <= '0 ;
		end
	end else begin
		for (int i = 0; i < SLOT_AMOUNT; i++) begin
			// occupancy: allocate (alloc_oh) and free (del_oh) target different slots
			valid_q[i] <= (valid_q[i] | (new_tran & alloc_oh[i])) & ~(del_en & del_oh[i]) ;

			if (new_tran & alloc_oh[i]) begin
				id_q[i]      <= awid ;
				dstamp_q[i]  <= dseq_q ;
				block_vec[i] <= is_block_new ;
				divert_vec[i]<= is_div_new ;
				done_q[i]    <= 1'b0 ;
			end else begin
				if (del_en & del_oh[i]) begin
					block_vec[i]  <= 1'b0 ;
					divert_vec[i] <= 1'b0 ;
					done_q[i]     <= 1'b0 ;
				end else if (done_en & done_set_oh[i]) begin
					done_q[i] <= 1'b1 ;
				end
			end
		end
	end
end

// ---- counters / full / empty ----
logic [PCW-1:0] count_next ;
assign count_next = proc_count + (new_tran ? 1'b1 : 1'b0) - (del_en ? 1'b1 : 1'b0) ;
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		proc_count <= '0 ;
		full_q     <= 1'b0 ;
		empty_q    <= 1'b1 ;
	end else begin
		proc_count <= count_next ;
		full_q     <= (count_next == PCW'(SLOT_AMOUNT)) ;
		empty_q    <= (count_next == '0) ;
	end
end

// ---- divert sequence / base pointer ----
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		dseq_q <= '0 ;
		base_q <= '0 ;
	end else begin
		if (new_tran & is_div_new)
			dseq_q <= dseq_q + DSW'(1) ;
		if (base_adv)                           // oldest divert retired, or skip a completed gap
			base_q <= base_q + DSW'(1) ;
	end
end

// ---- registered spec_release handshake ----
// Assert when the oldest pending divert's older txns are all gone; hold until special_memory
// acks (release_ready). released_q then blocks re-fire until that divert actually retires.
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		spec_release_q <= 1'b0 ;
		released_q     <= 1'b0 ;
	end else begin
		if (release_ready)                  spec_release_q <= 1'b0 ;
		else if (spec_fire & ~released_q)   spec_release_q <= 1'b1 ;

		if (base_adv)                       released_q <= 1'b0 ;
		else if (spec_release_q & release_ready) released_q <= 1'b1 ;
	end
end

// ---- registered block_fin: a BLOCK slot retired this cycle ----
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n)
		block_fin_q <= 1'b0 ;
	else
		block_fin_q <= del_en & (|(del_oh & block_vec)) ;
end


// synthesis translate_off
//==============================================================================
// Assertions
//==============================================================================
// occupancy bitmap matches the running count
ap_count: assert property (@(posedge clk) disable iff (!rst_n)
	proc_count == $countones(valid_q))
	else $fatal("proc_count (%0d) != popcount(valid_q) (%0d)", proc_count, $countones(valid_q));

// at most one oldest-pending divert; delete/done pick exactly one slot
ap_div_oh:  assert property (@(posedge clk) disable iff (!rst_n) $onehot0(oldest_div_oh))
	else $fatal("oldest_div_oh not one-hot");
ap_del_oh:  assert property (@(posedge clk) disable iff (!rst_n) $onehot0(del_oh))
	else $fatal("del_oh not one-hot");
ap_done_oh: assert property (@(posedge clk) disable iff (!rst_n) $onehot0(done_set_oh))
	else $fatal("done_set_oh not one-hot");

// live-divert window must stay below 2^DSW or dstamp==base equality would alias.
ap_window: assert property (@(posedge clk) disable iff (!rst_n)
	(dseq_q - base_q) < DSW'(SLOT_AMOUNT))
	else $fatal("divert window (%0d) too large -> dstamp aliasing; widen DSW", dseq_q - base_q);

// spec_release implies a divert is pending and nothing older than it remains
ap_spec: assert property (@(posedge clk) disable iff (!rst_n)
	spec_release_q |-> (div_pending & ~(|older_remaining)))
	else $fatal("spec_release asserted with older txns still pending");

// no X on control nets
ap_x: assert property (@(posedge clk) disable iff (!rst_n)
	!$isunknown({new_tran, del_en, done_en, spec_release_q, block_fin_q, base_q, dseq_q}))
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
		$display("[PROCMEM WATCHDOG @%0t] STUCK proc_count=%0d dseq=%0d base=%0d", $time, proc_count, dseq_q, base_q);
		$display("  full=%b empty=%b to_block=%b block_data=%b block_fin=%b", full_q, empty_q, to_block, block_data, block_fin_q);
		$display("  spec_release=%b release_ready=%b div_pending=%b older_remaining=%b", spec_release_q, release_ready, div_pending, |older_remaining);
		$display("  bvalid=%b bready=%b bid=%0d  awvalid=%b awready=%b awid=%0d awuser=%b", bvalid, bready, bid, awvalid, awready, awid, awuser);
		for (int k = 0; k < SLOT_AMOUNT; k++)
			if (valid_q[k])
				$display("    slot[%0d] id=%0d blk=%b div=%b done=%b dstamp=%0d", k, id_q[k], block_vec[k], divert_vec[k], done_q[k], dstamp_q[k]);
		$display("==========================================================================");
	end
end
// synthesis translate_on


endmodule
