/*------------------------------------------------------------------------------
 * File          : special_memory.sv
 * Project       : RTL
 * Author        : epabab
 * Creation date : Aug 23, 2024
 * Description   : Special & Unlucky transaction linked-list memory and arbitrator.
 * Main functions: Stores/releases data, and handles AXI Master/Slave communication.
 *------------------------------------------------------------------------------*/

module special_memory
import pkg::*;
(
	input              rst_n,
	input              clk,
									// Master's side Address and Data channels (module behave as a slave)
	axi_if.slave_add   s_add,
	axi_if.slave_data  s_data,
									// Slave's side Address and Data channels (module behave as a Master)
	axi_if.master_add  m_add,
	axi_if.master_data m_data,
	
	input              proc_full,     // Process Memory connections
	input              proc_empty,
	input              spec_release,  
	input              to_block,	  // Router connections
	
	output 	logic      release_ready, //connect to process memory
	output             spec2router,    //connect to router
	output logic       unluck
);

// 1. Core State & Control Signals
//=========================================
spec_slot [SPEC_SLOT_AMOUNT-1:0]  spec_mem ;
logic     [SPEC_SLOT_AMOUNT-1:0] bitmap_val_q         ;
age_row_t                    age_q [SPEC_SLOT_AMOUNT] ;
reg	  	  [INDEX_WIDTH:0] 	      spec_count 		  ;

logic	  [INDEX_WIDTH-1:0]  	  wr_idx_in ;
logic  	  [INDEX_WIDTH-1:0]		  rd_next   ;
logic  	  [INDEX_WIDTH-1:0]		  rd_curr   ; 
logic  	  [INDEX_WIDTH-1:0]		  rd_addr   ; 
logic 	  [PID_WIDTH-1:0] 		  cur_id 	;
reg 	  [PID_WIDTH-1:0] 		  d_cur_id 	;

reg	  mem_full 	    ;
wire  found_unluck  ;
logic tran_valid    ;
logic tran_ready    ;
logic first_done    ;
logic first_unluck  ;
logic in_awshake    ;
logic transfer_done ;

// --- Unlucky early-fire (Phase 1): registered m_add payload + FSM ---
typedef enum logic [0:0] {
    EU_IDLE,
    EU_ARMED
} eu_state_t; //early-unluck
eu_state_t eu_state, eu_next;

add_t m_add_q      ;
logic m_add_vld_q  ;
logic load_release ;
// --- Unlucky Prefetch ---
logic tran_ready_q ;     // Delayed tran_ready to detect 0->1 edge (idle cycle)
logic idle_cycle   ;     // The cycle immediately after a transfer finishes
logic prefetch_now ;     // Pulse to load beat-0 of the unlucky transaction

// 2. Pipeline Stages
//=========================================
// Read Path: Address Logic -> [rd_stg1 REG] -> SRAM
logic [INDEX_WIDTH+PLENGTH_WIDTH-1:0] rd_stg1_addr_q ;
logic                 rd_stg1_en_q 	  ;
logic [PID_WIDTH-1:0] rd_stg1_wid_q   ;
logic                 rd_stg1_wlast_q ;
// Write Path: AXI s_data -> [wr_data_pipe REG] -> SRAM (write port always-ready: no skid)
wr_pipe_data_t wr_bus_in     ;       // pipe input  (combinational from s_data)
wr_pipe_data_t wr_stg1_bus   ;       // pipe output (registered) -> SRAM write port
logic          wr_stg1_valid ;       // pipe output valid       -> SRAM wr_en
logic          pipe_up_ready ;       // pipe up_ready (write accept)
logic          wr_id_match   ;

// 3. AXI Flow Control (Skid Buffers)
//=========================================
// Read Path: SRAM Output -> [rd_raw_pipe REG] -> [data_skid SKID] -> m_data
logic [PDATA_WIDTH*8-1:0] rd_stg2_data ;
logic [PDATA_WIDTH-1:0]   rd_stg2_strb ;
logic [PWUSER_WIDTH-1:0]  rd_stg2_user ;

raw_rd_data_t pipe_raw_in, pipe_raw_out ;   
logic       rd_pipe_up_ready ;
logic       rd_skid_valid    ;
logic       rd_skid_ready    ;
w_beat_t rd_skid_bus_in ;
w_beat_t rd_axi_buf     ;       // Output of read-path skid buffer

