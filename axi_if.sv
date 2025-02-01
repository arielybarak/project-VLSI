/*------------------------------------------------------------------------------
 * File          : axi_if.sv
 * Project       : RTL
 * Author        : epabab
 * Creation date : Jul 16, 2024
 * Description   : AXI protocol interface
 *------------------------------------------------------------------------------*/

interface axi_if
import pkg::*;
();
logic [1:0]				  awburst ;					// "01" for INCR							/////Address Channel//////
logic [PID_WIDTH-1:0]  	  awid;
logic [PADDR_WIDTH-1:0]   awaddr;
logic [PLENGTH_WIDTH-1:0] awlen;
logic [PSIZE_WIDTH-1:0]	  awsize;				//number of bytes in each transfer
logic [PAWUSER_WIDTH-1:0] awuser;
logic					  awvalid;
logic 	    			  awready; 
logic [POTHER-1:0]		  other ;				//AWREGION, AWQOS(only axi4) [2:0]AWPROT [3:0]AWCACHE [1:0]AWLOCK
													
logic [PID_WIDTH-1:0]		 wid;																/////Data Channel//////
logic [PDATA_WIDTH-1:0][7:0] wdata;
logic [PDATA_WIDTH-1:0] 	 wstrb;
logic 						 wlast;				//PID_WIDTH + 2
logic 						 wvalid;
logic 						 wready;

logic [PID_WIDTH-1:0]  bid;																		/////Respond Channel//////
logic [1:0]  	 	   bresp;
logic 				   bvalid;
logic 				   bready;


//separate to master and slave sides
modport slave_add (
	input  awburst,
	       awid,
	       awaddr,
	       awlen,
	       awsize,
	       awvalid,
	       awuser,
		   other,
	
	output awready
);

modport master_add (
	input  awready,
	
	output awburst,
	       awid,
	       awaddr,
	       awlen,
	       awsize,
	       awvalid,
	       awuser,
		   other
);


modport slave_data (
	input  wid,
	       wdata,
	       wstrb,
	       wlast,
	       wvalid,
	
	output wready
);

modport master_data (
	input  wready,
	
	output wid,
	       wdata,
	       wstrb,
	       wlast,
	       wvalid
);

modport slave_resp (
	input  bready,
	
	output bid,
	       bvalid,
	       bresp
);

modport master_resp (
	input  bid,
	       bresp,
	       bvalid,
		   
	output bready
);
   

endinterface : axi_if


