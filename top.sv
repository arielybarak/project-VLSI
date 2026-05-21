/*------------------------------------------------------------------------------
 * File          : top.sv
 * Project       : RTL
 * Author        : epabab
 * Creation date : Nov 24, 2024
 * Description   :
 *------------------------------------------------------------------------------*/

module top
import pkg::*;
(
	input              clk,
	input              rst_n,
	
	/*Master side - FIFO's entrance*/
	axi_if.slave_add   top_slave_add,
	axi_if.slave_data  top_slave_data,
	axi_if.slave_resp  top_slave_resp,
	
	/*Slave side of the module (connected as a Master)*/
	axi_if.master_add  top_master_add,
	axi_if.master_data top_master_data,
	axi_if.master_resp top_master_resp
);
axi_if in () ;	// Master side - FIFO's exit
axi_if out () ;	// Slave side - FIFO's entrance
/* for FIFO */
wire m_add_fifo_full ;
wire m_data_fifo_full ;
wire m_resp_full ;
wire m_add_fifo_empty ;
wire m_data_fifo_empty ;
wire m_resp_fifo_empty ;
logic m_add_fifo_push ;
logic m_data_fifo_push ;
logic m_resp_fifo_push ;
logic m_add_fifo_pop ;
logic m_data_fifo_pop ;
logic m_resp_fifo_pop ;

wire s_add_fifo_full  ;
wire s_data_fifo_full ;
wire s_resp_fifo_full ;
wire s_add_fifo_empty ;
wire s_data_fifo_empty ;
wire s_resp_fifo_empty ;
logic s_add_fifo_push  ;
logic s_data_fifo_push ;
logic s_resp_fifo_push ;
logic s_add_fifo_pop ;
logic s_data_fifo_pop ;
logic s_resp_fifo_pop ;

typedef struct packed {
	logic [1:0]               awburst ;
	logic [PID_WIDTH-1:0]     awid    ;
	logic [PADDR_WIDTH-1:0]   awaddr  ;
	logic [PLENGTH_WIDTH-1:0] awlen   ;
	logic [PSIZE_WIDTH-1:0]   awsize  ;
	logic [PAWUSER_WIDTH-1:0] awuser  ;
	logic [POTHER-1:0]        other   ;
} address_channel ;

typedef struct packed {
	logic [PID_WIDTH-1:0]     wid   ;
	logic [8*PDATA_WIDTH-1:0] wdata ;
	logic [PDATA_WIDTH-1:0]   wstrb ;
	logic [PWUSER_WIDTH-1:0]  wuser ;
	logic                     wlast ;
} data_channel ;

typedef struct packed {
	logic [PID_WIDTH-1:0] bid	;
	logic [1:0]           bresp ;
} respond_channel ;


/* Top input interface into Struct master2fifo*/
address_channel master2fifo_add  ;	
data_channel master2fifo_data 	 ;
respond_channel master2fifo_resp ;
assign master2fifo_add.awburst = top_slave_add.awburst ;
assign master2fifo_add.awid    = top_slave_add.awid	   ;
assign master2fifo_add.awaddr  = top_slave_add.awaddr  ;
assign master2fifo_add.awlen   = top_slave_add.awlen   ;
assign master2fifo_add.awsize  = top_slave_add.awsize  ;
assign master2fifo_add.awuser  = top_slave_add.awuser  ;
assign master2fifo_add.other   = top_slave_add.other   ;		
assign master2fifo_data.wid   = top_slave_data.wid   ;
assign master2fifo_data.wdata = top_slave_data.wdata ;
assign master2fifo_data.wstrb = top_slave_data.wstrb ;
assign master2fifo_data.wuser = top_slave_data.wuser ;
assign master2fifo_data.wlast = top_slave_data.wlast ;
assign top_slave_resp.bid = master2fifo_resp.bid  	 ;
assign top_slave_resp.bresp = master2fifo_resp.bresp ;