// 4. Aux Logic & Parity Signals
//=========================================

parameter batchZize = PDATA_WIDTH*8/PWUSER_WIDTH ;
logic [PWUSER_WIDTH-1:0] calcIn_parity_in ;
logic [PWUSER_WIDTH-1:0] calcOut_parity ;
logic [PWUSER_WIDTH-1:0] origin_parity  ;
logic [PWUSER_WIDTH-1:0] wr_isRuined_in ;
logic [PWUSER_WIDTH-1:0] rd_isRuined    ;
logic [PLENGTH_WIDTH-1:0] sent_transfer ;

// 5. Instantiations
//=========================================
special_mem_dpbank_v2 memory (
	.clk(clk),
	.wr_en(wr_stg1_valid),
	.wr_addr({wr_stg1_bus.wr_idx, wr_stg1_bus.cur_len_stg1}),
	.wr_data(wr_stg1_bus.beat.wdata),
	.wr_strb(wr_stg1_bus.beat.wstrb),
	.wr_parity(wr_stg1_bus.beat.wuser),
	.wr_isRuined(wr_stg1_bus.wr_isRuined),
	.rd_en(rd_stg1_en_q),
	.rd_addr(rd_stg1_addr_q),
	.rd_data(rd_stg2_data),
	.rd_strb(rd_stg2_strb),
	.rd_parity(origin_parity),
	.rd_isRuined(rd_isRuined)
);

// --- free-slot pick ---
logic [SPEC_SLOT_AMOUNT-1:0] alloc_oh, del_oh ;
logic [SPEC_SLOT_AMOUNT-1:0] free_mask ;

assign free_mask = ~bitmap_val_q ;
assign alloc_oh = in_awshake ? (free_mask & -free_mask) : '0 ;
assign del_oh = transfer_done ? (SPEC_SLOT_AMOUNT'(1) << rd_curr) : '0 ;

age_order #(SPEC_SLOT_AMOUNT) order (
    .clk(clk), .rst_n(rst_n),
    .alloc_en(in_awshake),   .alloc_oh(alloc_oh),
    .del_en  (transfer_done), .del_oh (del_oh),
    .bitmap_val_q (bitmap_val_q),       .age_q(age_q)
);

assign wr_bus_in = '{beat: '{wid: s_data.wid, wdata: s_data.wdata, wstrb: s_data.wstrb, wuser: s_data.wuser, wlast: s_data.wlast},
                     wr_idx: wr_idx_in, cur_len_stg1: spec_mem[wr_idx_in].cur_len, wr_isRuined: wr_isRuined_in};
pipe_reg #($bits(wr_pipe_data_t)) wr_data_pipe (
    .clk(clk), .rst_n(rst_n),
    .up_valid(s_data.wvalid & wr_id_match),  .dn_valid(wr_stg1_valid),
    .up_ready(pipe_up_ready),                .dn_ready(1'b1),
    .up_data(wr_bus_in),                     .dn_data(wr_stg1_bus)
);

assign pipe_raw_in = '{wid: rd_stg1_wid_q, wdata: rd_stg2_data, wstrb: rd_stg2_strb, 
                       origin_parity: origin_parity, rd_isRuined: rd_isRuined, wlast: rd_stg1_wlast_q} ;
pipe_reg #($bits(raw_rd_data_t)) rd_raw_pipe (
    .clk(clk), .rst_n(rst_n),
    .up_valid(rd_stg1_en_q),   .dn_valid(rd_skid_valid),
    .up_ready(rd_pipe_up_ready),  .dn_ready(rd_skid_ready),
    .up_data(pipe_raw_in),     .dn_data(pipe_raw_out)
);

assign rd_skid_bus_in = '{wid: pipe_raw_out.wid, wdata: pipe_raw_out.wdata, 
                          wstrb: pipe_raw_out.wstrb, wuser: rd_stg2_user, wlast: pipe_raw_out.wlast} ;
skid_buffer #($bits(w_beat_t)) data_skid (
    .clk(clk), .rst_n(rst_n),
    .up_valid(rd_skid_valid),  .dn_valid(m_data.wvalid),
    .up_ready(rd_skid_ready),  .dn_ready(m_data.wready),
    .up_data(rd_skid_bus_in),  .dn_data(rd_axi_buf)
);

