/*------------------------------------------------------------------------------
 * File          : WriteOrderTop.sv
 * Project       : RTL
 * Author        : epabab
 * Creation date : Jul 17, 2024
 * Description   :
 *------------------------------------------------------------------------------*/

module WriteOrderTop
import pkg::*;
(
	input              clk,
	input              rst_n,
	
	/*Master side of the module (connected as a Slave)*/
	axi_if.slave_add   t_s_add,
	axi_if.slave_data  t_s_data,
	axi_if.slave_resp  t_s_resp,
	
	/*Slave side of the module (connected as a Master)*/
	axi_if.master_add  t_m_add,
	axi_if.master_data t_m_data,
	axi_if.master_resp t_m_resp
	
);
parameter ADD_REG_FLOW = 1'b0 ;
parameter ADD_MERGE    = 1'b1 ;
parameter DATA_REG_FLOW = 1'b0 ;
parameter DATA_MERGE    = 1'b1 ;

axi_if axi () ;
axi_if axiOut () ;
wire add_cur_state ;
wire data_cur_state ;
wire unluck ;
wire spec2router;

wire proc_full ;
wire proc_empty ;
wire spec_release ;
wire release_ready ;
wire block_fin ;
wire to_block ;
wire block_data ;
logic s_wready ;
assign s_wready = t_s_data.wready ;

/*--- Phase 1: s_add AW boundary skid -------------------------------------------
 * One skid_buffer decouples the backward awready path from the external m_add_fifo.
 * up_ready (=t_s_add.awready) is a registered output -> severs FIFO.pop combinationally.
 * All AW consumers (special_memory via axi.*, process_mem, rout, regular t_m_add mux)
 * read the skid OUTPUT (s_add_buf/awvalid_buf); the single unified downstream awready
 * (aw_dn_ready) is the existing add_cur_state mux, now feeding the skid's dn_ready. */
add_t s_add_in_bus, s_add_buf ;
logic awvalid_buf ;
logic aw_dn_ready ;

assign s_add_in_bus = '{
	awid    : t_s_add.awid    ,
	awlen   : t_s_add.awlen   ,
	awburst : t_s_add.awburst ,
	awaddr  : t_s_add.awaddr  ,
	awsize  : t_s_add.awsize  ,
	awuser  : t_s_add.awuser  ,
	other   : t_s_add.other
};

skid_buffer #($bits(add_t)) s_add_skid (
	.clk     (clk            ),
	.rst_n   (rst_n          ),
	.up_valid(t_s_add.awvalid),
	.up_ready(t_s_add.awready),
	.up_data (s_add_in_bus   ),
	.dn_valid(awvalid_buf    ),
	.dn_ready(aw_dn_ready    ),
	.dn_data (s_add_buf      )
);

/*Connecting 2 sides of module's respond channel */
assign t_s_resp.bvalid = t_m_resp.bvalid ;
assign t_m_resp.bready = t_s_resp.bready ;
assign t_s_resp.bid = t_m_resp.bid 		 ;
assign t_s_resp.bresp = t_m_resp.bresp   ;


/*Connecting internal AXI bus to the FIFO from Master's side (Slave's modports)*/
assign axi.awvalid = awvalid_buf      ;
assign axi.wvalid  = t_s_data.wvalid  ;
assign axi.awid    = s_add_buf.awid   ;
assign axi.awaddr  = s_add_buf.awaddr ;
assign axi.awburst = s_add_buf.awburst;
assign axi.awlen   = s_add_buf.awlen  ;
assign axi.awsize  = s_add_buf.awsize ;
assign axi.awuser  = s_add_buf.awuser ;
assign axi.other   = s_add_buf.other  ;
assign axi.wid 	   = t_s_data.wid 	 ;
assign axi.wdata   = t_s_data.wdata  ;
assign axi.wstrb   = t_s_data.wstrb  ;
assign axi.wuser   = t_s_data.wuser  ;
assign axi.wlast   = t_s_data.wlast  ;


