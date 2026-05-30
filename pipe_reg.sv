module pipe_reg #(parameter W = 8) (
  input  logic           clk,
  input  logic           rst_n,
  // upstream
  input  logic           up_valid,
  output logic           up_ready,
  input  logic [W-1:0]   up_data,
  // downstream
  output logic           dn_valid,
  input  logic           dn_ready,
  output logic [W-1:0]   dn_data
);
  logic         valid_q;
  logic [W-1:0] data_q;

  assign up_ready = (!valid_q) || dn_ready;
  assign dn_valid = valid_q;
  assign dn_data  = data_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q <= 1'b0;
      data_q  <= '0;
    end else begin
      if (up_ready) begin
        valid_q <= up_valid;
        if (up_valid) data_q <= up_data;
      end
    end
  end
endmodule
