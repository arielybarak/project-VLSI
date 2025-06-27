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
spec_slot [SPEC_SLOT_AMOUNT-1:0]  spec_mem 		  ;
logic  	  [SPEC_SLOT_AMOUNT-1:0]  spec_mem_unluck ;
logic	  [SPEC_SLOT_AMOUNT-1:0]  one_hot_slot_zero ;
reg	  	  [INDEX_WIDTH-1:0] 	  spec_count 	  ;
logic  	  [INDEX_WIDTH-1:0]		  cur_index    	  ;
logic  	  [SPEC_SLOT_AMOUNT-1:0][INDEX_WIDTH-1:0] cur_index_bus ; //TODO think about more efficient solution
logic 	  [PID_WIDTH-1:0] 		  cur_id 		  ;
reg 	  [PID_WIDTH-1:0] 		  d_cur_id 		  ;
logic		  [SPEC_SLOT_AMOUNT-1:0]  cur_data_i 	  ;

burst_slot complete_tran ;
reg	mem_full 	;
wire  found_unluck ;
logic tran_valid ;
wire  ready_fall ;
logic tran_ready ;
logic first_done ;
logic first_unluck ;
logic temp ;

reg [SPEC_SLOT_AMOUNT-1:0] prior_coder_in 			;
wire [SPEC_SLOT_AMOUNT-1:0] prior_coder_out 		;
reg [SPEC_SLOT_AMOUNT-1:0] reverse_prior_coder_out ;
wire zeros ;


DW_pricod #(SPEC_SLOT_AMOUNT) priority_decoder (
	.a   (prior_coder_in ),
	.cod (prior_coder_out),
	.zero(zeros               )
);

box_master send_burst (
	.clk       (clk          ),
	.rst_n     (rst_n        ),
	.tran_valid(tran_valid   ),
	.in_slot   (complete_tran),
	.tran_ready(tran_ready   ),
	.m_add     (m_add        ),
	.m_data    (m_data       )
);

																										
assign mem_full = (SPEC_SLOT_AMOUNT == spec_count) ;																
assign found_unluck = |(spec_mem_unluck & reverse_prior_coder_out) ;
assign ready_fall = temp & ~tran_ready ;
assign tran_valid = tran_ready & (release_ready | found_unluck | (first_unluck & first_done)) & (spec_count > 0) ;	
assign first_unluck = spec_mem_unluck[0] ; 									//5.25
assign cur_index = ^cur_index_bus ; 										//TODO think about more efficient solution
																								/* communication related */
assign release_ready = tran_ready & spec_release & ~found_unluck & (spec_count > 0) & first_done ;					
assign spec2router = (tran_valid & tran_ready) | ~tran_ready ;																
assign s_add.awready = s_add.awvalid & ~to_block & ~mem_full & ~proc_full & ~proc_empty & ((s_add.awuser === DIVERT) | unluck) ;

// synthesis translate_off
always_comb begin
  for (int i = 0; i < SPEC_SLOT_AMOUNT; i++) begin
	for (int j = i+1; j < SPEC_SLOT_AMOUNT; j++) begin
	  assert (!(spec_mem[i].index === spec_mem[j].index))
		else $fatal("Duplicate index found: spec_mem[%0d] and spec_mem[%0d] both have index %0d", i, j, spec_mem[i].index);
	end
  end
end
// synthesis translate_on

always_comb begin
	first_done = 1'b0 ;														//5.25
	s_data.wready = 1'b0 ;
	unluck = 1'b0 ;
	cur_id = '0 ;
	cur_data_i = 0 ;
	complete_tran = '{default: '0};
	spec_mem_unluck = '0 ;	//default outside of for loop because the assignment is not by j - but by spec_mem[j].index ('0' might overrun non '0' value)
	prior_coder_in = '0 ;
	
	for(int j=0; j<SPEC_SLOT_AMOUNT; j++) begin : xxxx
		cur_index_bus[j] = '0 ;												//5.25
		one_hot_slot_zero[j] = (spec_mem[j].index == 0) ? 1'b1 : 1'b0 ;		
																									/* Interleaving data channel */																		
		if(s_data.wvalid  & (~|(spec_mem[j].awid^s_data.wid)) & (~spec_mem[j].done)) begin
			s_data.wready = 1 ;
			cur_data_i = j ;
		end
																								///// transaction train operator /////
		spec_mem_unluck[spec_mem[j].index] = spec_mem[j].unluck ;										/* unlucky search mechanism */
		reverse_prior_coder_out[j] = prior_coder_out[SPEC_SLOT_AMOUNT-1-j] ;
		prior_coder_in[SPEC_SLOT_AMOUNT-1-spec_mem[j].index] = (~|(spec_mem[j].awid^d_cur_id)) & (spec_mem[j].index < spec_count) & spec_mem[j].done ;
		
		if(/*tran_ready &&*/ found_unluck && reverse_prior_coder_out[j])								/* dealing with unlucky */					
			cur_index_bus[j] = j ;
		
