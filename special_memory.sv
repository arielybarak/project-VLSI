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
spec_slot [SPEC_SLOT_AMOUNT-1:0]  spec_mem 		    ;
logic  	  [SPEC_SLOT_AMOUNT-1:0]  spec_mem_unluck   ;
logic	  [SPEC_SLOT_AMOUNT-1:0]  one_hot_slot_zero ;
reg	  	  [INDEX_WIDTH:0] 	  spec_count 		;

logic	  [INDEX_WIDTH-1:0]  	  wr_slot_idx   ;
logic  	  [INDEX_WIDTH-1:0]		  rd_slot_next  ;
logic  	  [INDEX_WIDTH-1:0]		  rd_slot_curr  ; 
logic  	  [INDEX_WIDTH-1:0]		  rd_slot_addr  ; 
logic  	  [INDEX_WIDTH-1:0]		  next_slot_idx ;
logic 	  [PID_WIDTH-1:0] 		  cur_id 		;
reg 	  [PID_WIDTH-1:0] 		  d_cur_id 		;

reg	mem_full 	   ;
wire  found_unluck ;
logic tran_valid   ;
logic tran_ready   ;
logic first_done   ;
logic first_unluck ;
logic d_awvalid    ;
logic in_awshake   ;
logic transfer_done;

reg [SPEC_SLOT_AMOUNT-1:0] prior_coder_in 		   ;
wire [SPEC_SLOT_AMOUNT-1:0] prior_coder_out 	   ;
reg [SPEC_SLOT_AMOUNT-1:0] reverse_prior_coder_out ;
wire zeros ;

//----Parity----
parameter batchZize = PDATA_WIDTH*8/PWUSER_WIDTH;
logic [PWUSER_WIDTH-1:0] calcIn_parity  ;
logic [PWUSER_WIDTH-1:0] calcOut_parity ;
logic [PWUSER_WIDTH-1:0] origin_parity  ;
logic [PWUSER_WIDTH-1:0] wr_isRuined    ;
logic [PWUSER_WIDTH-1:0] rd_isRuined    ;
logic [PLENGTH_WIDTH-1:0] sent_transfer ;

special_mem_dpbank memory (
	.clk(clk),
	.wr_en(s_data.wready),
	.wr_addr({wr_slot_idx, spec_mem[wr_slot_idx].cur_len}),
	.wr_data(s_data.wdata),
	.wr_strb(s_data.wstrb),
	.wr_parity(s_data.wuser),
	.wr_isRuined(wr_isRuined),
	.rd_en(~tran_ready),
	.rd_addr({rd_slot_addr, sent_transfer}),
	.rd_data(m_data.wdata),
	.rd_strb(m_data.wstrb),
	.rd_parity(origin_parity),
	.rd_isRuined(rd_isRuined)
);

DW_pricod #(SPEC_SLOT_AMOUNT) priority_decoder (
	.a   (prior_coder_in ),
	.cod (prior_coder_out),
	.zero(zeros          )
);
																							
