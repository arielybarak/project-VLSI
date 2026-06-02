/*------------------------------------------------------------------------------
 * File          : special_memory.sv
 * Project       : RTL
 * Author        : epabab
 * Creation date : Aug 23, 2024
 * Description   : Upgraded linked list type memory, Stores Special and Unlucky transactions. Arbitrator. 
 * Main functions: Incoming Address and Data channel's data selector. Stores and releases data. communicate with Masters and Slave (AXI).
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
spec_slot [SPEC_SLOT_AMOUNT-1:0]  spec_mem 		    ;
logic  	  [SPEC_SLOT_AMOUNT-1:0]  spec_mem_unluck   ;
logic	  [SPEC_SLOT_AMOUNT-1:0]  one_hot_slot_zero ;
reg	  	  [INDEX_WIDTH:0] 	      spec_count 		;

logic	  [INDEX_WIDTH-1:0]  	  wr_idx_in   ;
logic  	  [INDEX_WIDTH-1:0]		  rd_next  ;
logic  	  [INDEX_WIDTH-1:0]		  rd_curr  ; 
logic  	  [INDEX_WIDTH-1:0]		  rd_addr  ; 
logic  	  [INDEX_WIDTH-1:0]		  next_slot_idx ;
logic 	  [PID_WIDTH-1:0] 		  cur_id 		;
reg 	  [PID_WIDTH-1:0] 		  d_cur_id 		;

reg	  mem_full 	    ;
wire  found_unluck  ;
logic tran_valid    ;
logic tran_ready    ;
logic first_done    ;
logic first_unluck  ;
// logic d_awvalid removed
logic in_awshake    ;
logic transfer_done ;
logic tran_done_q;
logic [INDEX_WIDTH-1:0] tran_done_addr_q;

// --- Unlucky early-fire (Phase 1): registered m_add payload + FSM ---
typedef enum logic [0:0] {
    EU_IDLE,
    EU_ARMED
} eu_state_t; //early-unluck
eu_state_t eu_state, eu_next;

add_t m_add_q;
logic m_add_vld_q;
logic load_release;

// --- Unlucky idle-cycle prefetch (Phase 2) ---
logic tran_ready_q ;     // tran_ready delayed by 1 — used to detect the IDLE cycle (0→1 edge)
logic idle_cycle   ;     // 1 on the cycle right after transfer_done (when rd_stg1 would naturally go idle)
logic prefetch_now ;     // 1-cycle pulse: load rd_stg1 with the unlucky's beat-0 on this cycle

// 2. Pipeline Optimization Stage
//=========================================
// --- Read Path: Flow: Address Logic -> [rd_stg1 REG] -> SRAM ---
logic [INDEX_WIDTH+PLENGTH_WIDTH-1:0] rd_stg1_addr_q  ;
logic                                 rd_stg1_en_q 	  ;
logic [PID_WIDTH-1:0]                 rd_stg1_wid_q   ;
logic                                 rd_stg1_wlast_q ;
// --- Write Path: Breaks the forward timing path (AXI s_data to SRAM) ---
logic       wr_stg1_valid ;
logic       wr_stg1_ready ;
wr_skid_data_t wr_stg1_bus   ;

// 3. AXI Flow Control (Skid Buffers) for protocol compliance / backpressure handling.
//=========================================
// --- Write Path ---
// Flow: AXI s_data -> [wr_stg1 PIPE] -> [wr_axi_buf SKID] -> ID-Match & Parity Logic -> SRAM
logic 		pipe_up_ready ;
logic 		wr_id_match   ;
logic       wr_skid_valid ;
logic       wr_skid_ready ;
wr_skid_data_t wr_bus_in	  ;
wr_skid_data_t wr_axi_buf	  ;       // Output of write-path skid buffer

// --- Read Path ---
// Flow: SRAM Output -> [rd_axi_buf SKID] -> AXI m_data
logic [PDATA_WIDTH*8-1:0] rd_stg2_data ;
logic [PDATA_WIDTH-1:0]   rd_stg2_strb ;
logic [PWUSER_WIDTH-1:0]  rd_stg2_user ;

typedef struct packed {
    logic [PID_WIDTH-1:0]       wid;
    logic [(PDATA_WIDTH*8)-1:0] wdata;
    logic [PDATA_WIDTH-1:0]     wstrb;
    logic [PWUSER_WIDTH-1:0]    origin_parity;
    logic [PWUSER_WIDTH-1:0]    rd_isRuined;
    logic                       wlast;
} raw_rd_data_t;

raw_rd_data_t pipe_raw_in, pipe_raw_out;
logic       rd_pipe_up_ready;
logic       rd_skid_valid  ;
logic       rd_skid_ready  ;
skid_data_t rd_skid_bus_in ;
skid_data_t rd_axi_buf     ;       // Output of read-path skid buffer

// 4. Aux Logic & Parity Signals
//=========================================

logic [INDEX_WIDTH-1:0] effective_index [0:SPEC_SLOT_AMOUNT-1];
logic [INDEX_WIDTH:0]   spec_occ;

always_comb begin
    // Live occupancy this cycle: registered count minus the deferred delete.
    // NEVER folds in in_awshake -> input accept path stays combinational-loop-free,
    // and is more correct (a just-accepted slot is not written until the next edge).
    spec_occ = tran_done_q ? (spec_count - 1'b1) : spec_count;

    for (int j=0; j<SPEC_SLOT_AMOUNT; j++) begin
        if (tran_done_q) begin
            if (j == tran_done_addr_q)
                effective_index[j] = spec_count - 1;
            else if ((spec_mem[j].index > spec_mem[tran_done_addr_q].index) && (spec_mem[j].index < spec_count))
                effective_index[j] = spec_mem[j].index - 1;
            else
                effective_index[j] = spec_mem[j].index;
        end else begin
            effective_index[j] = spec_mem[j].index;
        end
    end
end

reg [SPEC_SLOT_AMOUNT-1:0] prior_coder_in 		   ;
wire [SPEC_SLOT_AMOUNT-1:0] prior_coder_out 	   ;
reg [SPEC_SLOT_AMOUNT-1:0] reverse_prior_coder_out ;
wire zeros ;

parameter batchZize = PDATA_WIDTH*8/PWUSER_WIDTH;
logic [PWUSER_WIDTH-1:0] calcIn_parity_in ;
logic [PWUSER_WIDTH-1:0] calcOut_parity ;
logic [PWUSER_WIDTH-1:0] origin_parity  ;
logic [PWUSER_WIDTH-1:0] wr_isRuined_in ;
logic [PWUSER_WIDTH-1:0] rd_isRuined    ;
logic [PLENGTH_WIDTH-1:0] sent_transfer ;

// 5. Instantiations
//=========================================

special_mem_dpbank memory (
	.clk(clk),
	.wr_en(wr_skid_ready & wr_skid_valid),
	.wr_addr({wr_axi_buf.wr_idx, wr_axi_buf.cur_len_stg1}),
	.wr_data(wr_axi_buf.wdata),
	.wr_strb(wr_axi_buf.wstrb),
	.wr_parity(wr_axi_buf.wuser),
	.wr_isRuined(wr_axi_buf.wr_isRuined),
	.rd_en(rd_stg1_en_q),
	.rd_addr(rd_stg1_addr_q),
	.rd_data(rd_stg2_data),
	.rd_strb(rd_stg2_strb),
	.rd_parity(origin_parity),
	.rd_isRuined(rd_isRuined)
);

DW_pricod #(SPEC_SLOT_AMOUNT) priority_decoder (
	.a   (prior_coder_in ),
	.cod (prior_coder_out),
	.zero(zeros          )
);

assign wr_bus_in = '{
    wid: s_data.wid, 
    wdata: s_data.wdata, 
    wstrb: s_data.wstrb, 
    wuser: s_data.wuser, 
    wlast: s_data.wlast,
    wr_idx: wr_idx_in,
    cur_len_stg1: spec_mem[wr_idx_in].cur_len,
    wr_isRuined: wr_isRuined_in
};
pipe_reg #($bits(wr_skid_data_t)) wr_data_pipe (
    .clk(clk), .rst_n(rst_n),
    .up_valid(s_data.wvalid & wr_id_match),  .dn_valid(wr_stg1_valid),
    .up_ready(pipe_up_ready),                .dn_ready(wr_stg1_ready),
    .up_data(wr_bus_in),                     .dn_data(wr_stg1_bus)
);

skid_buffer #($bits(wr_skid_data_t)) wr_data_skid (
    .clk(clk), .rst_n(rst_n),
    .up_valid(wr_stg1_valid),  .dn_valid(wr_skid_valid),
    .up_ready(wr_stg1_ready),  .dn_ready(wr_skid_ready),
    .up_data(wr_stg1_bus),     .dn_data(wr_axi_buf)
);

assign pipe_raw_in = '{
    wid: rd_stg1_wid_q, 
    wdata: rd_stg2_data, 
    wstrb: rd_stg2_strb, 
    origin_parity: origin_parity, 
    rd_isRuined: rd_isRuined, 
    wlast: rd_stg1_wlast_q
};

pipe_reg #($bits(raw_rd_data_t)) rd_raw_pipe (
    .clk(clk), .rst_n(rst_n),
    .up_valid(rd_stg1_en_q),   .dn_valid(rd_skid_valid),
    .up_ready(rd_pipe_up_ready),  .dn_ready(rd_skid_ready),
    .up_data(pipe_raw_in),     .dn_data(pipe_raw_out)
);

assign rd_skid_bus_in = '{
    wid: pipe_raw_out.wid, 
    wdata: pipe_raw_out.wdata, 
    wstrb: pipe_raw_out.wstrb, 
    wuser: rd_stg2_user, 
    wlast: pipe_raw_out.wlast
};

skid_buffer #($bits(skid_data_t)) data_skid (
    .clk(clk), .rst_n(rst_n),
    .up_valid(rd_skid_valid),  .dn_valid(m_data.wvalid),
    .up_ready(rd_skid_ready),  .dn_ready(m_data.wready),
    .up_data(rd_skid_bus_in),  .dn_data(rd_axi_buf)
);

// Pre-register m_add payload for all transactions (Fix B)
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin 
		m_add_vld_q <= 1'b0; 
	end else begin
		if (load_release) begin 
			m_add_q <= '{
				awid    : spec_mem[rd_next].awid    ,
				awlen   : spec_mem[rd_next].awlen   ,
				awburst : spec_mem[rd_next].awburst ,
				awaddr  : spec_mem[rd_next].awaddr  ,
				awsize  : spec_mem[rd_next].awsize  ,
				awuser  : spec_mem[rd_next].awuser  ,
				other   : spec_mem[rd_next].other
			};
			m_add_vld_q <= 1'b1; 
		end else if (m_add.awready) begin
			m_add_vld_q <= 1'b0;
		end
	end
end

// 6. Continuous Assignments
//=========================================

// mem_full is REGISTERED off the registered count (mirrors process_mem's full/empty).
// awready therefore gates on a flop -> the in_awshake->mem_full->awready combinational
// loop is impossible by construction, and the compare leaves the awready critical path.
wire spec_inc = in_awshake & ~tran_done_q ;   // same terms as the spec_count update
wire spec_dec = tran_done_q & ~in_awshake ;
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) mem_full <= 1'b0 ;
	else        mem_full <= ((spec_count + spec_inc - spec_dec) == SPEC_SLOT_AMOUNT) ;
end
// ~zeros gate: when prior_coder_in is all-zero DW_pricod leaves `cod` undefined.
// Without this gate a stale ghost `unluck` bit in spec_mem_unluck ANDs with the
// X cod -> found_unluck X -> rd_en/OEB2 X -> self-sustaining X churn (test-6 hang).
assign found_unluck = ~zeros & |(spec_mem_unluck & reverse_prior_coder_out) ;
assign tran_valid = (release_ready | found_unluck | (first_unluck & first_done)) & (spec_occ > '0) ;
assign first_unluck = spec_mem_unluck[0] ;

// --- Communication ----
assign release_ready = tran_ready & spec_release & ~found_unluck & (spec_occ > '0) & first_done ;
assign spec2router = (tran_valid & tran_ready) | ~tran_ready ;
assign s_add.awready = s_add.awvalid & ~to_block & ~mem_full & ~proc_full & ~proc_empty & ((s_add.awuser === DIVERT) | unluck) ;
assign in_awshake = s_add.awvalid & s_add.awready ;
assign s_data.wready = pipe_up_ready & wr_id_match;

// --- Read Path Flow ---
assign transfer_done = (~tran_ready) & (sent_transfer == spec_mem[rd_curr].awlen) & rd_pipe_up_ready;
assign rd_addr = tran_ready ? rd_next : rd_curr ;			// Look-Ahead Mux/Address Bypass logic

// Connect rd_axi_buf directly to AXI master
assign m_data.wid   = rd_axi_buf.wid;
assign m_data.wdata = rd_axi_buf.wdata;
assign m_data.wstrb = rd_axi_buf.wstrb;
assign m_data.wuser = rd_axi_buf.wuser;
assign m_data.wlast = rd_axi_buf.wlast;

// 7. Combinational Search & Match Logic
//=========================================

always_comb begin
	wr_id_match = 1'b0;
	wr_idx_in = 0 ;
	for(int j=0; j<SPEC_SLOT_AMOUNT; j++) begin
		// Match logic (Front of wr pipe): Asserts wr_id_match if incoming ID matches a special transaction.
		// This gates the pipe input and asserts s_data.wready to claim data from the router.
		if ((~|(spec_mem[j].awid^s_data.wid)) & (~spec_mem[j].done) & (effective_index[j] < spec_occ)) begin
			wr_id_match = 1'b1;
			wr_idx_in = INDEX_WIDTH'(j) ;
		end
	end
	// SRAM is always ready to receive data from the skid buffer.
	wr_skid_ready = 1'b1 ;
end

always_comb begin
	first_done = 1'b0 ;														
	unluck = 1'b0 ;
	cur_id = '0 ;
	spec_mem_unluck = '0 ;	
	prior_coder_in = '0 ;
	next_slot_idx = '0 ;
	rd_next = '0 ;
	
	for(int j=0; j<SPEC_SLOT_AMOUNT; j++) begin : x1											
		one_hot_slot_zero[j] = (effective_index[j] == '0) ? 1'b1 : 1'b0 ;		
																								///// transaction train operator /////
		spec_mem_unluck[effective_index[j]] = spec_mem[j].unluck ;										//-----unlucky search mechanism-----//
		reverse_prior_coder_out[j] = prior_coder_out[SPEC_SLOT_AMOUNT-1-j] ;
		prior_coder_in[SPEC_SLOT_AMOUNT-1-effective_index[j]] = (~|(spec_mem[j].awid^d_cur_id)) & (effective_index[j] < spec_occ) & spec_mem[j].done & ~(tran_done_q & (j == tran_done_addr_q)) ;
		
		if(found_unluck) begin
			if(reverse_prior_coder_out[j]) begin
				next_slot_idx = INDEX_WIDTH'(j) ;
			end
		end 
		else if(one_hot_slot_zero === (1<<j) && ((first_unluck & first_done) || release_ready)) begin		//-----Special release-----//
			cur_id = spec_mem[j].awid ;
		end
																									  	//-----new burst: luck check-----//
		if(s_add.awvalid && (spec_mem[j].awid === s_add.awid)
			&& (|(s_add.awuser^DIVERT)) && (effective_index[j] < spec_occ) && ~(tran_done_q & (j == tran_done_addr_q))) begin
			unluck = 1 ;
		end																				
		if(one_hot_slot_zero === (1<<j)) begin	
			first_done = spec_mem[j].done ;
		end
		if(effective_index[j] === next_slot_idx) begin	
			rd_next = j ;
		end
	end
end

//----------parity-start--------------------

always_comb begin
	for(int i = 0; i < PWUSER_WIDTH; i++) begin
//		logic [batchZize-1:0]  mask ;
//		logic [batchZize-1:0]  Omask ;
		
//		for(int j = 0; j<batchZize/8; j++) begin
//			mask[j*8 +: 8] = {8{s_data.wstrb[i*(batchZize/8) + j]}} ;
//			Omask[j*8 +: 8] = {8{m_data.wstrb[i*(batchZize/8) + j]}} ;
//		end

		// batchZize = (PDATA_WIDTH*8)/PWUSER_WIDTH = bits covered per parity bit (32).
		// Each of the PWUSER_WIDTH parity bits XORs its full batchZize-bit data group,
		// so all PDATA_WIDTH*8 data bits are covered (was batchZize/8 -> only low 32 bits).
		calcIn_parity_in[i] = ^(s_data.wdata[i*batchZize +: batchZize] /*& mask*/) ;
		calcOut_parity[i] = ^(pipe_raw_out.wdata[i*batchZize +: batchZize] /*& Omask*/) ;
	end
	wr_isRuined_in = calcIn_parity_in ^ s_data.wuser;	
	rd_stg2_user = (pipe_raw_out.origin_parity & ~pipe_raw_out.rd_isRuined) | (~calcOut_parity & pipe_raw_out.rd_isRuined) ; //output
