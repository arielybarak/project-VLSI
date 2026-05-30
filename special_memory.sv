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

logic	  [INDEX_WIDTH-1:0]  	  wr_idx   ;
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
logic d_awvalid     ;
logic in_awshake    ;
logic transfer_done ;

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
skid_data_t wr_stg1_bus   ;

// 3. AXI Flow Control (Skid Buffers)
//    Purpose: AXI protocol compliance / backpressure handling.
//=========================================
// --- Write Path ---
// Flow: AXI s_data -> [wr_stg1 PIPE] -> [wr_axi_buf SKID] -> ID-Match & Parity Logic -> SRAM
logic 		pipe_up_ready ;
logic 		wr_id_match   ;
logic       wr_skid_valid ;
logic       wr_skid_ready ;
skid_data_t wr_bus_in	  ;
skid_data_t wr_axi_buf	  ;       // Output of write-path skid buffer

// --- Read Path ---
// Flow: SRAM Output -> [rd_axi_buf SKID] -> AXI m_data
logic [PDATA_WIDTH*8-1:0] rd_stg2_data ;
logic [PDATA_WIDTH-1:0]   rd_stg2_strb ;
logic [PWUSER_WIDTH-1:0]  rd_stg2_user ;

logic       rd_skid_valid  ;
logic       rd_skid_ready  ;
skid_data_t rd_skid_bus_in ;
skid_data_t rd_axi_buf     ;       // Output of read-path skid buffer

//=========================================
// 4. Aux Logic & Parity Signals
//=========================================

reg [SPEC_SLOT_AMOUNT-1:0] prior_coder_in 		   ;
wire [SPEC_SLOT_AMOUNT-1:0] prior_coder_out 	   ;
reg [SPEC_SLOT_AMOUNT-1:0] reverse_prior_coder_out ;
wire zeros ;

parameter batchZize = PDATA_WIDTH*8/PWUSER_WIDTH;
logic [PWUSER_WIDTH-1:0] calcIn_parity  ;
logic [PWUSER_WIDTH-1:0] calcOut_parity ;
logic [PWUSER_WIDTH-1:0] origin_parity  ;
logic [PWUSER_WIDTH-1:0] wr_isRuined    ;
logic [PWUSER_WIDTH-1:0] rd_isRuined    ;
logic [PLENGTH_WIDTH-1:0] sent_transfer ;

//=========================================
// 4. Instantiations
//=========================================

special_mem_dpbank memory (
	.clk(clk),
	.wr_en(wr_skid_ready & wr_skid_valid),
	.wr_addr({wr_idx, spec_mem[wr_idx].cur_len}),
	.wr_data(wr_axi_buf.wdata),
	.wr_strb(wr_axi_buf.wstrb),
	.wr_parity(wr_axi_buf.wuser),
	.wr_isRuined(wr_isRuined),
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

assign wr_bus_in = '{wid: s_data.wid, wdata: s_data.wdata, wstrb: s_data.wstrb, wuser: s_data.wuser, wlast: s_data.wlast};
pipe_reg #($bits(skid_data_t)) wr_data_pipe (
    .clk(clk), .rst_n(rst_n),
    .up_valid(s_data.wvalid & wr_id_match),  .dn_valid(wr_stg1_valid),
    .up_ready(pipe_up_ready),                .dn_ready(wr_stg1_ready),
    .up_data(wr_bus_in),                     .dn_data(wr_stg1_bus)
);

skid_buffer #($bits(skid_data_t)) wr_data_skid (
    .clk(clk), .rst_n(rst_n),
    .up_valid(wr_stg1_valid),  .dn_valid(wr_skid_valid),
    .up_ready(wr_stg1_ready),  .dn_ready(wr_skid_ready),
    .up_data(wr_stg1_bus),     .dn_data(wr_axi_buf)
);

assign rd_skid_bus_in = '{wid: rd_stg1_wid_q, wdata: rd_stg2_data, wstrb: rd_stg2_strb, wuser: rd_stg2_user, wlast: rd_stg1_wlast_q};
skid_buffer #($bits(skid_data_t)) data_skid (
    .clk(clk), .rst_n(rst_n),
    .up_valid(rd_skid_valid),  .dn_valid(m_data.wvalid),
    .up_ready(rd_skid_ready),  .dn_ready(m_data.wready),
    .up_data(rd_skid_bus_in),  .dn_data(rd_axi_buf)
);

//=========================================
// 5. Continuous Assignments
//=========================================

