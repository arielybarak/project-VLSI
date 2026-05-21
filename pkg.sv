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
	localparam tot_data = PID_WIDTH + PDATA_WIDTH*8 + PDATA_WIDTH + PWUSER_WIDTH + 1 ;
	localparam tot_resp = PID_WIDTH + 2 ;
	
	localparam depth = 8 ;
	localparam af_level = 7 ;
	
	// transaction's states
	localparam REGULAR = 2'b00 ;
	localparam BLOCK   = 2'b01 ;
	localparam DIVERT  = 2'b10 ;
	localparam UNLUCKY = 2'b11 ;
	
	
	
	typedef struct packed {
		reg [PID_WIDTH-1:0]     id 		  ;
		reg [PAWUSER_WIDTH-1:0] tran_type ;
		reg 					done	  ;
	} slot ;	//size 11 bits
	
	
	typedef struct packed { 	
		reg [INDEX_WIDTH-1:0]   index   ;				//6 for 32 slots
		reg                     unluck  ;
		reg [PLENGTH_WIDTH-1:0] cur_len ; 									
		reg                     done 	;				//11 bits total.
		
		reg [PID_WIDTH-1:0]           awid	  ; //4       should be regs for cur perf
		reg [PLENGTH_WIDTH-1:0]       awlen	  ; //3
		reg [1:0]                     awburst ; //2
		reg [PADDR_WIDTH-1:0]         awaddr  ; //32
		reg [PSIZE_WIDTH-1:0]         awsize  ; //3
		reg [PAWUSER_WIDTH-1:0]       awuser  ;	//2		// should be regs for cur perf			  
		reg [POTHER-1:0]			  other   ; //9, 55 total
														//66 bits for address channel. 17 of them multiple reading.
		
//		reg [PCOMPLETE_DATA-1:0][7:0] data    ;			//256 bytes (2K bits)
//		reg [PCOMPLETE_DATA-1:0]      strb 	  ;			//256 bits.					
	} spec_slot ;										//total data channel 2,304
	
	typedef struct packed { 	
		logic [INDEX_WIDTH-1:0]   index   ;				//3 bits for 4 slots. 5 bits for 16 slots. for 4 slots:     //TODO try without
		logic                     unluck  ;
		logic [PLENGTH_WIDTH-1:0] cur_len ; 
		logic                     done 	  ;				//9/11 bits. better in registers
		
		logic [PID_WIDTH-1:0]           awid	;
		logic [PLENGTH_WIDTH-1:0]       awlen	;
		logic [1:0]                     awburst ;
		logic [PADDR_WIDTH-1:0]         awaddr  ;
		logic [PSIZE_WIDTH-1:0]         awsize  ;
		logic [PAWUSER_WIDTH-1:0]       awuser  ;			//47 bits for address channel. 10 of them multiple reading.  
		
		logic [POTHER-1:0]			  other   ; 		//9 bits
		
//		logic [PCOMPLETE_DATA-1:0][7:0] data    ;			//16384 bits (2KB)
//		logic [PCOMPLETE_DATA-1:0]      strb 	  ;			//2K bits.					sum size 18,432
	} burst_slot ;
	

//	typedef struct packed { 									//for box_master
//		logic [PID_WIDTH-1:0]           awid	  ;
//		logic [PLENGTH_WIDTH-1:0]       awlen	  ;
//		logic [1:0]                     awburst ;
//		logic [PADDR_WIDTH-1:0]         awaddr  ;
//		logic [PSIZE_WIDTH-1:0]         awsize  ;
//		logic [PAWUSER_WIDTH-1:0]       awuser  ;
//		logic [POTHER-1:0]			  other   ; 
//		
//		logic [PCOMPLETE_DATA-1:0][7:0] data    ;
//		logic [PCOMPLETE_DATA-1:0]      strb 	  ;
//	} burst_slot ;	

	
endpackage

// design_vision -f ../scripts/synthesis.tcl -o ../logfile/run.log