end

//--------------Transmit-start----------------------

// Output assignments (pure flop->port)
assign m_add.awvalid = m_add_vld_q;
assign m_add.awburst = m_add_q.awburst;
assign m_add.awid    = m_add_q.awid;
assign m_add.awaddr  = m_add_q.awaddr;
assign m_add.awlen   = m_add_q.awlen;
assign m_add.awsize  = m_add_q.awsize;
assign m_add.awuser  = m_add_q.awuser;
assign m_add.other   = m_add_q.other;

always_comb begin
	eu_next = eu_state ;
	load_release = 1'b0 ;
	case (eu_state)
		EU_IDLE    : if (tran_valid && tran_ready && ~m_add_vld_q) begin
						load_release = 1'b1     ;
						eu_next      = EU_ARMED ;
					end
		// Return to IDLE the moment the address is accepted. Pacing to the data
		// stream is handled by tran_ready (can't re-arm until the next release is
		// selected) + m_add_vld_q backpressure -- NOT by waiting on transfer_done,
		// which is one cycle too slow for the 1-cycle idle gap left by the prefetch.
		EU_ARMED   : if (m_add.awready) eu_next = EU_IDLE;
		default    : eu_next = EU_IDLE;
	endcase
end

always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) eu_state <= EU_IDLE;
	else        eu_state <= eu_next;