process_mem monitor (
	.clk          (clk            ),
	.rst_n        (rst_n          ),
	.full_q       (proc_full      ),
	.empty_q      (proc_empty     ),
	.awvalid      (awvalid_buf    ),
	.awready      (aw_dn_ready    ),
	.awid         (s_add_buf.awid ),
	.awuser       (s_add_buf.awuser),
	.wvalid       (t_s_data.wvalid),
	.wready       (s_wready       ),
	.wid          (t_s_data.wid   ),
	.wlast        (t_s_data.wlast ),
	.bvalid       (t_s_resp.bvalid),
	.bready       (t_m_resp.bready),
	.bid          (t_s_resp.bid   ),
	.block_fin    (block_fin      ),
	.to_block     (to_block       ),
	.spec_release_q(spec_release  ),
	.release_ready(release_ready  ),
	.block_data   (block_data     )
);

special_memory spec_mem (
	.clk          (clk               ),
	.rst_n        (rst_n             ),
	.proc_full    (proc_full         ),
	.proc_empty   (proc_empty        ),
	.to_block     (to_block          ),
	.spec_release (spec_release      ),
	.release_ready(release_ready     ),
	.spec2router  (spec2router       ),
	.unluck       (unluck            ),
	.s_add        (axi.slave_add     ),
	.s_data       (axi.slave_data    ),
	.m_add        (axiOut.master_add ),
	.m_data       (axiOut.master_data)
);


rout router (
	.clk           (clk            ),
	.rst_n         (rst_n          ),
	.proc_full     (proc_full      ),
	.proc_empty    (proc_empty     ),
	.spec2router   (spec2router    ),
	.unluck        (unluck         ),
	.s_awvalid     (awvalid_buf     ),
	.block_fin     (block_fin       ),
	.s_awuser      (s_add_buf.awuser),
	.aw_dn_ready   (aw_dn_ready     ),
	.id_in_spec    (axi.wready     ),
	.to_block      (to_block       ),
	.add_cur_state (add_cur_state  ),
	.data_cur_state(data_cur_state ),
	.block_data    (block_data     )
);


/*which bus is permitted to send bursts to the Slaves - Masters or Special Memory*/
always_comb begin
	
	case (add_cur_state)
		
		ADD_REG_FLOW: begin
			t_m_add.awburst = s_add_buf.awburst ;
			t_m_add.awid    = s_add_buf.awid    ;
			t_m_add.awaddr  = s_add_buf.awaddr  ;
			t_m_add.awlen   = s_add_buf.awlen   ;
			t_m_add.awsize  = s_add_buf.awsize  ;
			t_m_add.awuser  = s_add_buf.awuser  ;
			t_m_add.other   = s_add_buf.other   ;
			t_m_add.awvalid = awvalid_buf       ;
			aw_dn_ready     = t_m_add.awready   ;
			axiOut.awready  = 1'b0 ;

		end
		ADD_MERGE:	begin
			t_m_add.awburst = axiOut.awburst ;
			t_m_add.awid    = axiOut.awid    ;
			t_m_add.awaddr  = axiOut.awaddr  ;
			t_m_add.awlen   = axiOut.awlen   ;
			t_m_add.awsize  = axiOut.awsize  ;
			t_m_add.awuser  = axiOut.awuser  ;
			t_m_add.other   = axiOut.other   ;
			t_m_add.awvalid = axiOut.awvalid ;
			axiOut.awready  = t_m_add.awready ;
			aw_dn_ready     = axi.awready	 ;
		end
		
	endcase
	
	case (data_cur_state)
		
		DATA_REG_FLOW: begin
			t_m_data.wid    = t_s_data.wid    ;
			t_m_data.wdata  = t_s_data.wdata  ;
			t_m_data.wstrb  = t_s_data.wstrb  ;
			t_m_data.wuser  = t_s_data.wuser  ;
			t_m_data.wlast  = t_s_data.wlast  ;
			t_m_data.wvalid = t_s_data.wvalid ;
			t_s_data.wready = t_m_data.wready ;
			axiOut.wready  = 1'b0 ;
			
		end
		DATA_MERGE: begin
			t_m_data.wid	= axiOut.wid     ;
			t_m_data.wdata  = axiOut.wdata   ;
			t_m_data.wstrb  = axiOut.wstrb   ;
			t_m_data.wuser  = axiOut.wuser   ;
			t_m_data.wlast  = axiOut.wlast   ;
			t_m_data.wvalid = axiOut.wvalid  ;
			axiOut.wready = t_m_data.wready  ;
			t_s_data.wready = axi.wready	 ;
		end
		default: begin
			t_s_data.wready = 1'b0 ;
		end
		
	endcase
	
end

endmodule







