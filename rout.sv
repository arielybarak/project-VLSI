/*------------------------------------------------------------------------------
 * File          : rout.sv
 * Project       : RTL
 * Author        : epabab
 * Creation date : Jul 20, 2024
 * Description   : decides based on inputs on the address and data router states using combinatorical logic. 
 *------------------------------------------------------------------------------*/

import pkg::*;
module rout (
	input                     clk,
	input                     rst_n,
	
	input                     proc_full,  // processes memory 
	input                     proc_empty,
	input                     block_fin,   
	input					  block_data,

	input                     spec2router, // special memory 
	input 	                  unluck,      
	input                     id_in_spec,
	
	input                     s_awvalid,   // s_add.awvalid
	input [PAWUSER_WIDTH-1:0] s_awuser,
	input                     aw_dn_ready, // s_add downstream ready -> AW handshake = s_awvalid & aw_dn_ready

	output logic              to_block,
	output logic              add_cur_state,
	output logic              data_cur_state
);

 
///////address channel selector//////
parameter ADD_REG_FLOW = 1'b0 ;
parameter ADD_MERGE    = 1'b1 ;

wire add_regular = ((unluck === 1'b0) ? 1'b1 : 1'b0) & s_awvalid & ((|(s_awuser^DIVERT)) | proc_empty) ;
wire add_2merge  = (~add_regular & ~proc_empty) | to_block | spec2router | proc_full ;	

assign add_cur_state = (add_2merge) ? ADD_MERGE : ADD_REG_FLOW ;

///////data channel selector/////////
parameter DATA_REG_FLOW = 1'b0 ;
parameter DATA_MERGE    = 1'b1 ;

assign data_cur_state = (id_in_spec | spec2router | block_data) ? DATA_MERGE : DATA_REG_FLOW ;
wire block_accepted = (~|(s_awuser^BLOCK)) & s_awvalid & aw_dn_ready ;

always_ff @(posedge clk or negedge rst_n) begin
	if(~rst_n)
		to_block <= 1'b0 ;
	else begin
		if(block_accepted)        // BLOCK taken -> block every transaction after it
			to_block <= 1'b1 ;
		else if(block_fin)        // BLOCK completed (B-response) -> reopen
			to_block <= 1'b0 ;
	end
end

endmodule