// Pre-register m_add payload for all transactions (Fix B)
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin 
		m_add_vld_q <= 1'b0 ; 
	end else begin
		if (load_release) begin 
			m_add_q <= '{awid: spec_mem[rd_next].awid, awlen: spec_mem[rd_next].awlen, awburst: spec_mem[rd_next].awburst,
			             awaddr: spec_mem[rd_next].awaddr, awsize: spec_mem[rd_next].awsize, awuser: spec_mem[rd_next].awuser, other: spec_mem[rd_next].other};
			m_add_vld_q <= 1'b1 ; 
		end else if (m_add.awready) begin
			m_add_vld_q <= 1'b0 ;
		end
	end
end

// 6. Continuous Assignments
//=========================================
logic [SPEC_SLOT_AMOUNT-1:0] bitmap_val_next ;
wire spec_nonempty = |bitmap_val_q ;
always_comb begin
    bitmap_val_next = bitmap_val_q ;
    if (in_awshake) bitmap_val_next = bitmap_val_next | alloc_oh ;
    if (transfer_done) bitmap_val_next = bitmap_val_next & ~del_oh ;
end

// --- Communication ----
assign spec2router = (tran_valid & tran_ready) | ~tran_ready ;
assign s_add.awready = s_add.awvalid & ~to_block & ~mem_full & ~proc_full &
 						~proc_empty & ((s_add.awuser === DIVERT) | unluck) ;
assign in_awshake = s_add.awvalid & s_add.awready ;
assign s_data.wready = pipe_up_ready & wr_id_match ;

// --- Read Path Flow ---
assign transfer_done = (~tran_ready) & (sent_transfer == spec_mem[rd_curr].awlen) & rd_pipe_up_ready ;
assign rd_addr = tran_ready ? rd_next : rd_curr ;			

// Connect rd_axi_buf directly to AXI master
assign m_data.wid   = rd_axi_buf.wid ;
assign m_data.wdata = rd_axi_buf.wdata ;
assign m_data.wstrb = rd_axi_buf.wstrb ;
assign m_data.wuser = rd_axi_buf.wuser ;
assign m_data.wlast = rd_axi_buf.wlast ;

// 7. Combinational Search & Match Logic
//=========================================
logic [SPEC_SLOT_AMOUNT-1:0] done_vec, unluck_vec ;
logic [SPEC_SLOT_AMOUNT-1:0] wr_match_cand, wr_oh ;
logic [SPEC_SLOT_AMOUNT-1:0] unluck_cand, unluck_oh ;

always_comb begin
    unluck = 1'b0 ;
    for (int j = 0; j < SPEC_SLOT_AMOUNT; j++) begin
        done_vec[j] = spec_mem[j].done ;
        unluck_vec[j] = spec_mem[j].unluck ;
        wr_match_cand[j] = bitmap_val_q[j] & ~spec_mem[j].done & (spec_mem[j].awid == s_data.wid) ;
        unluck_cand[j] = bitmap_val_q[j] & spec_mem[j].done  & (spec_mem[j].awid == d_cur_id) ;
        
        if (s_add.awvalid & bitmap_val_q[j] & (spec_mem[j].awid == s_add.awid) & (|(s_add.awuser ^ DIVERT)))
            unluck = 1'b1 ;
    end
    wr_oh = oldest(wr_match_cand, age_q) ;
    wr_id_match = |wr_match_cand ;
    wr_idx_in = enc_oh(wr_oh) ;
    unluck_oh = oldest(unluck_cand, age_q) ;
end
assign found_unluck = |(unluck_oh & unluck_vec) ;  // late-decode: removes 16:1 mux and binary encoder

logic [SPEC_SLOT_AMOUNT-1:0] head_oh ;
logic [INDEX_WIDTH-1:0]      head_idx ;

assign head_oh = oldest(bitmap_val_q, age_q) ;
assign head_idx = enc_oh(head_oh) ;
assign first_done  = |(head_oh & done_vec) ;
assign first_unluck = |(head_oh & unluck_vec) ;
assign rd_next = found_unluck ? enc_oh(unluck_oh) : head_idx ;
assign cur_id = spec_mem[head_idx].awid ;