//		if(tran_ready) begin																		  	/* dealing with unlucky */
//			if(reverse_prior_coder_out[j] & spec_mem_unluck[j])
//				cur_index = j ;
//			else cur_index = 0 ;
//		end
//		else cur_index = 0 ; //5.25
		
		if(found_unluck) begin
			if(tran_ready && (spec_mem[j].index === cur_index))											/* Unlucky release */
				complete_tran = spec_mem[j] ;
		end 
		else if((one_hot_slot_zero === (1<<j)) && ((first_unluck & first_done) || release_ready)) begin	/* Special release */
			complete_tran = spec_mem[j] ;
			cur_id = spec_mem[j].awid ;
		end
//		else if(~((first_unluck & first_done) | release_ready)) begin
//			cur_id = 0 ;
//			complete_tran = 0 ;
//		end

																									  /* new burst: luck check */
		if(s_add.awvalid && (spec_mem[j].awid === s_add.awid) && (|(s_add.awuser^DIVERT)) && (spec_mem[j].index < spec_count)) 
			unluck = 1 ;
//		else if(~s_add.awvalid) 
//			unluck = 0 ;																				
		
																										
		if(one_hot_slot_zero === (1<<j))		
			first_done = spec_mem[j].done ;
//			first_unluck = spec_mem[j].unluck;
		
	end
end


genvar i;
generate
	
	for (i = 0; i < SPEC_SLOT_AMOUNT; i++) begin	: For_Spec_Mem
		always_ff @(posedge clk or negedge rst_n) begin
			
			if(!rst_n) begin
				spec_mem[i].index <= i   ;
				spec_mem[i].awburst <= 0 ;
				spec_mem[i].awid <= 0    ;
				spec_mem[i].awaddr <= 0  ;
				spec_mem[i].awlen <= 0   ;
				spec_mem[i].awsize <= 0  ;
				spec_mem[i].awuser <= 0  ;
				spec_mem[i].unluck <= 0  ;
				spec_mem[i].other <= 0   ;
				spec_mem[i].done <= 1    ;
				spec_mem[i].cur_len <= 0 ;
				
				for(int j = 0; j<PCOMPLETE_DATA; j++) begin
					spec_mem[i].data[j] <= 8'h0 ;
					spec_mem[i].strb[j] <= 1'b0 ;
				end
			end
			else begin
																							/////new incoming transaction////
				if(s_add.awvalid & s_add.awready) begin
					if((~ready_fall & (spec_mem[i].index === spec_count)) /*|| (ready_fall & (spec_mem[i].index === spec_count-1))*/ /*&& ~ready_fall 25.5 */) begin
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
				
				if(s_data.wready & (i == cur_data_i)) begin
					spec_mem[i].data[spec_mem[i].cur_len*PDATA_WIDTH +: PDATA_WIDTH] <= s_data.wdata ;
					spec_mem[i].strb[spec_mem[i].cur_len*PDATA_WIDTH +: PDATA_WIDTH] <= s_data.wstrb ;
				end
				
				if(ready_fall & (spec_mem[i].index === cur_index) & (spec_count > 0))
					spec_mem[i].cur_len <= 0 ;
																								/////Live transaction update/////
				else if(i === cur_data_i) begin
					if(s_data.wready & s_data.wlast)
						spec_mem[i].done <= 1'b1 ;
					else if(s_data.wready)
						spec_mem[i].cur_len <= spec_mem[cur_data_i].cur_len + 1 ;
				end
				
				
				if(ready_fall) begin																/////delete operator/////
					if((spec_mem[i].index === cur_index) & (spec_count > 0)) begin
						spec_mem[i].index <= spec_count-1 ;
						
					end
					
					if((spec_mem[i].index > cur_index) & (spec_mem[i].index < spec_count))
						spec_mem[i].index <= spec_mem[i].index-1 ;
				end
				
			end
		end
	end
endgenerate



always_ff @(posedge clk or negedge rst_n) begin
	
	if (!rst_n) begin
		spec_count <= 0 ;
		d_cur_id <= 0 ;
		temp <= 0;
	end
	else begin
		
		if(tran_ready)
			temp <= 1;
		else if(~tran_ready)
			temp <= 0 ;
		
		if(release_ready)
			d_cur_id <= cur_id ;
		
		if(s_add.awvalid & s_add.awready & ~ready_fall)
			spec_count <= spec_count + 1 ;
		
		if(ready_fall)
			spec_count <= spec_count - 1 ;
	end
end

endmodule


	


 


	
		




