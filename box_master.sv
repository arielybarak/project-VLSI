/*------------------------------------------------------------------------------
 * File          : box_master.sv
 * Project       : RTL
 * Author        : epabab
 * Creation date : Oct 5, 2024
 * Description   : Sends a transaction using AXI protocol. 
 *------------------------------------------------------------------------------*/

module box_master
import pkg::*;
(
	input              clk,
	input              rst_n,
	
	input              tran_valid, //connect to special memory
	input spec_slot    in_slot,
	
	output logic       tran_ready, //connect to special memory
	axi_if.master_add  m_add,
	axi_if.master_data m_data
);
burst_slot slot ;
logic [PLENGTH_WIDTH-1:0] sent_transfer ;
logic d_awvalid ;


always_comb begin
	
	if(tran_valid & tran_ready) begin				
		m_add.awvalid = 1'b1 ;
		m_data.wvalid = 1'b1 ;
		m_add.awburst = in_slot.awburst ;
		m_add.awid    = in_slot.awid 	;
		m_add.awaddr  = in_slot.awaddr  ;
		m_add.awlen   = in_slot.awlen 	;
		m_add.awsize  = in_slot.awsize  ;
		m_add.awuser  = in_slot.awuser  ;
		m_add.other   = in_slot.other	;
		m_data.wdata[0 +: PDATA_WIDTH]  <=  in_slot.data[0 +: PDATA_WIDTH] ;
		m_data.wstrb[0 +: PDATA_WIDTH]  <=  in_slot.strb[0 +: PDATA_WIDTH] ;
		m_data.wid = in_slot.awid ;
	end
	else begin
		
		m_add.awvalid = d_awvalid ;
		m_data.wvalid = ~tran_ready ;
		
		if(m_add.awvalid) begin
			m_add.awburst = slot.awburst ;
			m_add.awid    = slot.awid 	 ;
			m_add.awaddr  = slot.awaddr  ;
			m_add.awlen   = slot.awlen 	 ;
			m_add.awsize  = slot.awsize  ;
			m_add.awuser  = slot.awuser  ;
			m_add.other   = slot.other   ;
		end
		else begin
			m_add.awburst = 0 ;
			m_add.awid    = 0 ;
			m_add.awaddr  = 0 ;
			m_add.awlen   = 0 ;
			m_add.awsize  = 0 ;
			m_add.awuser  = 0 ;
			m_add.other   = 0 ;
		end
		
		if(~tran_ready) begin
			m_data.wdata[0 +: PDATA_WIDTH]  =  slot.data[ (sent_transfer*PDATA_WIDTH) +: PDATA_WIDTH ] ;
			m_data.wstrb[0 +: PDATA_WIDTH]  =  slot.strb[ (sent_transfer*PDATA_WIDTH) +: PDATA_WIDTH ] ;
			m_data.wid = slot.awid ;
		end
		else begin
			m_data.wdata[0 +: PDATA_WIDTH]  = 0 ;
			m_data.wstrb[0 +: PDATA_WIDTH]  = 0 ;
			m_data.wid = 0 ;
		end
	end
	
	if((sent_transfer == slot.awlen) & (slot.awlen != 0) )
		m_data.wlast = 1 ;
	else
		m_data.wlast = 0 ;
end

always_ff @(posedge clk or negedge rst_n) begin
	
	if(~rst_n) begin
		tran_ready <= 1 ;
		d_awvalid <= 0 ;
		sent_transfer <= 0 ;
		
		slot.awburst <= 0 ;
		slot.awid    <= 0 ;
		slot.awaddr  <= 0 ;
		slot.awlen   <= 0 ;
		slot.awsize  <= 0 ;
		slot.awuser  <= 0 ;
		slot.other 	 <= 0 ;
		slot.data 	 <= 0 ;
		slot.strb 	 <= 0 ;
	end
	else begin
		
		if(m_add.awready)
			d_awvalid <= 0 ;
		else if(tran_valid & tran_ready)
			d_awvalid <= 1 ;
		
		if(tran_valid & tran_ready) begin
			tran_ready <= 0 ;
			
			slot.awburst <= in_slot.awburst ;
			slot.awid 	 <= in_slot.awid 	;
			slot.awaddr  <= in_slot.awaddr 	;
			slot.awlen   <= in_slot.awlen 	;
			slot.awsize  <= in_slot.awsize 	;
			slot.awuser  <= in_slot.awuser 	;
			slot.other 	 <= in_slot.other 	;
			slot.data 	 <= in_slot.data 	;
			slot.strb 	 <= in_slot.strb 	;
			
			if(m_data.wready) 							// Part of delay prevention
				sent_transfer <= sent_transfer + 1 ;
		end
			
		else if(~tran_ready) begin
			
			if(m_data.wready) 
				sent_transfer <= sent_transfer + 1 ;
				
			if(m_data.wlast & m_data.wready) begin
				sent_transfer <= 0 ;
				tran_ready <= 1 ;
			end
		end
	end
end


endmodule

