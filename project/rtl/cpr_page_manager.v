// Single SD-clock policy. Keys are already debounced, positive levels.
// A held request is accepted when request_valid && request_accept; acceptance
// transfers ownership to the loader, not a guarantee that the page will load.
module cpr_page_manager #(
    parameter [1:0] TRAINING_PAGE_INDEX = 2'd1
)(
    input wire clk, rst,
    input wire training, next_level, prev_level,
    input wire catalog_ready,
    input wire [2:0] page_count,
    input wire display_valid,
    input wire [1:0] display_index,
    input wire request_accept,
    output wire request_valid,
    output reg request_pending,
    output reg [1:0] request_index,
    output wire page_missing,
    output reg user_request
);
reg training_d, next_d, prev_d;
reg saved_valid;
reg [1:0] saved_index;
wire next_press = next_level && !next_d;
wire prev_press = prev_level && !prev_d;
assign page_missing = request_pending && catalog_ready &&
                      ({1'b0,request_index} >= page_count);
assign request_valid = request_pending && catalog_ready && !page_missing;
function [1:0] step_page;
    input [1:0] current;
    input previous;
    input [2:0] total;
    begin
        if (total <= 1) step_page = 0;
        else if (previous)
            step_page = (current == 0 || {1'b0,current} >= total) ? total-1'b1 : current-1'b1;
        else
            step_page = ({1'b0,current}+3'd1 >= total) ? 2'd0 : current+1'b1;
    end
endfunction
always @(posedge clk or posedge rst) begin
    if (rst) begin
        training_d<=0; next_d<=0; prev_d<=0;
        saved_valid<=0; saved_index<=0;
        request_pending<=0; request_index<=0; user_request<=0;
    end else begin
        // Track keys in every mode: holding a key through entry is not a press.
        training_d<=training; next_d<=next_level; prev_d<=prev_level;
        user_request<=0;
        if (request_valid && request_accept) request_pending<=0;
        // Mode transitions supersede a same-cycle ACK and navigation.
        if (training && !training_d) begin
            saved_valid<=display_valid; saved_index<=display_index;
            request_index<=TRAINING_PAGE_INDEX; request_pending<=1; user_request<=1;
        end else if (!training && training_d) begin
            request_index<=saved_valid ? saved_index : 2'd0;
            request_pending<=1; user_request<=1;
        end else if (training && (next_press ^ prev_press)) begin
            user_request<=1;
            if (catalog_ready && page_count!=0) begin
                request_index<=step_page(request_index,prev_press,page_count);
                request_pending<=1;
            end
        end
    end
end
endmodule