/*Struct fifo2module into sub-module's input interface*/
address_channel fifo2module_add  ;
data_channel 	fifo2module_data ;
respond_channel fifo2module_resp ;
assign in.awburst = fifo2module_add.awburst ;
assign in.awid    = fifo2module_add.awid	;
assign in.awaddr  = fifo2module_add.awaddr  ;
assign in.awlen   = fifo2module_add.awlen   ;
assign in.awsize  = fifo2module_add.awsize  ;
assign in.awuser  = fifo2module_add.awuser  ;
assign in.other   = fifo2module_add.other   ;
assign in.wid   = fifo2module_data.wid   ;
assign in.wdata = fifo2module_data.wdata ;
assign in.wstrb = fifo2module_data.wstrb ;
assign in.wuser = fifo2module_data.wuser ;
assign in.wlast = fifo2module_data.wlast ;
assign fifo2module_resp.bid   = in.bid   ;
assign fifo2module_resp.bresp = in.bresp ;


/*Interface of the sub-module's output into Struct module2fifo*/
address_channel module2fifo_add  ;
data_channel    module2fifo_data ;
respond_channel module2fifo_resp ;
assign module2fifo_add.awburst = out.awburst ;
assign module2fifo_add.awid    = out.awid	 ;
assign module2fifo_add.awaddr  = out.awaddr  ;
assign module2fifo_add.awlen   = out.awlen   ;
assign module2fifo_add.awsize  = out.awsize  ;
assign module2fifo_add.awuser  = out.awuser  ;
assign module2fifo_add.other   = out.other   ;
assign module2fifo_data.wid   = out.wid   ;
assign module2fifo_data.wdata = out.wdata ;
assign module2fifo_data.wstrb = out.wstrb ;
assign module2fifo_data.wuser = out.wuser ;
assign module2fifo_data.wlast = out.wlast ;
assign out.bid = module2fifo_resp.bid  	  ;
assign out.bresp = module2fifo_resp.bresp ;


/*Struct fifo2slave into Top output interface*/
address_channel fifo2slave_add  ;
data_channel fifo2slave_data 	;
respond_channel fifo2slave_resp ;
assign top_master_add.awburst = fifo2slave_add.awburst ;
assign top_master_add.awid    = fifo2slave_add.awid    ; 
assign top_master_add.awaddr  = fifo2slave_add.awaddr  ;
assign top_master_add.awlen   = fifo2slave_add.awlen   ;
assign top_master_add.awsize  = fifo2slave_add.awsize  ;
assign top_master_add.awuser  = fifo2slave_add.awuser  ; 
assign top_master_add.other   = fifo2slave_add.other   ;
assign top_master_data.wid   = fifo2slave_data.wid   ;
assign top_master_data.wdata = fifo2slave_data.wdata ;
assign top_master_data.wstrb = fifo2slave_data.wstrb ;
assign top_master_data.wuser = fifo2slave_data.wuser ;
assign top_master_data.wlast = fifo2slave_data.wlast ;
assign fifo2slave_resp.bid = top_master_resp.bid 	 ;
assign fifo2slave_resp.bresp = top_master_resp.bresp ;

/*1*/
/*Top push to master's side FIFO*/
assign m_add_fifo_push = top_slave_add.awvalid & ~m_add_fifo_full    ;
assign m_data_fifo_push = top_slave_data.wvalid & ~m_data_fifo_full  ;
assign s_resp_fifo_push = top_master_resp.bvalid & ~s_resp_fifo_full ;