// One-hot read target + burst length selection.
// Late-decode: extracting awlen via one-hot. 
// OR-reduction: Removes Binary encoder + 16:1 mux from the critical path (enc_oh function)
logic [SPEC_SLOT_AMOUNT-1:0] rd_next_oh ;
logic [PLENGTH_WIDTH-1:0]    rd_next_awlen, rd_addr_awlen ;
assign rd_next_oh = found_unluck ? unluck_oh : head_oh ;   // one-hot form of rd_next (no enc_oh)
always_comb begin
    rd_next_awlen = '0 ;
    for (int j = 0; j < SPEC_SLOT_AMOUNT; j++)
        rd_next_awlen |= {PLENGTH_WIDTH{rd_next_oh[j]}} & spec_mem[j].awlen ;
end
// rd_curr is already flopped, so leaving its awlen mux binary is safe.
assign rd_addr_awlen = tran_ready ? rd_next_awlen : spec_mem[rd_curr].awlen ;

assign release_ready = tran_ready & spec_release & ~found_unluck & spec_nonempty & first_done ;
assign tran_valid = (release_ready | found_unluck | (first_unluck & first_done)) & spec_nonempty ;

//----------parity-start--------------------
always_comb begin
	for(int i = 0; i < PWUSER_WIDTH; i++) begin
		logic [batchZize-1:0]  mask ;
		logic [batchZize-1:0]  Omask ;

		for(int j = 0; j<batchZize/8; j++) begin
			mask[j*8 +: 8]  = {8{s_data.wstrb[i*(batchZize/8) + j]}} ;
			Omask[j*8 +: 8] = {8{pipe_raw_out.wstrb[i*(batchZize/8) + j]}} ;
		end

		calcIn_parity_in[i] = ^(s_data.wdata[i*batchZize/8 +: batchZize/8] & mask) ;
		calcOut_parity[i]   = ^(pipe_raw_out.wdata[i*batchZize/8 +: batchZize/8] & Omask) ;
	end
	wr_isRuined_in = calcIn_parity_in ^ s_data.wuser ;	
	rd_stg2_user = (pipe_raw_out.origin_parity & ~pipe_raw_out.rd_isRuined) | (~calcOut_parity & pipe_raw_out.rd_isRuined) ; //output
end

//--------------Transmit-start----------------------

// Output assignments (pure flop->port)
assign m_add.awvalid = m_add_vld_q ;
assign m_add.awburst = m_add_q.awburst ;
assign m_add.awid    = m_add_q.awid ;
assign m_add.awaddr  = m_add_q.awaddr ;
assign m_add.awlen   = m_add_q.awlen ;
assign m_add.awsize  = m_add_q.awsize ;
assign m_add.awuser  = m_add_q.awuser ;
assign m_add.other   = m_add_q.other ;

always_comb begin
	eu_next = eu_state ;
	load_release = 1'b0 ;
	case (eu_state)
		EU_IDLE    : if (tran_valid && tran_ready && ~m_add_vld_q) begin
						load_release = 1'b1     ;
						eu_next      = EU_ARMED ;
					end
		EU_ARMED   : if (m_add.awready) eu_next = EU_IDLE ;
		default    : eu_next = EU_IDLE ;
	endcase
end

always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) eu_state <= EU_IDLE ;
	else        eu_state <= eu_next ;
end

//--------------sending-end---------------------