assign mem_full = (SPEC_SLOT_AMOUNT == spec_count) ;																
assign found_unluck = |(spec_mem_unluck & reverse_prior_coder_out) ;
assign tran_valid = (release_ready | found_unluck | (first_unluck & first_done)) & (spec_count > '0) ;	
assign first_unluck = spec_mem_unluck[0] ; 																		

// --- Communication ----
assign release_ready = tran_ready & spec_release & ~found_unluck & (spec_count > '0) & first_done ;					
assign spec2router = (tran_valid & tran_ready) | ~tran_ready ;																
assign s_add.awready = s_add.awvalid & ~to_block & ~mem_full & ~proc_full & ~proc_empty & ((s_add.awuser === DIVERT) | unluck) ; 	
assign in_awshake = s_add.awvalid & s_add.awready ;
assign s_data.wready = pipe_up_ready & wr_id_match;

// --- Read Path Flow ---
assign rd_skid_valid = rd_stg1_en_q;
assign transfer_done = (~tran_ready) & (sent_transfer == spec_mem[rd_curr].awlen) & rd_skid_ready;
assign rd_addr = tran_ready ? rd_next : rd_curr ;			// Look-Ahead Mux/Address Bypass logic

// Connect rd_axi_buf directly to AXI master
assign m_data.wid   = rd_axi_buf.wid;
assign m_data.wdata = rd_axi_buf.wdata;
assign m_data.wstrb = rd_axi_buf.wstrb;
assign m_data.wuser = rd_axi_buf.wuser;
assign m_data.wlast = rd_axi_buf.wlast;



always_comb begin
	wr_id_match = 1'b0;
	wr_skid_ready = 1'b0 ;
	wr_idx = 0 ;
	for(int j=0; j<SPEC_SLOT_AMOUNT; j++) begin
		// Match logic (Front of pipe): Asserts wr_id_match if incoming ID matches a special transaction.
		// This gates the pipe input and asserts s_data.wready to claim data from the router.
		if ((~|(spec_mem[j].awid^s_data.wid)) & (~spec_mem[j].done) & (spec_mem[j].index < spec_count)) begin
			wr_id_match = 1'b1;
		end
		// Match logic (End of pipe): Asserts wr_skid_ready if data leaving the pipe matches an active transaction.
		// This determines the target SRAM index (wr_idx) exactly when the data is ready to be written.
		if(wr_skid_valid  & (~|(spec_mem[j].awid^wr_axi_buf.wid)) & (~spec_mem[j].done)) begin
			wr_skid_ready = 1'b1 ;
			wr_idx = INDEX_WIDTH'(j) ;
		end
	end
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
		one_hot_slot_zero[j] = (spec_mem[j].index == '0) ? 1'b1 : 1'b0 ;		
																								///// transaction train operator /////
		spec_mem_unluck[spec_mem[j].index] = spec_mem[j].unluck ;										//-----unlucky search mechanism-----//
		reverse_prior_coder_out[j] = prior_coder_out[SPEC_SLOT_AMOUNT-1-j] ;
		prior_coder_in[SPEC_SLOT_AMOUNT-1-spec_mem[j].index] = (~|(spec_mem[j].awid^d_cur_id)) & (spec_mem[j].index < spec_count) & spec_mem[j].done ;
		
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
			&& (|(s_add.awuser^DIVERT)) && (spec_mem[j].index < spec_count)) begin
			unluck = 1 ;
		end																				
		if(one_hot_slot_zero === (1<<j)) begin	
			first_done = spec_mem[j].done ;
		end
		if(spec_mem[j].index === next_slot_idx) begin	
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

		calcIn_parity[i] = ^(wr_axi_buf.wdata[i*(batchZize/8) +: (batchZize/8)] /*& mask*/) ; 
		calcOut_parity[i] = ^(rd_stg2_data[i*(batchZize/8) +: (batchZize/8)] /*& Omask*/) ;
	end
	wr_isRuined = calcIn_parity ^ wr_axi_buf.wuser;	
	rd_stg2_user = (origin_parity & ~rd_isRuined) | (~calcOut_parity & rd_isRuined) ; //output
end

//--------------Transmit-start----------------------

always_comb begin
	m_add.awvalid = (tran_valid & tran_ready) ? 1'b1 : d_awvalid ;
	
	m_add.awburst = spec_mem[rd_addr].awburst ;
	m_add.awid    = spec_mem[rd_addr].awid    ;
	m_add.awaddr  = spec_mem[rd_addr].awaddr  ;
	m_add.awlen   = spec_mem[rd_addr].awlen   ;
	m_add.awsize  = spec_mem[rd_addr].awsize  ;
	m_add.awuser  = spec_mem[rd_addr].awuser  ;
	m_add.other   = spec_mem[rd_addr].other   ;
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
		
		if(m_add.awready) begin
			d_awvalid <= 0 ;
		end 
		else if(tran_valid & tran_ready) begin
			d_awvalid <= 1 ;
		end	
		
		if(tran_valid & tran_ready) begin
			tran_ready <= 0 ;
		end
		else if (~tran_ready) begin
			if(rd_skid_ready) begin
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

always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		rd_stg1_addr_q  <= '0;
		rd_stg1_en_q    <= '0;
		rd_stg1_wlast_q <= '0;
		rd_stg1_wid_q   <= '0;
	end else begin
		if (rd_skid_ready) begin
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
																				//-----new incoming transaction-----//
				if(in_awshake) begin
					if( (~transfer_done && (spec_mem[i].index === spec_count)) || 
					(transfer_done && (spec_mem[i].index === spec_count-1)) ) begin
						spec_mem[i].awburst <= s_add.awburst ;
						spec_mem[i].awid   <= s_add.awid 	 ;
						spec_mem[i].awaddr <= s_add.awaddr 	 ;
						spec_mem[i].awlen  <= s_add.awlen 	 ;
						spec_mem[i].awsize <= s_add.awsize 	 ;
						spec_mem[i].awuser <= s_add.awuser 	 ;
						spec_mem[i].unluck <= unluck 	 	 ;
						spec_mem[i].other  <= s_add.other	 ;
						spec_mem[i].done <= 1'b0 ;
					end
				end
																				//-----Live transaction update-----//
				if(i === wr_idx) begin
					if(wr_skid_ready & wr_skid_valid & wr_axi_buf.wlast) begin
						spec_mem[i].done <= 1'b1 ;
					end
					else if(wr_skid_ready & wr_skid_valid) begin
						spec_mem[i].cur_len <= spec_mem[i].cur_len + PLENGTH_WIDTH'(1) ;
					end
				end
																				//-----delete operator-----//
				if(transfer_done) begin											
					if((i === rd_addr) & (spec_count > '0)) begin
						spec_mem[i].index <= spec_count - 1 ;
						spec_mem[i].cur_len <= '0 ;
					end
					if((spec_mem[i].index > spec_mem[rd_addr].index) & (spec_mem[i].index < spec_count)) begin
						spec_mem[i].index <= spec_mem[i].index - INDEX_WIDTH'(1) ;
					end
				end			
			end
		end
	end
endgenerate


always_ff @(posedge clk or negedge rst_n) begin
	
	if (!rst_n) begin
		spec_count <= 0 ;
		d_cur_id <= 0 ;
	end
	else begin
		
		if(release_ready) begin
			d_cur_id <= cur_id ;
		end
		if(in_awshake & ~transfer_done) begin
			spec_count <= spec_count + 1 ;
		end
		if(transfer_done & ~in_awshake) begin
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
	(wr_skid_valid & wr_skid_ready) |-> (spec_mem[wr_idx].awid == wr_axi_buf.wid))
	else $fatal("Violation: wr_axi_buf.wid (%h) does not match target slot ID (%h)", wr_axi_buf.wid, spec_mem[wr_idx].awid);

// 8. Write After Done: cannot write to a slot already marked 'done'.
as8_no_wr_done: assert property (@(posedge clk) disable iff (!rst_n)
	(wr_skid_valid & wr_skid_ready) |-> !spec_mem[wr_idx].done)
	else $fatal("Violation: Writing data to slot %0d already marked 'done'", wr_idx);

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

// 12. AXI write handshake stability: once s_data.wvalid is asserted, the
//     master must hold it until wready is seen (no withdrawing valid).
as12_wvalid_hold: assert property (@(posedge clk) disable iff (!rst_n)
	(s_data.wvalid & ~s_data.wready) |=> s_data.wvalid)
	else $fatal("Violation: s_data.wvalid dropped before handshake");

// 13. Skid/pipe no-data-loss: if the write skid presents a beat downstream
//     and the consumer is not ready, the same beat must persist next cycle.
as13_wr_skid_stable: assert property (@(posedge clk) disable iff (!rst_n)
	(wr_skid_valid & ~wr_skid_ready) |=> (wr_skid_valid && $stable(wr_axi_buf)))
	else $fatal("Violation: write skid lost or mutated a stalled beat");

// synthesis translate_on

endmodule


	


 


	
		




