/*------------------------------------------------------------------------------
 * File          : pkg.sv
 * Project       : RTL
 * Author        : epabab
 * Creation date : Jul 20, 2024
 * Description   : Struct definitions and parameters
 *------------------------------------------------------------------------------*/

package pkg;
	
	// memory size
	parameter SLOT_AMOUNT = 256 ;
	localparam SPEC_SLOT_AMOUNT = 16 ;
	
	// address channel
	localparam PID_WIDTH = $clog2(SLOT_AMOUNT) ;
	localparam PADDR_WIDTH = 32  ;
	localparam PLENGTH_WIDTH = 3 ;										//in AXI3, Burst_Length = AxLEN[3:0] + 1
	localparam PAWUSER_WIDTH = 2 ;
	localparam PSIZE_WIDTH = 3   ;										//fixed 3. SIZE OF A TRANSTER IN BYTES 
	
	// data channel
//	localparam PDATA_WIDTH = (2**PSIZE_WIDTH)-1) 	  ;					// max size of a transfer (DATA BUS) in bytes
	localparam PDATA_WIDTH = 32 						  ;
	localparam PSTRB_WIDTH = PSIZE_WIDTH			  ;					//is max(awsize)/8 = 128/8
	localparam PWUSER_WIDTH = 8 ;
	localparam INDEX_WIDTH = $clog2(SPEC_SLOT_AMOUNT) ;
	localparam POTHER	= 9 						  ;
	
	localparam PCOMPLETE_DATA = PDATA_WIDTH*((2**PLENGTH_WIDTH)) ; 	//max 2KB.     
	
	// used in FIFO (top.sv) 
	localparam tot_add = 2 + PID_WIDTH + PADDR_WIDTH + PLENGTH_WIDTH + PSIZE_WIDTH + PAWUSER_WIDTH + POTHER ;
	localparam tot_metadata = PID_WIDTH + PDATA_WIDTH + PWUSER_WIDTH + 1 ;
	localparam tot_resp = PID_WIDTH + 2 ;
	
	localparam depth = 8 ;
	localparam af_level = 7 ;
	
	// transaction's states
	localparam REGULAR = 2'b00 ;
	localparam BLOCK   = 2'b01 ;
	localparam DIVERT  = 2'b10 ;
	localparam UNLUCKY = 2'b11 ;
	
	
	
	typedef struct packed {
		logic [PID_WIDTH-1:0]     id 		  ;
		logic [PAWUSER_WIDTH-1:0] tran_type ;
		logic 					done	  ;
	} slot ;	//size 11 bits
	
	
	typedef struct packed { 	
		logic                     unluck  ;
		logic [PLENGTH_WIDTH-1:0] cur_len ; 									
		logic                     done 	;				//11 bits total.
		
		logic [PID_WIDTH-1:0]     awid	  ; //4       should be logics for cur perf
		logic [PLENGTH_WIDTH-1:0] awlen	  ; //3
		logic [1:0]               awburst ; //2
		logic [PADDR_WIDTH-1:0]   awaddr  ; //32
		logic [PSIZE_WIDTH-1:0]   awsize  ; //3
		logic [PAWUSER_WIDTH-1:0] awuser  ;	//2		// should be logics for cur perf			  
		logic [POTHER-1:0]		  other   ; //9, 55 total
														//66 bits for address channel. 17 of them multiple reading.
//		logic [PCOMPLETE_DATA-1:0][7:0] data    ;			//256 bytes (2K bits)
//		logic [PCOMPLETE_DATA-1:0]      strb 	  ;			//256 bits.					
	} spec_slot ;										//total data channel 2,304
	
	// AXI Data Channel metadata (used in pipeline skid buffers)
	typedef struct packed {
		logic [PID_WIDTH-1:0]       wid;
		logic [(PDATA_WIDTH*8)-1:0] wdata;
		logic [PDATA_WIDTH-1:0]     wstrb;
		logic [PWUSER_WIDTH-1:0]    wuser;
		logic                       wlast;
	} skid_data_t;

	typedef struct packed {
		logic [PID_WIDTH-1:0]       wid;
		logic [(PDATA_WIDTH*8)-1:0] wdata;
		logic [PDATA_WIDTH-1:0]     wstrb;
		logic [PWUSER_WIDTH-1:0]    wuser;
		logic                       wlast;
		logic [INDEX_WIDTH-1:0]     wr_idx;
		logic [PLENGTH_WIDTH-1:0]   cur_len_stg1;
		logic [PWUSER_WIDTH-1:0]    wr_isRuined;
	} wr_skid_data_t;

	typedef struct packed {
  		logic [PID_WIDTH-1:0]     awid	  ; 
		logic [PLENGTH_WIDTH-1:0] awlen	  ;
		logic [1:0]               awburst ;
		logic [PADDR_WIDTH-1:0]   awaddr  ; 
		logic [PSIZE_WIDTH-1:0]   awsize  ;
		logic [PAWUSER_WIDTH-1:0] awuser  ;		  
		logic [POTHER-1:0]		  other   ;
	} add_t;
	
	// One row of the age matrix: bit k = "slot k is older than this row's slot".
	typedef logic [SPEC_SLOT_AMOUNT-1:0] age_row_t ;
	
	// Oldest member of `mask`, returned one-hot. One-hot whenever mask != 0.
	//   slot j wins iff it is in the set AND no still-present older slot is in the set.
	function automatic logic [SPEC_SLOT_AMOUNT-1:0] oldest
	    (input logic [SPEC_SLOT_AMOUNT-1:0] mask,
	     input age_row_t age [SPEC_SLOT_AMOUNT]);
	    for (int j = 0; j < SPEC_SLOT_AMOUNT; j++)
	        oldest[j] = mask[j] & ~|(age[j] & mask);
	endfunction
	
	// One-hot -> binary slot index.
	function automatic logic [INDEX_WIDTH-1:0] enc_oh
	    (input logic [SPEC_SLOT_AMOUNT-1:0] oh);
	    enc_oh = '0;
	    for (int j = 0; j < SPEC_SLOT_AMOUNT; j++)
	        if (oh[j]) enc_oh = INDEX_WIDTH'(j);
	endfunction
	
endpackage


// design_vision -f ../scripts/synthesis.tcl -o ../logfile/run.log