end

always_ff @(posedge clk or negedge rst_n) begin
	if(~rst_n) begin
		tran_ready <= 1 ;
		sent_transfer <= 0 ;
		rd_curr <= 0 ;
	end
	else begin
		if(tran_ready) begin
			rd_curr <= rd_next ;
		end
		
		// d_awvalid removed (handled by m_add_vld_q logic)
		
		if(tran_valid & tran_ready) begin
			tran_ready <= 0 ;
			// Phase 2: if we prefetched beat-0 this same cycle, skip it so the
			// normal sequence starts at beat-1 instead of re-reading beat-0.
			if (prefetch_now) sent_transfer <= PLENGTH_WIDTH'(1) ;
		end
		else if (~tran_ready) begin
			if(rd_pipe_up_ready) begin
				sent_transfer <= sent_transfer + PLENGTH_WIDTH'(1) ;
			end
			if(transfer_done) begin
				sent_transfer <= 0 ;
				tran_ready <= 1 ;
			end
		end
	end
end

//--------------sending-end---------------------

// Phase 2: idle-cycle detector. tran_ready transitions 0→1 the cycle after transfer_done,
// which is exactly the cycle rd_stg1 would naturally go idle — perfect slot to prefetch into.
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) tran_ready_q <= 1'b1;
	else        tran_ready_q <= tran_ready;
