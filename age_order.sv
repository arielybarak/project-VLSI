/*------------------------------------------------------------------------------
 * File          : age_order.sv
 * Project       : RTL
 * Author        : Option C Spec
 * Creation date : 2024
 * Description   : O(1) Age Matrix and Occupancy Bitmap
 *------------------------------------------------------------------------------*/

module age_order
import pkg::*;
#(parameter N = SPEC_SLOT_AMOUNT)
(
    input  logic               clk,
    input  logic               rst_n,

    input  logic               alloc_en,   // a new slot is being allocated this cycle
    input  logic [N-1:0]       alloc_oh,   // one-hot: which free slot (must be 0 outside alloc_en)
    input  logic               del_en,     // a slot is being freed this cycle
    input  logic [N-1:0]       del_oh,     // one-hot: which slot (0 outside del_en)

    output logic [N-1:0]       bitmap_val_q,    // occupancy bitmap
    output age_row_t           age_q [N] // age matrix (row i = elders of slot i)
);

wire [N-1:0] del_mask = del_en ? del_oh : '0;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bitmap_val_q <= '0;
        for (int i = 0; i < N; i++) age_q[i] <= '0;
    end else begin
        for (int i = 0; i < N; i++) begin
            if (alloc_en & alloc_oh[i]) begin
                // newcomer: present-and-not-leaving slots are its elders.
                bitmap_val_q[i] <= 1'b1;
                age_q[i] <= bitmap_val_q & ~del_mask;   // snapshot BEFORE adding i
            end else begin
                if (del_en & del_oh[i]) bitmap_val_q[i] <= 1'b0;
                age_q[i] <= age_q[i] & ~del_mask; // clear the freed column everywhere
            end
        end
    end
end

endmodule
