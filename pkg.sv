/*------------------------------------------------------------------------------
 * File          : pkg.sv
 * Project       : RTL
 * Author        : epabab
 * Creation date : Jul 20, 2024
 * Description   : Struct definitions and parameters
 *------------------------------------------------------------------------------*/

package pkg;
	
	
	localparam PID_WIDTH = 4 	 ;
	localparam PADDR_WIDTH = 32  ;
	localparam PLENGTH_WIDTH = 3 ;										//in AXI3, Burst_Length = AxLEN[3:0] + 1
	localparam PAWUSER_WIDTH = 2 ;
	localparam PSIZE_WIDTH = 2   ;										//fixed 3. SIZE OF A TRANSTER IN BYTES
	
	localparam PDATA_WIDTH = 2**((2**PSIZE_WIDTH)-1) 	;				// SIZE OF THE DATA BUS IN BYTES (128)
	localparam PSTRB_WIDTH = PSIZE_WIDTH				;				//is max(awsize)/8 = 128/8
	localparam SPEC_SLOT_AMOUNT = 6 					;
	localparam INDEX_WIDTH = $clog2(SPEC_SLOT_AMOUNT)+1 ;
	localparam POTHER	= 9 							;
	
	localparam PCOMPLETE_DATA = PDATA_WIDTH*((2**PLENGTH_WIDTH)+1) ; 	//IN BYTES. 128*     A burst must not cross a 4KB address boundary.
	
	localparam REGULAR = 2'b00 ;
	localparam BLOCK   = 2'b01 ;
	localparam DIVERT  = 2'b10 ;
	localparam UNLUCKY = 2'b11 ;
	
	typedef struct packed {
		reg [PID_WIDTH-1:0]     id 		  ;
		reg [PAWUSER_WIDTH-1:0] tran_type ;
		reg 					done	  ;
	} slot ;
	
	
	typedef struct packed { 	
		reg [INDEX_WIDTH-1:0]   index   ;
		reg                     unluck  ;
		reg [PLENGTH_WIDTH-1:0] cur_len ; 
		reg                     done 	;
		
		reg [PID_WIDTH-1:0]           awid	  ;
		reg [PLENGTH_WIDTH-1:0]       awlen	  ;
		reg [1:0]                     awburst ;
		reg [PADDR_WIDTH-1:0]         awaddr  ;
		reg [PSIZE_WIDTH-1:0]         awsize  ;
		reg [PAWUSER_WIDTH-1:0]       awuser  ;
		reg [POTHER-1:0]			  other   ; 
		
		reg [PCOMPLETE_DATA-1:0][7:0] data    ;
		reg [PCOMPLETE_DATA-1:0]      strb 	  ;
	} spec_slot ;
	
	typedef struct packed { 									//for box_master
		logic [PID_WIDTH-1:0]           awid	  ;
		logic [PLENGTH_WIDTH-1:0]       awlen	  ;
		logic [1:0]                     awburst ;
		logic [PADDR_WIDTH-1:0]         awaddr  ;
		logic [PSIZE_WIDTH-1:0]         awsize  ;
		logic [PAWUSER_WIDTH-1:0]       awuser  ;
		logic [POTHER-1:0]			  other   ; 
		
		logic [PCOMPLETE_DATA-1:0][7:0] data    ;
		logic [PCOMPLETE_DATA-1:0]      strb 	  ;
	} burst_slot ;	
	
	
	

	
endpackage