end

assign idle_cycle   = tran_ready & ~tran_ready_q ;
assign prefetch_now = idle_cycle & found_unluck & rd_pipe_up_ready & (spec_mem[rd_next].awlen > '0);

// Phase 2: rd_stg1 input mux gains a prefetch branch on the IDLE cycle.
always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		rd_stg1_addr_q  <= '0;
		rd_stg1_en_q    <= '0;
		rd_stg1_wlast_q <= '0;
		rd_stg1_wid_q   <= '0;
	end else if (rd_pipe_up_ready) begin
		if (prefetch_now) begin
			// Prefetch the unlucky's beat-0 into the naturally-free IDLE slot.
			rd_stg1_addr_q  <= {rd_next, {PLENGTH_WIDTH{1'b0}}};
			rd_stg1_en_q    <= 1'b1;
			rd_stg1_wlast_q <= (spec_mem[rd_next].awlen == '0);
			rd_stg1_wid_q   <= spec_mem[rd_next].awid;
		end else begin
			rd_stg1_addr_q  <= {rd_addr, sent_transfer};
			rd_stg1_en_q    <= ~tran_ready;
			rd_stg1_wlast_q <= (sent_transfer == spec_mem[rd_addr].awlen);
			rd_stg1_wid_q   <= spec_mem[rd_addr].awid;
		end
	end
end

genvar i;
generate
	for (i = 0; i < SPEC_SLOT_AMOUNT; i++) begin	: For_Spec_Mem
		always_ff @(posedge clk or negedge rst_n) begin
			
			if(!rst_n) begin
				spec_mem[i].index <= INDEX_WIDTH'(i) ;
				spec_mem[i].awburst <= '0 ;
				spec_mem[i].awid <= '0    ;
				spec_mem[i].awaddr <= '0  ;
				spec_mem[i].awlen <= '0   ;
				spec_mem[i].awsize <= '0  ;
				spec_mem[i].awuser <= '0  ;
				spec_mem[i].unluck <= '0  ;
				spec_mem[i].other <= '0   ;
				spec_mem[i].done <= '1    ;
				spec_mem[i].cur_len <= '0 ;
			end
			else begin
				// --- Deferred Delete + Allocate (3-way mux) ---
				// Determine if this slot is the allocation target
				if (in_awshake) begin
					if (( tran_done_q && (i === tran_done_addr_q)) ||
					    (~tran_done_q && (spec_mem[i].index === spec_count))) begin
						spec_mem[i].awburst <= s_add.awburst ;
						spec_mem[i].awid    <= s_add.awid    ;
						spec_mem[i].awaddr  <= s_add.awaddr  ;
						spec_mem[i].awlen   <= s_add.awlen   ;
						spec_mem[i].awsize  <= s_add.awsize  ;
						spec_mem[i].awuser  <= s_add.awuser  ;
						spec_mem[i].unluck  <= unluck        ;
						spec_mem[i].other   <= s_add.other   ;
						spec_mem[i].done    <= 1'b0          ;
						spec_mem[i].cur_len <= '0            ;
						if (tran_done_q) spec_mem[i].index <= spec_count - 1 ;
					end
				end
				// --- Deferred Delete: shift indices (runs for both alloc+delete and delete-only) ---
				if (tran_done_q && (i !== tran_done_addr_q)) begin
					if ((spec_mem[i].index > spec_mem[tran_done_addr_q].index) && (spec_mem[i].index < spec_count))
						spec_mem[i].index <= spec_mem[i].index - INDEX_WIDTH'(1) ;
				end
				// --- Delete-only: recycle the deleted slot's index ---
				if (tran_done_q && ~in_awshake && (i === tran_done_addr_q)) begin
					spec_mem[i].index   <= spec_count - 1 ;
					spec_mem[i].cur_len <= '0 ;
				end
																				//-----Live transaction update-----//
				// 1. Increment cur_len when beat enters the pipe (front of pipe)
				if(pipe_up_ready & s_data.wvalid & wr_id_match & (i == wr_idx_in)) begin
					spec_mem[i].cur_len <= spec_mem[i].cur_len + PLENGTH_WIDTH'(1) ;
				end
				// 2. Set done when the final beat is written to SRAM (back of pipe)
				if(wr_skid_ready & wr_skid_valid & wr_axi_buf.wlast & (i == wr_axi_buf.wr_idx)) begin
					spec_mem[i].done <= 1'b1 ;
				end
			end
		end
	end
endgenerate


always_ff @(posedge clk or negedge rst_n) begin
	
	if (!rst_n) begin
		spec_count <= 0 ;
		d_cur_id <= 0 ;
		tran_done_q <= 0 ;
		tran_done_addr_q <= 0 ;
	end
	else begin
		
		if(release_ready) begin
			d_cur_id <= cur_id ;
		end
		
		tran_done_q <= transfer_done;
		if(transfer_done) tran_done_addr_q <= rd_addr;

		if(in_awshake & ~tran_done_q) begin
			spec_count <= spec_count + 1 ;
		end
		if(tran_done_q & ~in_awshake) begin
			spec_count <= spec_count - 1 ;
		end
	end
end




// synthesis translate_off

// 1. Count Bounds: spec_count never exceeds max slots.
as1_count_bounds: assert property (@(posedge clk) disable iff (!rst_n)
	spec_count <= SPEC_SLOT_AMOUNT)
	else $fatal("Violation: spec_count (%0d) > SPEC_SLOT_AMOUNT", spec_count);

// 2. Index Bounds: while a release transfer is in progress (~tran_ready),
//    the slot being read (rd_curr) must hold a valid in-range index.
//    Re-anchored from m_data.wvalid (now pipelined two stages downstream)
//    to the internal control signal that gates the read.
as2_rd_bounds: assert property (@(posedge clk) disable iff (!rst_n)
	(~tran_ready) |-> (spec_mem[rd_curr].index < spec_count))
	else $fatal("Violation: rd_curr slot index (%0d) >= spec_count (%0d)", spec_mem[rd_curr].index, spec_count);

// 3. Full Protection: do not accept a new burst when memory is full.
as3_full_prot: assert property (@(posedge clk) disable iff (!rst_n)
	(spec_count == SPEC_SLOT_AMOUNT) |-> !s_add.awready)
	else $fatal("Violation: s_add.awready is High while memory is Full");

// 4. Empty Protection: cannot start a new release transfer when memory is empty.
//    Re-anchored from m_data.wvalid (now downstream of the read pipeline + skid)
//    to the actual start-of-transfer condition.
as4_empty_prot: assert property (@(posedge clk) disable iff (!rst_n)
	(spec_count == '0) |-> !(tran_valid & tran_ready))
	else $fatal("Violation: new transfer launched while memory is Empty");

// 5. Double Index: no two slots share the same index.
always @(posedge clk) begin
	if (rst_n) begin
		for (int i = 0; i < SPEC_SLOT_AMOUNT; i++) begin
			for (int j = i + 1; j < SPEC_SLOT_AMOUNT; j++) begin
				as5_doule_idx: assert (spec_mem[i].index !== spec_mem[j].index)
					else $fatal("Duplicate index collision: Slot %0d and Slot %0d", i, j);
			end
		end
	end
end

// 6. Data Validity: a slot can only be read after its write side is complete.
//    Re-anchored to ~tran_ready (matches the read-enable lifetime); the old
//    check at m_data.wvalid no longer aligns now that reads are pipelined.
as6_read_done: assert property (@(posedge clk) disable iff (!rst_n)
	(~tran_ready) |-> spec_mem[rd_curr].done)
	else $fatal("Violation: rd_curr slot %0d marked not 'done'", rd_curr);

// 7. Write ID Matching: incoming write must match the target slot's ID.
//    Checked at the skid output (the point where the SRAM write actually fires).
as7_id_match: assert property (@(posedge clk) disable iff (!rst_n)
	(wr_skid_valid & wr_skid_ready) |-> (spec_mem[wr_axi_buf.wr_idx].awid == wr_axi_buf.wid))
	else $fatal("Violation: wr_axi_buf.wid (%h) does not match target slot ID (%h)", wr_axi_buf.wid, spec_mem[wr_axi_buf.wr_idx].awid);

// 8. Write After Done: cannot write to a slot already marked 'done'.
as8_no_wr_done: assert property (@(posedge clk) disable iff (!rst_n)
	(wr_skid_valid & wr_skid_ready) |-> !spec_mem[wr_axi_buf.wr_idx].done)
	else $fatal("Violation: Writing data to slot %0d already marked 'done'", wr_axi_buf.wr_idx);

// 9. wlast Accuracy: the latched wlast at the SRAM-read stage must correspond
//    to the awlen of the slot being read. The address bus rd_stg1_addr_q is
//    {slot_idx, transfer_offset}; when wlast is set, the offset must equal awlen.
as9_wlast_acc: assert property (@(posedge clk) disable iff (!rst_n)
	(rd_stg1_en_q & rd_stg1_wlast_q) |->
		(rd_stg1_addr_q[PLENGTH_WIDTH-1:0]
			== spec_mem[rd_stg1_addr_q[INDEX_WIDTH+PLENGTH_WIDTH-1:PLENGTH_WIDTH]].awlen))
	else $fatal("Violation: rd_stg1_wlast_q asserted but offset (%0d) != slot awlen (%0d)",
		rd_stg1_addr_q[PLENGTH_WIDTH-1:0],
		spec_mem[rd_stg1_addr_q[INDEX_WIDTH+PLENGTH_WIDTH-1:PLENGTH_WIDTH]].awlen);

// 10. One-Hot Integrity: one_hot_slot_zero must be one-hot (or all-zero).
as10_one_hot: assert property (@(posedge clk) disable iff (!rst_n)
	$onehot0(one_hot_slot_zero))
	else $fatal("Violation: one_hot_slot_zero is not One-Hot (Value: %b)", one_hot_slot_zero);

// 11. Release Validity (input contract from process_mem): spec_release should
//     only pulse when there is something to release. Kept as 'assume' — this
//     is an input constraint, not a DUT property.
//as11_valid_release: assume property (@(posedge clk) disable iff (!rst_n)
//	spec_release |-> (spec_count > 0))
//	else $fatal("Violation: spec_release asserted while memory is empty");

// 12. Skid/pipe no-data-loss: if the write skid presents a beat downstream
//     and the consumer is not ready, the same beat must persist next cycle.
as13_wr_skid_stable: assert property (@(posedge clk) disable iff (!rst_n)
	(wr_skid_valid & ~wr_skid_ready) |=> (wr_skid_valid && $stable(wr_axi_buf)))
	else $fatal("Violation: write skid lost or mutated a stalled beat");

// 14. EU FSM liveness: an armed address must get accepted (never hang in ARMED).
as14_eu_progress: assert property (@(posedge clk) disable iff (!rst_n)
	(eu_state == EU_ARMED) |-> ##[1:$] (eu_state == EU_IDLE))
	else $fatal("EU FSM stuck in EU_ARMED: m_add never accepted");

// 15. Address issue: every armed release eventually issues its m_add beat.
//     Catches address/data desync (released data with no matching address beat).
as15_addr_issued: assert property (@(posedge clk) disable iff (!rst_n)
	load_release |-> ##[1:$] (m_add.awvalid & m_add.awready))
	else $fatal("Released transaction never issued its address on m_add");

// 16. sent_transfer never overruns the current burst length while transferring.
as16_sent_bound: assert property (@(posedge clk) disable iff (!rst_n)
	(~tran_ready) |-> (sent_transfer <= spec_mem[rd_curr].awlen))
	else $fatal("sent_transfer (%0d) overran awlen (%0d) of slot %0d", sent_transfer, spec_mem[rd_curr].awlen, rd_curr);

//==============================================================================
// X-DETECTION BATTERY -- localizes the OEB2/rd_en-unknown cascade.
// These fire on the FIRST X seen on each control net, so the earliest-firing
// assert points at the root. (rd_en = rd_stg1_en_q; OEB2 = ~rd_en in dpbank.)
//==============================================================================

// 17. Read-port enable feeding the SRAM (drives OEB2) must never be X.
as17_rden_x: assert property (@(posedge clk) disable iff (!rst_n)
	!$isunknown(rd_stg1_en_q))
	else $fatal("rd_stg1_en_q (SRAM rd_en / OEB2) is X");

// 18. Read address must be defined whenever a read is issued.
as18_rdaddr_x: assert property (@(posedge clk) disable iff (!rst_n)
	rd_stg1_en_q |-> !$isunknown(rd_stg1_addr_q))
	else $fatal("rd_stg1_addr_q is X while rd_en asserted");

// 19. Core read-select control plane must never be X (upstream of rd_en).
as19_sel_x: assert property (@(posedge clk) disable iff (!rst_n)
	!$isunknown({tran_ready, tran_done_q, found_unluck, prefetch_now, rd_next, rd_curr, rd_addr}))
	else $fatal("read-select control net is X (tr=%b td=%b fu=%b pf=%b)", tran_ready, tran_done_q, found_unluck, prefetch_now);

// 20. Priority-coder input must be clean -- the most likely X seed, since
//     effective_index[] is used as a bit-select index to build it.
as20_pcoder_x: assert property (@(posedge clk) disable iff (!rst_n)
	!$isunknown(prior_coder_in))
	else $fatal("prior_coder_in is X (value %b) -> DW_pricod will emit X -> found_unluck X", prior_coder_in);

// 21. Counters must be clean (spec_count-1 underflow / spec_occ).
as21_count_x: assert property (@(posedge clk) disable iff (!rst_n)
	!$isunknown({spec_count, spec_occ, d_cur_id}))
	else $fatal("count/id net is X (spec_count=%b eff=%b d_cur_id=%b)", spec_count, spec_occ, d_cur_id);

// 22. effective_index[] entries must be clean -- each is used as an index, so an
//     X here silently corrupts spec_mem_unluck / prior_coder_in.
always @(posedge clk) begin
	if (rst_n) begin
		for (int k = 0; k < SPEC_SLOT_AMOUNT; k++) begin
			as22_effidx_x: assert (!$isunknown(effective_index[k]))
				else $fatal("effective_index[%0d] is X", k);
		end
	end
end

//==============================================================================
// FUNCTIONAL GUARDS -- catch a desync even if it does not manifest as X.
//==============================================================================

// 23. spec_occ stays in [0 .. SPEC_SLOT_AMOUNT] (no underflow wrap).
as23_eff_bound: assert property (@(posedge clk) disable iff (!rst_n)
	(spec_occ <= SPEC_SLOT_AMOUNT))
	else $fatal("spec_occ (%0d) out of range -> spec_count-1 underflow?", spec_occ);

// 24. A read is only issued against a slot whose write side is complete.
as24_rd_done: assert property (@(posedge clk) disable iff (!rst_n)
	rd_stg1_en_q |-> spec_mem[rd_stg1_addr_q[INDEX_WIDTH+PLENGTH_WIDTH-1:PLENGTH_WIDTH]].done)
	else $fatal("read issued to slot %0d which is not done",
		rd_stg1_addr_q[INDEX_WIDTH+PLENGTH_WIDTH-1:PLENGTH_WIDTH]);

// 25. While releasing an unlucky train, the released id must equal d_cur_id.
as25_train_id: assert property (@(posedge clk) disable iff (!rst_n)
	(found_unluck & tran_ready) |-> (spec_mem[rd_next].awid == d_cur_id))
	else $fatal("unlucky-train release slot %0d id (%0h) != d_cur_id (%0h)", rd_next, spec_mem[rd_next].awid, d_cur_id);

//==============================================================================
// DEADLOCK WATCHDOG + RELEASE-PATH TRACE  (debug instrumentation)
// No-X, no assert -> pure liveness hang. This dumps WHY the release side is
// stuck and traces every insert / release-start / release-done event.
//==============================================================================

// "progress" = any forward motion on any channel; "pending" = work outstanding.
wire dbg_progress = in_awshake | transfer_done | release_ready
                  | (m_add.awvalid  & m_add.awready)
                  | (m_data.wvalid  & m_data.wready)
                  | (s_data.wvalid  & s_data.wready);
wire dbg_pending  = (spec_occ > 0) | ~tran_ready | spec_release;

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
		$display("  spec_count=%0d  eff_count=%0d  mem_full=%b", spec_count, spec_occ, mem_full);
		$display("  INPUTS : spec_release=%b to_block=%b proc_full=%b proc_empty=%b", spec_release, to_block, proc_full, proc_empty);
		$display("  RELEASE: tran_valid=%b tran_ready=%b release_ready=%b found_unluck=%b zeros=%b", tran_valid, tran_ready, release_ready, found_unluck, zeros);
		$display("           first_done=%b first_unluck=%b unluck=%b spec2router=%b", first_done, first_unluck, unluck, spec2router);
		$display("  READ   : rd_curr=%0d rd_next=%0d rd_addr=%0d sent_transfer=%0d tran_done_q=%b td_addr=%0d", rd_curr, rd_next, rd_addr, sent_transfer, tran_done_q, tran_done_addr_q);
		$display("  PIPES  : rd_pipe_up_ready=%b rd_skid_valid=%b rd_skid_ready=%b m_data(v=%b r=%b)", rd_pipe_up_ready, rd_skid_valid, rd_skid_ready, m_data.wvalid, m_data.wready);
		$display("  ADDR   : eu_state=%0d load_release=%b m_add(v=%b r=%b) m_add_vld_q=%b d_cur_id=%0d", int'(eu_state), load_release, m_add.awvalid, m_add.awready, m_add_vld_q, d_cur_id);
		$display("  CODER  : spec_mem_unluck=%b prior_coder_in=%b prior_coder_out=%b", spec_mem_unluck, prior_coder_in, prior_coder_out);
		for (int k = 0; k < SPEC_SLOT_AMOUNT; k++)
			$display("    slot[%0d] idx=%0d eff=%0d awid=%0d done=%b unluck=%b awlen=%0d cur_len=%0d awuser=%b",
				k, spec_mem[k].index, effective_index[k], spec_mem[k].awid, spec_mem[k].done,
				spec_mem[k].unluck, spec_mem[k].awlen, spec_mem[k].cur_len, spec_mem[k].awuser);
		$display("==========================================================================");
		$fatal("[SPECMEM] deadlock watchdog tripped @%0t", $time);
	end
end

// Event trace: insert / release-start / release-complete.
always @(posedge clk) begin
	if (rst_n) begin
		if (in_awshake)
			$display("[SPECMEM @%0t] INSERT  awid=%0d awuser=%b awlen=%0d unluck=%b -> spec_count(next)=%0d",
				$time, s_add.awid, s_add.awuser, s_add.awlen, unluck, spec_count + 1);
		if (tran_valid & tran_ready)
			$display("[SPECMEM @%0t] REL-START slot=%0d awid=%0d kind=%s eff_count=%0d",
				$time, rd_next, spec_mem[rd_next].awid, (found_unluck ? "UNLUCKY" : "SPECIAL"), spec_occ);
		if (transfer_done)
			$display("[SPECMEM @%0t] REL-DONE  slot=%0d awid=%0d", $time, rd_curr, spec_mem[rd_curr].awid);
	end
end

// synthesis translate_on

endmodule