assign idle_cycle   = tran_ready & ~tran_ready_q ;
assign prefetch_now = idle_cycle & found_unluck & rd_pipe_up_ready & (rd_next_awlen > '0) ;

// ---- Read/Transmit Pipeline & Prefetch ----
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		tran_ready      <= 1'b1 ;
		sent_transfer   <= '0 ;
		rd_curr         <= '0 ;
		tran_ready_q    <= 1'b1 ;
		rd_stg1_addr_q  <= '0 ;
		rd_stg1_en_q    <= '0 ;
		rd_stg1_wlast_q <= '0 ;
		rd_stg1_wid_q   <= '0 ;
	end else begin
		// 1. Transmit Tracker
		if(tran_ready) begin
			rd_curr <= rd_next ;
		end
		if(tran_valid & tran_ready) begin
			tran_ready <= 1'b0 ;
			if (prefetch_now) sent_transfer <= PLENGTH_WIDTH'(1) ;
		end else if (~tran_ready) begin
			if(rd_pipe_up_ready) begin
				sent_transfer <= sent_transfer + PLENGTH_WIDTH'(1) ;
			end
			if(transfer_done) begin
				sent_transfer <= '0 ;
				tran_ready <= 1'b1 ;
			end
		end

		// 2. Idle-cycle detector: triggers on the cycle after transfer_done.
		tran_ready_q <= tran_ready;

		// 3. rd_stg1 input mux: handles both normal reads and idle-cycle prefetching.
		if (rd_pipe_up_ready) begin
			if (prefetch_now) begin
				// Prefetch the unlucky's beat-0 into the naturally-free IDLE slot.
				rd_stg1_addr_q  <= {rd_next, {PLENGTH_WIDTH{1'b0}}} ;
				rd_stg1_en_q <= 1'b1;
				rd_stg1_wlast_q <= (rd_next_awlen == '0) ;
				rd_stg1_wid_q <= spec_mem[rd_next].awid ;
			end else begin
				rd_stg1_addr_q <= {rd_addr, sent_transfer} ;
				rd_stg1_en_q <= ~tran_ready ;
				rd_stg1_wlast_q <= (sent_transfer == rd_addr_awlen) ;
				rd_stg1_wid_q <= spec_mem[rd_addr].awid ;
			end
		end
	end
end

genvar i;
generate
	for (i = 0; i < SPEC_SLOT_AMOUNT; i++) begin : For_Spec_Mem
		always_ff @(posedge clk or negedge rst_n) begin
			if (!rst_n) begin
				spec_mem[i] <= '{done: 1'b1, default: '0};
			end else begin
				// allocate (free slot chosen by alloc_oh)
				if (in_awshake & alloc_oh[i]) begin
					spec_mem[i] <= '{awburst: s_add.awburst, awid: s_add.awid, awaddr: s_add.awaddr, awlen: s_add.awlen,
					                 awsize: s_add.awsize, awuser: s_add.awuser, other: s_add.other, unluck: unluck, done: 1'b0, cur_len: '0} ;
				end
				// cur_len bump when a beat enters the write pipe (front of pipe)
				if (pipe_up_ready & s_data.wvalid & wr_id_match & (i == wr_idx_in))
					spec_mem[i].cur_len <= spec_mem[i].cur_len + PLENGTH_WIDTH'(1) ;
				// done set when final beat is written to SRAM (back of pipe)
				if (wr_stg1_valid & wr_stg1_bus.beat.wlast & (i == wr_stg1_bus.wr_idx))
					spec_mem[i].done <= 1'b1 ;
			end
		end
	end
endgenerate


// ---- State & Metrics ----
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		mem_full   <= 1'b0 ;
		spec_count <= '0 ;
		d_cur_id   <= '0 ;
	end else begin
		// 1. Memory Full Flag
		mem_full <= &bitmap_val_next ;

		// 2. Counters & IDs
		if(release_ready) begin
			d_cur_id <= cur_id ;
		end
		if(in_awshake & ~transfer_done) begin
			spec_count <= spec_count + 1 ;
		end else if(transfer_done & ~in_awshake) begin
			spec_count <= spec_count - 1 ;
		end
	end
end




// synthesis translate_off

// 1. Count Bounds: occupancy bitmap count <= max slots.
as1_count_bounds: assert property (@(posedge clk) disable iff (!rst_n)
	$countones(bitmap_val_q) <= SPEC_SLOT_AMOUNT)
	else $fatal("Violation: bitmap count (%0d) > SPEC_SLOT_AMOUNT", $countones(bitmap_val_q));

// 3. Full Protection: do not accept a new burst when memory is full.
as3_full_prot: assert property (@(posedge clk) disable iff (!rst_n)
	mem_full |-> !s_add.awready)
	else $fatal("Violation: s_add.awready is High while memory is Full");

// 4. Empty Protection: cannot start a new release transfer when memory is empty.
as4_empty_prot: assert property (@(posedge clk) disable iff (!rst_n)
	~|bitmap_val_q |-> !(tran_valid & tran_ready))
	else $fatal("Violation: new transfer launched while memory is Empty");

// 6. Data Validity: a slot can only be read after its write side is complete.
as6_read_done: assert property (@(posedge clk) disable iff (!rst_n)
	(~tran_ready) |-> spec_mem[rd_curr].done)
	else $fatal("Violation: rd_curr slot %0d marked not 'done'", rd_curr);

// 7. Write ID Matching: incoming write must match the target slot's ID.
as7_id_match: assert property (@(posedge clk) disable iff (!rst_n)
	(wr_stg1_valid) |-> (spec_mem[wr_stg1_bus.wr_idx].awid == wr_stg1_bus.beat.wid))
	else $fatal("Violation: wr_stg1_bus.beat.wid (%h) does not match target slot ID (%h)", wr_stg1_bus.beat.wid, spec_mem[wr_stg1_bus.wr_idx].awid);

// 8. Write After Done: cannot write to a slot already marked 'done'.
as8_no_wr_done: assert property (@(posedge clk) disable iff (!rst_n)
	(wr_stg1_valid) |-> !spec_mem[wr_stg1_bus.wr_idx].done)
	else $fatal("Violation: Writing data to slot %0d already marked 'done'", wr_stg1_bus.wr_idx);

// 9. wlast Accuracy: the latched wlast at the SRAM-read stage must correspond
as9_wlast_acc: assert property (@(posedge clk) disable iff (!rst_n)
	(rd_stg1_en_q & rd_stg1_wlast_q) |->
		(rd_stg1_addr_q[PLENGTH_WIDTH-1:0]
			== spec_mem[rd_stg1_addr_q[INDEX_WIDTH+PLENGTH_WIDTH-1:PLENGTH_WIDTH]].awlen))
	else $fatal("Violation: rd_stg1_wlast_q asserted but offset (%0d) != slot awlen (%0d)",
		rd_stg1_addr_q[PLENGTH_WIDTH-1:0],
		spec_mem[rd_stg1_addr_q[INDEX_WIDTH+PLENGTH_WIDTH-1:PLENGTH_WIDTH]].awlen);

// 10. One-Hot Integrity
as10_one_hot: assert property (@(posedge clk) disable iff (!rst_n)
	$onehot0(head_oh) && $onehot0(wr_oh) && $onehot0(unluck_oh))
	else $fatal("Violation: one-hot vectors are not one-hot");

// 14. EU FSM liveness
as14_eu_progress: assert property (@(posedge clk) disable iff (!rst_n)
	(eu_state == EU_ARMED) |-> ##[1:$] (eu_state == EU_IDLE))
	else $fatal("EU FSM stuck in EU_ARMED: m_add never accepted");

// 15. Address issue
as15_addr_issued: assert property (@(posedge clk) disable iff (!rst_n)
	load_release |-> ##[1:$] (m_add.awvalid & m_add.awready))
	else $fatal("Released transaction never issued its address on m_add");

// 16. sent_transfer never overruns
as16_sent_bound: assert property (@(posedge clk) disable iff (!rst_n)
	(~tran_ready) |-> (sent_transfer <= spec_mem[rd_curr].awlen))
	else $fatal("sent_transfer (%0d) overran awlen (%0d) of slot %0d", sent_transfer, spec_mem[rd_curr].awlen, rd_curr);

// 17-19. X-DETECTION BATTERY
as17_rden_x: assert property (@(posedge clk) disable iff (!rst_n)
	!$isunknown(rd_stg1_en_q))
	else $fatal("rd_stg1_en_q (SRAM rd_en / OEB2) is X");

as18_rdaddr_x: assert property (@(posedge clk) disable iff (!rst_n)
	rd_stg1_en_q |-> !$isunknown(rd_stg1_addr_q))
	else $fatal("rd_stg1_addr_q is X while rd_en asserted");

as19_sel_x: assert property (@(posedge clk) disable iff (!rst_n)
	!$isunknown({tran_ready, found_unluck, prefetch_now, rd_next, rd_curr, rd_addr, bitmap_val_q}))
	else $fatal("read-select control net is X (tr=%b fu=%b pf=%b)", tran_ready, found_unluck, prefetch_now);

// 21. Counters clean
as21_count_x: assert property (@(posedge clk) disable iff (!rst_n)
	!$isunknown({spec_count, d_cur_id}))
	else $fatal("count/id net is X");

// 24. A read is only issued against a slot whose write side is complete.
as24_rd_done: assert property (@(posedge clk) disable iff (!rst_n)
	rd_stg1_en_q |-> spec_mem[rd_stg1_addr_q[INDEX_WIDTH+PLENGTH_WIDTH-1:PLENGTH_WIDTH]].done)
	else $fatal("read issued to slot %0d which is not done",
		rd_stg1_addr_q[INDEX_WIDTH+PLENGTH_WIDTH-1:PLENGTH_WIDTH]);

// 25. While releasing an unlucky train, the released id must equal d_cur_id.
as25_train_id: assert property (@(posedge clk) disable iff (!rst_n)
	(found_unluck & tran_ready) |-> (spec_mem[rd_next].awid == d_cur_id))
	else $fatal("unlucky-train release slot %0d id (%0h) != d_cur_id (%0h)", rd_next, spec_mem[rd_next].awid, d_cur_id);

// ---- Parity / wuser X-localization ----
// Identifies the source of any X on the wuser bus:
// as26: Stored as X (input undefined)
// as27: Read as X (SRAM model issue)
// as28: Egress recomputation introduced X
as26_wr_parity_x: assert property (@(posedge clk) disable iff (!rst_n)
	(wr_stg1_valid) |-> !$isunknown({wr_stg1_bus.beat.wuser, wr_stg1_bus.wr_isRuined}))
	else $fatal("STORE parity X: slot=%0d off=%0d wuser=%b isRuined=%b (root is write-side / s_data.wuser)",
		wr_stg1_bus.wr_idx, wr_stg1_bus.cur_len_stg1, wr_stg1_bus.beat.wuser, wr_stg1_bus.wr_isRuined);

as27_rd_parity_x: assert property (@(posedge clk) disable iff (!rst_n)
	rd_stg1_en_q |-> !$isunknown({origin_parity, rd_isRuined}))
	else $fatal("READ parity X from SRAM: rd_addr=%h origin_parity=%b rd_isRuined=%b (cell read but not written, or parity-bank model)",
		rd_stg1_addr_q, origin_parity, rd_isRuined);

as28_out_wuser_x: assert property (@(posedge clk) disable iff (!rst_n)
	rd_skid_valid |-> !$isunknown(rd_stg2_user))
	else $fatal("EGRESS wuser X: origin_parity=%b rd_isRuined=%b calcOut=%b (recompute introduced X)",
		pipe_raw_out.origin_parity, pipe_raw_out.rd_isRuined, calcOut_parity);

// as29: Checks if 'done' is set prematurely, causing read over-runs into unwritten cells.
as29_done_complete: assert property (@(posedge clk) disable iff (!rst_n)
	(wr_stg1_valid & wr_stg1_bus.beat.wlast)
		|-> (wr_stg1_bus.cur_len_stg1 == spec_mem[wr_stg1_bus.wr_idx].awlen))
	else $fatal("done set early: slot %0d wlast at off %0d but awlen %0d -> read over-runs into X",
		wr_stg1_bus.wr_idx, wr_stg1_bus.cur_len_stg1, spec_mem[wr_stg1_bus.wr_idx].awlen);

// age-matrix invariants
genvar a_i, a_j;
generate for (a_i=0; a_i<SPEC_SLOT_AMOUNT; a_i++)
  for (a_j=0; a_j<SPEC_SLOT_AMOUNT; a_j++) if (a_i!=a_j) begin
    asA_antisym: assert property (@(posedge clk) disable iff (!rst_n)
      (bitmap_val_q[a_i] & bitmap_val_q[a_j] & age_q[a_i][a_j]) |-> ~age_q[a_j][a_i])
      else $fatal("age antisymmetry violated: %0d,%0d", a_i, a_j);
  end
endgenerate

always @(posedge clk) if (rst_n)
  for (int k=0;k<SPEC_SLOT_AMOUNT;k++)
    if (!bitmap_val_q[k])
      for (int j=0;j<SPEC_SLOT_AMOUNT;j++)
        asB_freecol: assert (age_q[j][k]==1'b0)
          else $fatal("freed slot %0d still in row %0d", k, j);

asC_alloc_snapshot: assert property (@(posedge clk) disable iff (!rst_n)
  (in_awshake) |=> (age_q[$past(enc_oh(alloc_oh))] == $past(bitmap_val_q & ~del_oh)))
  else $fatal("alloc snapshot wrong");


wire dbg_progress = in_awshake | transfer_done | release_ready
                  | (m_add.awvalid  & m_add.awready)
                  | (m_data.wvalid  & m_data.wready)
                  | (s_data.wvalid  & s_data.wready);
wire dbg_pending  = (|bitmap_val_q) | ~tran_ready | spec_release;

integer dbg_idle_cnt;
always @(posedge clk or negedge rst_n) begin
	if (!rst_n)                            dbg_idle_cnt <= 0;
	else if (dbg_progress | ~dbg_pending) dbg_idle_cnt <= 0;
	else                                   dbg_idle_cnt <= dbg_idle_cnt + 1;
end

always @(posedge clk) begin
	if (rst_n && dbg_idle_cnt == 400) begin
		$display("==========================================================================");
		$display("[SPECMEM WATCHDOG @%0t] NO PROGRESS 400 cyc while work pending -> DEADLOCK", $time);
		$display("  bitmap_val_q=%b  mem_full=%b", bitmap_val_q, mem_full);
		$display("  INPUTS : spec_release=%b to_block=%b proc_full=%b proc_empty=%b", spec_release, to_block, proc_full, proc_empty);
		$display("  RELEASE: tran_valid=%b tran_ready=%b release_ready=%b found_unluck=%b", tran_valid, tran_ready, release_ready, found_unluck);
		$display("           first_done=%b first_unluck=%b unluck=%b spec2router=%b", first_done, first_unluck, unluck, spec2router);
		$display("  READ   : rd_curr=%0d rd_next=%0d rd_addr=%0d sent_transfer=%0d", rd_curr, rd_next, rd_addr, sent_transfer);
		$display("  PIPES  : rd_pipe_up_ready=%b rd_skid_valid=%b rd_skid_ready=%b m_data(v=%b r=%b)", rd_pipe_up_ready, rd_skid_valid, rd_skid_ready, m_data.wvalid, m_data.wready);
		$display("  ADDR   : eu_state=%0d load_release=%b m_add(v=%b r=%b) m_add_vld_q=%b d_cur_id=%0d", int'(eu_state), load_release, m_add.awvalid, m_add.awready, m_add_vld_q, d_cur_id);
		$display("  CODER  : head_oh=%b unluck_oh=%b wr_oh=%b alloc_oh=%b del_oh=%b", head_oh, unluck_oh, wr_oh, alloc_oh, del_oh);
		for (int k = 0; k < SPEC_SLOT_AMOUNT; k++)
			$display("    slot[%0d] valid=%b awid=%0d done=%b unluck=%b awlen=%0d cur_len=%0d awuser=%b age_row=%b",
				k, bitmap_val_q[k], spec_mem[k].awid, spec_mem[k].done,
				spec_mem[k].unluck, spec_mem[k].awlen, spec_mem[k].cur_len, spec_mem[k].awuser, age_q[k]);
		$display("==========================================================================");
		$fatal("[SPECMEM] deadlock watchdog tripped @%0t", $time);
	end
end

always @(posedge clk) begin
	if (rst_n) begin
		if (in_awshake)
			$display("[SPECMEM @%0t] INSERT  awid=%0d awuser=%b awlen=%0d unluck=%b -> next_free_idx=%0d",
				$time, s_add.awid, s_add.awuser, s_add.awlen, unluck, enc_oh(alloc_oh));
		if (tran_valid & tran_ready)
			$display("[SPECMEM @%0t] REL-START slot=%0d awid=%0d kind=%s",
				$time, rd_next, spec_mem[rd_next].awid, (found_unluck ? "UNLUCKY" : "SPECIAL"));
		if (transfer_done)
			$display("[SPECMEM @%0t] REL-DONE  slot=%0d awid=%0d", $time, rd_curr, spec_mem[rd_curr].awid);
	end
end

// synthesis translate_on

endmodule
