/*------------------------------------------------------------------------------
 * File          : special_mem_dpbank.sv
 * Project       : RTL
 * Author        : epabab
 * Creation date : Dec 22, 2025
 * Description   :
 *------------------------------------------------------------------------------*/


module special_mem_dpbank (
	input  logic         clk,	
	
	// Port 1: Dedicated Writer
	input  logic         wr_en,		// connect to valid
	input  logic [6:0]   wr_addr,  // 128 Depth (16 trans * 8 transfers)
	input  logic [255:0] wr_data,
	input  logic [31:0]  wr_strb,
	input  logic [7:0]  wr_parity,
	input  logic [7:0]  wr_isRuined,
	
	// Port 2: Dedicated Reader
	input  logic         rd_en,
	input  logic [6:0]   rd_addr,
	output logic [255:0] rd_data,
	output logic [31:0]  rd_strb,
	output logic [7:0]  rd_parity,
	output logic [7:0]  rd_isRuined
);

	logic web1 , csb1, oeb1, web2, csb2, oeb2;
	
	// Port 1 (Write): Enable Chip, can Write, can't read Output
	assign csb1 = ~wr_en;          // Chip Select: A global enable for each port of the memory (Active Low)
	assign web1 = ~wr_en;        // Write Enable: Active Low (0 when wr_en=1)
	assign oeb1 = 1'b1;          // Output Enable: Disabled (Write Port)
	
	// Port 2 (Read): Enable Chip, can't Write, can read Output         
	assign csb2 = ~rd_en;
	assign web2 = 1'b1;          // Write Enable: Disabled (Read Only)
	assign oeb2 = ~rd_en;        // Output Enable: Active Low (0 when rd_en=1)


	// Data and Strb Storage
	// -------------------------------------------------------------------------
	// Each instance handles 64 bits (Quarter of a data transfer (256)). 

	//	localparam DATA_WIDTH=$bits();
//	localparam SRAM_CNT = DATA_WIDTH/64;
//	for (int i=0; i<SRAM_CNT = i+1) begin

	dpram128x72 u_ram_128x72_0 (
		// Port 1: Writer
		.A1(wr_addr), .I1({wr_strb[7:0], wr_data[63:0]}), .O1(), 
		.CEB1(clk), .WEB1(web1), .CSB1(csb1), .OEB1(oeb1),
		// Port 2: Reader
		.A2(rd_addr), .I2(72'b0), .O2({rd_strb[7:0], rd_data[63:0]}), 
		.CEB2(clk), .WEB2(web2), .CSB2(csb2), .OEB2(oeb2)
	);


	dpram128x72 u_ram_128x72_1 (
		.A1(wr_addr), .I1({wr_strb[15:8], wr_data[127:64]}), .O1(), 
		.CEB1(clk), .WEB1(web1), .CSB1(csb1), .OEB1(oeb1),
		.A2(rd_addr), .I2(72'b0), .O2({rd_strb[15:8], rd_data[127:64]}), 
		.CEB2(clk), .WEB2(web2), .CSB2(csb2), .OEB2(oeb2)
	);

	
	dpram128x72 u_ram_128x72_2 (
		.A1(wr_addr), .I1({wr_strb[23:16], wr_data[191:128]}), .O1(), 
		.CEB1(clk), .WEB1(web1), .CSB1(csb1), .OEB1(oeb1),
		.A2(rd_addr), .I2(72'b0), .O2({rd_strb[23:16], rd_data[191:128]}), 
		.CEB2(clk), .WEB2(web2), .CSB2(csb2), .OEB2(oeb2)
	);

	
	dpram128x72 u_ram_128x72_3 (
		.A1(wr_addr), .I1({wr_strb[31:24], wr_data[255:192]}), .O1(), 
		.CEB1(clk), .WEB1(web1), .CSB1(csb1), .OEB1(oeb1),
		.A2(rd_addr), .I2(72'b0), .O2({rd_strb[31:24], rd_data[255:192]}), 
		.CEB2(clk), .WEB2(web2), .CSB2(csb2), .OEB2(oeb2)
	);


	// Parity Storage
	// -------------------------------------------------------------------------
	
	
	dpram256x16 u_ram_256x16_parity (
		// Port 1: Writer
		.A1({1'b0, wr_addr}),   .I1({wr_isRuined, wr_parity}),    .O1(), 			//1'b0 pads the MSB to match the port width (128 instead of 256
		.CEB1(clk), .WEB1(web1), .CSB1(csb1), .OEB1(oeb1),

		// Port 2: Reader
		.A2({1'b0, rd_addr}),   .I2(16'b0),        .O2({rd_isRuined, rd_parity}), 
		.CEB2(clk), .WEB2(web2), .CSB2(csb2), .OEB2(oeb2)
	);

endmodule