assign mem_full = (SPEC_SLOT_AMOUNT == spec_count) ;																
assign found_unluck = |(spec_mem_unluck & reverse_prior_coder_out) ;
assign tran_valid = (release_ready | found_unluck | (first_unluck & first_done)) & (spec_count > '0) ;	
assign first_unluck = spec_mem_unluck[0] ; 																		
//--------communication----
assign release_ready = tran_ready & spec_release & ~found_unluck & (spec_count > '0) & first_done ;					
assign spec2router = (tran_valid & tran_ready) | ~tran_ready ;																
assign s_add.awready = s_add.awvalid & ~to_block & ~mem_full & ~proc_full & ~proc_empty & ((s_add.awuser === DIVERT) | unluck) ; 	
assign in_awshake = s_add.awvalid & s_add.awready ;
//---------Project B-------
assign m_data.wvalid = ~tran_ready ; 
assign transfer_done = m_data.wvalid & m_data.wready & m_data.wlast ;
assign rd_slot_addr = tran_ready ? rd_slot_next : rd_slot_curr ;			// Look-Ahead Mux/Address Bypass logic


always_comb begin
	first_done = 1'b0 ;														
	s_data.wready = 1'b0 ;
	unluck = 1'b0 ;
	cur_id = '0 ;
	wr_slot_idx = 0 ;
	spec_mem_unluck = '0 ;	
	prior_coder_in = '0 ;
	next_slot_idx = '0 ;
	rd_slot_next = '0 ;
	
	for(int j=0; j<SPEC_SLOT_AMOUNT; j++) begin : x1											
		one_hot_slot_zero[j] = (spec_mem[j].index == '0) ? 1'b1 : 1'b0 ;		
																									//-----Interleaving data channel-----//
		if(s_data.wvalid  & (~|(spec_mem[j].awid^s_data.wid)) & (~spec_mem[j].done)) begin
			s_data.wready = 1'b1 ;
			wr_slot_idx = INDEX_WIDTH'(j) ;
		end
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
			rd_slot_next = j ;
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

		calcIn_parity[i] = ^(s_data.wdata[i*(batchZize/8) +: (batchZize/8)] /*& mask*/) ; 
		calcOut_parity[i] = ^(m_data.wdata[i*(batchZize/8) +: (batchZize/8)] /*& Omask*/) ;
	end
	wr_isRuined = calcIn_parity ^ s_data.wuser;	
	m_data.wuser = (origin_parity & ~rd_isRuined) | (~calcOut_parity & rd_isRuined) ; //output
end

//--------------Transmit-start----------------------

always_comb begin
	m_add.awvalid = (tran_valid & tran_ready) ? 1'b1 : d_awvalid ;
	m_data.wlast = (sent_transfer == spec_mem[rd_slot_addr].awlen) ;								
	
	m_add.awburst = spec_mem[rd_slot_addr].awburst ;
	m_add.awid    = spec_mem[rd_slot_addr].awid    ;
	m_add.awaddr  = spec_mem[rd_slot_addr].awaddr  ;
	m_add.awlen   = spec_mem[rd_slot_addr].awlen   ;
	m_add.awsize  = spec_mem[rd_slot_addr].awsize  ;
	m_add.awuser  = spec_mem[rd_slot_addr].awuser  ;
	m_add.other   = spec_mem[rd_slot_addr].other   ;
	m_data.wid = spec_mem[rd_slot_addr].awid ;
end

always_ff @(posedge clk or negedge rst_n) begin
	if(~rst_n) begin
		tran_ready <= 1 ;
		sent_transfer <= 0 ;
		rd_slot_curr <= 0 ;
	end
	else begin
		if(tran_ready) begin
			rd_slot_curr <= rd_slot_next ;
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
		else if (~tran_ready || (tran_valid & tran_ready)) begin
			if(m_data.wready) begin
				sent_transfer <= sent_transfer + PLENGTH_WIDTH'(1) ;
			end
			if(m_data.wlast & m_data.wready) begin
				sent_transfer <= 0 ;
				tran_ready <= 1 ;
			end
		end
	end
end

//--------------sending-end---------------------

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
				if(i === wr_slot_idx) begin
					if(s_data.wready & s_data.wlast) begin
						spec_mem[i].done <= 1'b1 ;
					end
					else if(s_data.wready) begin
						spec_mem[i].cur_len <= spec_mem[i].cur_len + PLENGTH_WIDTH'(1) ;
					end
				end
																				//-----delete operator-----//
				if(transfer_done) begin											
					if((i === rd_slot_addr) & (spec_count > '0)) begin
						spec_mem[i].index <= spec_count - 1 ;
						spec_mem[i].cur_len <= '0 ;
					end
					if((spec_mem[i].index > spec_mem[rd_slot_addr].index) & (spec_mem[i].index < spec_count)) begin
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

// 1. Count Bounds: Count never exceeds max slots
as1_count_bounds: assert property (@(posedge clk) disable iff (!rst_n) 
	spec_count <= SPEC_SLOT_AMOUNT)
	else $fatal("Violation: spec_count (%0d) > SPEC_SLOT_AMOUNT", spec_count);

// 2. Index bounds: Reading from an empty slot
as2_rd_bounds: assert property (@(posedge clk) disable iff (!rst_n)
	(m_data.wvalid) |-> (spec_mem[rd_slot_curr].index < spec_count))
	else $fatal("Violation: Reading from slot with index >= spec_count");

// 3. Full Protection: Not ready if full
as3_full_prot: assert property (@(posedge clk) disable iff (!rst_n)
	(spec_count == SPEC_SLOT_AMOUNT) |-> !s_add.awready)
	else $fatal("Violation: s_add.awready is High while memory is Full");

// 4. Empty Protection: Not valid if empty
as4_empty_prot: assert property (@(posedge clk) disable iff (!rst_n)
	(spec_count == 0) |-> !m_data.wvalid)
	else $fatal("Violation: m_data.wvalid is High while memory is Empty");

// 5. Double index: Two slots with the same index
always @(posedge clk) begin
	if (rst_n) begin // Only check when not in reset
		for (int i = 0; i < SPEC_SLOT_AMOUNT; i++) begin
			for (int j = i + 1; j < SPEC_SLOT_AMOUNT; j++) begin
				as5_doule_idx: assert (spec_mem[i].index !== spec_mem[j].index)
					else $fatal("Duplicate index collision: Slot %0d and Slot %0d", i, j);
			end
		end
	end
end
// 6. Data Validity: Reading only fully written ('done') slots
as6_read_done: assert property (@(posedge clk) disable iff (!rst_n)
	(m_data.wvalid) |-> spec_mem[rd_slot_curr].done)
	else $fatal("Violation: Reading from a slot that is not marked 'done'");

// 7. ID Matching: Incoming Write ID must match the target slot's ID
as7_id_match: assert property (@(posedge clk) disable iff (!rst_n)
	(s_data.wvalid & s_data.wready) |-> (spec_mem[wr_slot_idx].awid == s_data.wid))
	else $fatal("Violation: s_data.wid (%h) does not match target slot ID (%h)", s_data.wid, spec_mem[wr_slot_idx].awid);

// 8. Write After Done: Cannot write to a slot marked 'done'
as8_no_wr_done: assert property (@(posedge clk) disable iff (!rst_n)
	(s_data.wvalid & s_data.wready) |-> !spec_mem[wr_slot_idx].done)
	else $fatal("Violation: Writing data to a slot already marked 'done'");

// 9. Last Signal Accuracy: wlast must match the internal length counter
as9_wlast_acc: assert property (@(posedge clk) disable iff (!rst_n)
	(m_data.wvalid & m_data.wready & m_data.wlast) |-> (sent_transfer == spec_mem[rd_slot_curr].awlen))
	else $fatal("Violation: wlast asserted but sent_transfer (%0d) != awlen (%0d)", sent_transfer, spec_mem[rd_slot_curr].awlen);

// 10. One-Hot Integrity: Ensure logic vector is One-Hot (or Zero)
as10_one_hot: assert property (@(posedge clk) disable iff (!rst_n)
	$onehot0(one_hot_slot_zero))
	else $fatal("Violation: one_hot_slot_zero is not One-Hot (Value: %b)", one_hot_slot_zero);

// 11. Double Release (Input Assumption): spec_release should not fire if empty
// Using 'assume' because this is an input constraint from the Process Memory
//as11_valid_release: assume property (@(posedge clk) disable iff (!rst_n)
//	spec_release |-> (spec_count > 0))
//	else $fatal("Violation: spec_release asserted while memory is empty");

// synthesis translate_on

endmodule


	


 


	
		




