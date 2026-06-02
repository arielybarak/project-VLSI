/*------------------------------------------------------------------------------
 * File          : process_mem.sv
 * Project       : RTL
 * Author        : epabab
 * Creation date : Jul 20, 2024
 * Description   : Upgraded linked list type memory, document every transaction (regular and special).
 * Main functions: Add new transaction to the database, Delete chosen transaction from the database, remain all the slots aligned (without spaces).  
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

slot 	[SLOT_AMOUNT-1:0] memory ;
logic 	[$clog2(SLOT_AMOUNT):0] proc_count ;

/// Inner logic ///
logic new_tran   ; 
logic bshake ;
logic d_spec_release ;
logic [$clog2(SLOT_AMOUNT)-1:0] cur_index_done ;

/////////// priority coder delete///////////////////////////
logic [SLOT_AMOUNT-1:0] priority_coder_in_d ;
logic [SLOT_AMOUNT-1:0] priority_coder_out_d ;
logic zeros_d;
logic [SLOT_AMOUNT-1:0] reverse_priority_coder_out_d ;



/////instances//// 
DW_pricod #(SLOT_AMOUNT) priority_coder_delete (
	.a   (priority_coder_in_d ),
	.cod (priority_coder_out_d),
	.zero(zeros_d             )
);


assign bshake = bvalid & bready ;
assign new_tran = awvalid & awready & ~full & ~to_block ;
assign block_fin = bshake && (~|(memory[cur_index_done].tran_type^BLOCK)) ;


always_comb begin
	block_data = 1 ;
	cur_index_done = 0 ;
	
	if ((~|(memory[1].tran_type^DIVERT)) && bshake && (proc_count > 1) && (cur_index_done === 0)) begin
		spec_release = 1 ;
	end
	else spec_release = d_spec_release ;
	
	for (int i = 0; i < SLOT_AMOUNT; i++) begin
		priority_coder_in_d[SLOT_AMOUNT-1-i] = (i < proc_count) & ~|(memory[i].id^bid) ;
		reverse_priority_coder_out_d[i] = priority_coder_out_d[SLOT_AMOUNT-1-i] ;
		
		if(bshake && reverse_priority_coder_out_d[i]) begin
			cur_index_done = i ;
		end
		if(wvalid && (i < proc_count) && ~|(memory[i].id^wid) && ~memory[i].done) begin//25.5
			block_data = 0 ;
		end
	end
end


always_ff @(posedge clk or negedge rst_n) begin
	
	if (!rst_n) begin
		for (int i = 0; i < SLOT_AMOUNT; i++) begin
			memory[i].id 		<= '0 ;
			memory[i].tran_type <= 2'b00 ;
			memory[i].done 		<= 1'b0 ;
		end
	end else for (int i = 0; i < SLOT_AMOUNT; i++) begin
																				//-----new incoming transaction-----//
		if(new_tran && (i === proc_count) && ~bshake ) begin
			memory[i].id <= awid ;
			memory[i].tran_type <= awuser ;
			memory[i].done <= 0 ;
		end
																				//-----wlast update-----//
		else if(wvalid && wready && wlast && (wid === memory[i].id) && (memory[i].done === 1'b0) ) begin
			memory[i].done <= 1'b1;
		end
																				//-----transaction deletion & Enable forward-----//
		else if (bshake && (i > cur_index_done) && (i < proc_count) ) begin
			memory[i-1].id <= memory[i].id ;
			memory[i-1].tran_type <= memory[i].tran_type ;
			memory[i-1].done <= memory[i].done ;
		end
	end
end


always_ff @(posedge clk or negedge rst_n) begin
	
	if (!rst_n) begin
		proc_count <= 0 ;
		d_spec_release <= 0 ;
		full <= 0 ;
		empty <= 0 ;
	end
	
	else begin																			
																				//-----Special release-----//				
		if ((~|(memory[1].tran_type^DIVERT)) && bshake && (proc_count > 1) && (cur_index_done === 0) && ~release_ready) 
			d_spec_release <= 1'b1 ;
		else if (release_ready)
			d_spec_release <= 1'b0 ;
																				//-----Slot Counter Update-----//
		if(new_tran && ~bshake)  									
			proc_count <= proc_count + 1 ;
		if(bshake && ~new_tran)
			proc_count <= proc_count - 1 ;
		
		full <= (proc_count === SLOT_AMOUNT) ;
		empty <= (proc_count === 0) ;						

	end
end


// synthesis translate_off
//==============================================================================
// DEADLOCK WATCHDOG + RELEASE-PATH TRACE  (debug instrumentation)
//==============================================================================
always @(posedge clk) begin
	if (rst_n) begin
		if (new_tran & ~bshake)
			$display("[PROCMEM @%0t] ADD   id=%0d type=%b -> proc_count(next)=%0d", $time, awid, awuser, proc_count + 1);
		if (bshake)
			$display("[PROCMEM @%0t] BRESP bid=%0d cur_index_done=%0d block_fin=%b proc_count=%0d mem1.type=%b",
				$time, bid, cur_index_done, block_fin, proc_count, memory[1].tran_type);
		if (spec_release)
			$display("[PROCMEM @%0t] SPEC_RELEASE=1 (mem1.type=%b proc_count=%0d release_ready=%b d_spec_release=%b)",
				$time, memory[1].tran_type, proc_count, release_ready, d_spec_release);
	end
end

wire pm_progress = new_tran | bshake | spec_release | release_ready;
integer pm_idle_cnt;
always @(posedge clk or negedge rst_n) begin
	if (!rst_n)                                pm_idle_cnt <= 0;
	else if (pm_progress | (proc_count == 0)) pm_idle_cnt <= 0;
	else                                       pm_idle_cnt <= pm_idle_cnt + 1;
end

always @(posedge clk) begin
	if (rst_n && pm_idle_cnt == 450) begin
		$display("==========================================================================");
		$display("[PROCMEM WATCHDOG @%0t] STUCK with proc_count=%0d -> who owes a move?", $time, proc_count);
		$display("  full=%b empty=%b to_block=%b block_data=%b block_fin=%b", full, empty, to_block, block_data, block_fin);
		$display("  spec_release=%b d_spec_release=%b release_ready=%b cur_index_done=%0d", spec_release, d_spec_release, release_ready, cur_index_done);
		$display("  bvalid=%b bready=%b bid=%0d  awvalid=%b awready=%b awid=%0d  wvalid=%b wready=%b wlast=%b wid=%0d",
			bvalid, bready, bid, awvalid, awready, awid, wvalid, wready, wlast, wid);
		for (int k = 0; (k < 18) && (k < proc_count); k++)
			$display("    pmem[%0d] id=%0d type=%b done=%b", k, memory[k].id, memory[k].tran_type, memory[k].done);
		$display("==========================================================================");
	end
end
// synthesis translate_on


endmodule







 

