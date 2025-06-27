/*------------------------------------------------------------------------------
 * File          : pkg.sv
 * Project       : RTL
 * Author        : epabab
 * Creation date : Jul 20, 2024
 * Description   : Struct definitions and parameters
 *------------------------------------------------------------------------------*/

package pkg;
	
	// memory size
	parameter SLOT_AMOUNT = 16		;
	localparam SPEC_SLOT_AMOUNT = 4 ;
	
	// address channel
	localparam PID_WIDTH = 4 	 ;
	localparam PADDR_WIDTH = 32  ;
	localparam PLENGTH_WIDTH = 3 ;										//in AXI3, Burst_Length = AxLEN[3:0] + 1
	localparam PAWUSER_WIDTH = 2 ;
	localparam PSIZE_WIDTH = 3   ;										//fixed 3. SIZE OF A TRANSTER IN BYTES 
	
	// data channel
//	localparam PDATA_WIDTH = (2**PSIZE_WIDTH)-1) 		;				// max size of a transfer (THE DATA BUS) in bytes = 128
	localparam PDATA_WIDTH = 4 						;
	localparam PSTRB_WIDTH = PSIZE_WIDTH				;				//is max(awsize)/8 = 128/8
	localparam INDEX_WIDTH = $clog2(SPEC_SLOT_AMOUNT)+1 ;
	localparam POTHER	= 9 							;
	
	localparam PCOMPLETE_DATA = PDATA_WIDTH*((2**PLENGTH_WIDTH)) ; 	//max 2KB.     
	
	// used in FIFO (top.sv) 
	localparam tot_add = 2 + PID_WIDTH + PADDR_WIDTH + PLENGTH_WIDTH + PSIZE_WIDTH + PAWUSER_WIDTH + POTHER ;
	localparam tot_data = PID_WIDTH + PDATA_WIDTH*8 + PDATA_WIDTH + 1 ;
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
	} slot ;	//size 7 bits
	
	
	typedef struct packed { 	
		reg [INDEX_WIDTH-1:0]   index   ;				//3 bits for 4 slots. 5 bits for 16 slots. for 4 slots:
		reg                     unluck  ;
		reg [PLENGTH_WIDTH-1:0] cur_len ; 
		reg                     done 	;				//9/11 bits. better in registers
		
		reg [PID_WIDTH-1:0]           awid	  ;
		reg [PLENGTH_WIDTH-1:0]       awlen	  ;
		reg [1:0]                     awburst ;
		reg [PADDR_WIDTH-1:0]         awaddr  ;
		reg [PSIZE_WIDTH-1:0]         awsize  ;
		reg [PAWUSER_WIDTH-1:0]       awuser  ;			//47 bits for address channel. 10 of them multiple reading.  
		
		reg [POTHER-1:0]			  other   ; 		//9 bits
		
		reg [PCOMPLETE_DATA-1:0][7:0] data    ;			//16384 bits (2KB)
		reg [PCOMPLETE_DATA-1:0]      strb 	  ;			//2K bits.					sum size 18,432
	} spec_slot ;										//total size 18,497 bits
	
	typedef struct packed { 	
		logic [INDEX_WIDTH-1:0]   index   ;				//3 bits for 4 slots. 5 bits for 16 slots. for 4 slots:
		logic                     unluck  ;
		logic [PLENGTH_WIDTH-1:0] cur_len ; 
		logic                     done 	;				//9/11 bits. better in registers
		
		logic [PID_WIDTH-1:0]           awid	  ;
		logic [PLENGTH_WIDTH-1:0]       awlen	  ;
		logic [1:0]                     awburst ;
		logic [PADDR_WIDTH-1:0]         awaddr  ;
		logic [PSIZE_WIDTH-1:0]         awsize  ;
		logic [PAWUSER_WIDTH-1:0]       awuser  ;			//47 bits for address channel. 10 of them multiple reading.  
		
		logic [POTHER-1:0]			  other   ; 		//9 bits
		
		logic [PCOMPLETE_DATA-1:0][7:0] data    ;			//16384 bits (2KB)
		logic [PCOMPLETE_DATA-1:0]      strb 	  ;			//2K bits.					sum size 18,432
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


//bash -c ' printf "TYPE\tLEN\tWID\tTOTAL\tSIZE\tAREA\n" for f in *.lef; do base=${f%.lef} if [[ $base =~ ^([A-Za-z]+)([0-9]+)x([0-9]+) ]]; then type=${BASH_REMATCH[1]} len=${BASH_REMATCH[2]} wid=${BASH_REMATCH[3]} total=$((len * wid)) read sx sy < <(grep -m1 -i "SIZE" "$f" | awk "{print \$2, \$4}" | sed "s/\\..*//g") area=$((sx * sy)) printf "%s\t%s\t%s\t%s\t%dx%d\t%d\n" "$type" "$len" "$wid" "$total" "$sx" "$sy" "$area" fi done '