/*Top master's side ready*/
assign top_slave_add.awready = ~m_add_fifo_full   ;
assign top_slave_data.wready = ~m_data_fifo_full  ;
assign top_master_resp.bready = ~s_resp_fifo_full ;
/*2*/
/*Ready to master side's FIFO (pop) from module*/
assign m_add_fifo_pop = in.awready & (~m_add_fifo_empty===1'b1);
assign m_data_fifo_pop = in.wready & ~m_data_fifo_empty  ;
assign s_resp_fifo_pop = out.bready & ~s_resp_fifo_empty ;

/*Valid from master side's FIFO to module*/
assign in.awvalid = ~m_add_fifo_empty  ;
assign in.wvalid = ~m_data_fifo_empty  ;
assign out.bvalid = ~s_resp_fifo_empty ;
/*3*/
/*Valid to slave side's FIFO (push) from module*/
assign s_add_fifo_push = out.awvalid & ~s_add_fifo_full  ;
assign s_data_fifo_push = out.wvalid & ~s_data_fifo_full ;
assign m_resp_fifo_push = in.bvalid & ~m_resp_full 		 ;

/*Ready from slave side's FIFO to module*/
assign out.awready = ~s_add_fifo_full ; 
assign out.wready = ~s_data_fifo_full ;
assign in.bready = ~m_resp_full 	  ;
/*4*/
/*Slave's side FIFO pop to top*/
assign s_add_fifo_pop = top_master_add.awready & ~s_add_fifo_empty   ;
assign s_data_fifo_pop = top_master_data.wready & ~s_data_fifo_empty ;
assign m_resp_fifo_pop = top_slave_resp.bready & ~m_resp_fifo_empty  ;

/*Top slave's side valid*/
assign top_master_add.awvalid = ~s_add_fifo_empty  ;
assign top_master_data.wvalid = ~s_data_fifo_empty ;
assign top_slave_resp.bvalid = ~m_resp_fifo_empty  ;



										/*Master side FIFO's instantiation*/
DW_asymfifo_s1_sf #(.data_in_width(tot_add), .data_out_width(tot_add), .depth(depth), .af_level(af_level), .ae_level(1)) m_add_fifo
(
	.clk(clk), .rst_n(rst_n), .push_req_n(~m_add_fifo_push), .pop_req_n(~m_add_fifo_pop), .data_in(master2fifo_add), 
	.empty(m_add_fifo_empty), .full(m_add_fifo_full), .data_out(fifo2module_add)
);
DW_asymfifo_s1_sf #(.data_in_width(tot_data), .data_out_width(tot_data), .depth(depth), .af_level(af_level), .ae_level(1)) m_data_fifo
(
	.clk(clk), .rst_n(rst_n), .push_req_n(~m_data_fifo_push), .pop_req_n(~m_data_fifo_pop), .data_in(master2fifo_data),
	.empty(m_data_fifo_empty), .full(m_data_fifo_full), .data_out(fifo2module_data)
);
DW_asymfifo_s1_sf #(.data_in_width(tot_resp), .data_out_width(tot_resp), .depth(depth), .af_level(af_level), .ae_level(1)) m_resp_fifo
(
	.clk(clk), .rst_n(rst_n), .push_req_n(~m_resp_fifo_push), .pop_req_n(~m_resp_fifo_pop), .data_in(fifo2module_resp),
	.empty(m_resp_fifo_empty), .full(m_resp_full), .data_out(master2fifo_resp)
);

										/*Slave side FIFO's instantiation*/
DW_asymfifo_s1_sf #(.data_in_width(tot_add), .data_out_width(tot_add), .depth(depth), .af_level(af_level), .ae_level(1)) s_add_fifo
(
	.clk(clk), .rst_n(rst_n), .push_req_n(~s_add_fifo_push), .pop_req_n(~s_add_fifo_pop), .data_in(module2fifo_add),
	.empty(s_add_fifo_empty), .full(s_add_fifo_full), .data_out(fifo2slave_add)
);
DW_asymfifo_s1_sf #( .data_in_width(tot_data), .data_out_width(tot_data), .depth(depth), .af_level(af_level), .ae_level(1)) s_data_fifo
(
	.clk(clk), .rst_n(rst_n), .push_req_n(~s_data_fifo_push), .pop_req_n(~s_data_fifo_pop), .data_in(module2fifo_data),
	.empty(s_data_fifo_empty), .full(s_data_fifo_full), .data_out(fifo2slave_data)
);
DW_asymfifo_s1_sf #( .data_in_width(tot_resp), .data_out_width(tot_resp), .depth(depth), .af_level(af_level), .ae_level(1)) s_resp_fifo 
(
	.clk(clk), .rst_n(rst_n), .push_req_n(~s_resp_fifo_push), .pop_req_n(~s_resp_fifo_pop), .data_in(fifo2slave_resp),
	.empty(s_resp_fifo_empty), .full(s_resp_fifo_full), .data_out(module2fifo_resp)
);


WriteOrderTop writetop (
	.clk     (clk            ),
	.rst_n   (rst_n          ),
	.t_s_add (in.slave_add   ),
	.t_s_data(in.slave_data  ),
	.t_s_resp(in.slave_resp  ),
	.t_m_add (out.master_add ),
	.t_m_data(out.master_data),
	.t_m_resp(out.master_resp)
);


endmodule






