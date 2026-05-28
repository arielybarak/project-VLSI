module skid_buffer #(parameter W = 8) (
  input  logic           clk,
  input  logic           rst_n,
  // upstream (source)
  input  logic           up_valid,
  output logic           up_ready,
  input  logic [W-1:0]   up_data,
  // downstream (sink)
  output logic           dn_valid,
  input  logic           dn_ready,
  output logic [W-1:0]   dn_data
);
  logic [W-1:0] buf_q;
  logic         buf_full_q;

  // upstream can accept whenever the skid slot is empty
  assign up_ready = !buf_full_q;

  // sink sees buf_q first, else passes up_data straight through
  assign dn_valid = buf_full_q || up_valid;
  assign dn_data  = buf_full_q ? buf_q : up_data;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      buf_q      <= '0;
      buf_full_q <= 1'b0;
    end else begin
      // capture into skid only when sink stalls AND a new beat arrives
      if (up_valid && up_ready && !dn_ready) begin
        buf_q      <= up_data;
        buf_full_q <= 1'b1;
      end
      // drain the skid as soon as sink resumes
      else if (buf_full_q && dn_ready) begin
        buf_full_q <= 1'b0;
      end
    end
  end
endmodule
