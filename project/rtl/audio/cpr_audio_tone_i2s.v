`timescale 1ns/1ps
// HDMI audio tone source for the CPR trainer.
//
// Derived from 05_lab_ex/lab_ex5_i2s/src/user_source/hdl_source/
// hdmi_audio_tone_i2s_64fs.v, which is left unmodified. Differences:
//
//   * I_metronome forces a fixed note instead of following the 0.5 s do-re-mi
//     scale. Without this the metronome click inherits whatever note the
//     background scale happens to be on, so consecutive compressions sound at
//     different pitches and the output does not read as a metronome.
//   * A mismatch between the source comment and the RTL is corrected below.
//
// Sample rate: LRCK = I_mclk / 256, i.e. 48027 Hz at the 12.295082 MHz audio
// clock. 64 BCLK cycles per channel slot, MSB first, 24 significant bits then
// 40 zeros.
//
// Channel timing: the generator reloads its shifter with the newly computed
// sample at the end of the right slot and with the previous sample at the end
// of the left slot, so left and right carry adjacent samples rather than the
// same one. That is one sample of L/R skew (about 21 us), inaudible, but it is
// not "the right channel reuses the same sample" as the upstream comment says.
module cpr_audio_tone_i2s #(
    parameter signed [23:0] AMP             = 24'sd2000000,
    parameter integer       NOTE_HOLD_FRAMES= 24000,   // 0.5 s per note at 48 kHz
    parameter [2:0]         METRONOME_NOTE  = 3'd5,    // la / A4 440 Hz
    parameter [31:0]        METRONOME_INC   = 32'd39370534
)(
    input  wire I_mclk,       // 12.295082 MHz
    input  wire I_rst,
    input  wire I_metronome,  // 1 = hold METRONOME_NOTE instead of the scale
    output reg  O_i2s_BCLK,
    output reg  O_i2s_LRCK,
    output reg  O_i2s_DOUT
);

// do/re/mi/fa/so/la/si/do  (C4 D4 E4 F4 G4 A4 B4 C5)
// Phase increments are computed for the 48 kHz sample rate.
function [31:0] note_inc_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: note_inc_lut = 32'd23409862; // do  C4 261.63 Hz
            3'd1: note_inc_lut = 32'd26276681; // re  D4 293.66 Hz
            3'd2: note_inc_lut = 32'd29494578; // mi  E4 329.63 Hz
            3'd3: note_inc_lut = 32'd31248410; // fa  F4 349.23 Hz
            3'd4: note_inc_lut = 32'd35075155; // so  G4 392.00 Hz
            3'd5: note_inc_lut = 32'd39370534; // la  A4 440.00 Hz
            3'd6: note_inc_lut = 32'd44191930; // si  B4 493.88 Hz
            default: note_inc_lut = 32'd46819716; // do  C5 523.25 Hz
        endcase
    end
endfunction

reg  [5:0]  S_bit_cnt;
reg  [63:0] S_shift_reg;
reg  [31:0] S_phase_acc;
reg  signed [23:0] S_sample_word;
reg  signed [23:0] S_sample_next;
reg  [2:0]  S_note_idx;
reg  [15:0] S_note_frame_cnt;

// I_metronome comes from the 25 MHz video domain and only changes at human
// rate, so it is synchronized into I_mclk here. The first stage is excluded
// from timing in constraints/audio_metronome.sdc, matching the mailbox
// synchronizer pattern already used by u_mailbox and u_page_status. Without
// this the tool sees a cross-domain path whose budget is the 1.3 ns difference
// between an 80 ns video edge and an 81.3 ns audio edge, and the design also has
// a real metastability exposure.
reg metronome_meta, metronome_sync;
always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin 
        metronome_meta <= 1'b0;
        metronome_sync <= 1'b0;
    end
    else begin 
        metronome_meta <= I_metronome; 
        metronome_sync <= metronome_meta; 
    end
end

// While the metronome is selected the scale position is ignored, so every
// compression click is the same pitch. The scale index keeps advancing in the
// background so leaving training mode resumes where the scale would have been.
wire [31:0] W_note_inc = metronome_sync ? METRONOME_INC : note_inc_lut(S_note_idx);

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        O_i2s_BCLK      <= 1'b0;
        O_i2s_LRCK      <= 1'b0;
        O_i2s_DOUT      <= 1'b0;
        S_bit_cnt       <= 6'd0;
        S_shift_reg     <= 64'd0;
        S_phase_acc     <= 32'd0;
        S_sample_word   <= 24'sd0;
        S_sample_next   <= AMP;
        S_note_idx      <= 3'd0;
        S_note_frame_cnt<= 16'd0;
    end
    else begin
        // 64 fs transmit timing, compatible with the existing I2S receiver.
        O_i2s_BCLK <= ~O_i2s_BCLK;

        if (O_i2s_BCLK == 1'b1) begin
            O_i2s_DOUT  <= S_shift_reg[63];
            S_shift_reg <= {S_shift_reg[62:0], 1'b0};

            if (S_bit_cnt == 6'd63) begin
                S_bit_cnt <= 6'd0;

                if (O_i2s_LRCK == 1'b0) begin
                    // Left slot finished: send the current sample on the right.
                    O_i2s_LRCK  <= 1'b1;
                    S_shift_reg <= {S_sample_word[23:0], 40'd0};
                end
                else begin
                    // Right slot finished: advance the phase and start the next
                    // frame with the newly computed sample on the left.
                    O_i2s_LRCK  <= 1'b0;

                    S_phase_acc <= S_phase_acc + W_note_inc;
                    if (S_phase_acc[31])
                        S_sample_next <= AMP;
                    else
                        S_sample_next <= -AMP;

                    S_sample_word <= S_sample_next;
                    S_shift_reg   <= {S_sample_next[23:0], 40'd0};

                    if (S_note_frame_cnt == NOTE_HOLD_FRAMES - 1) begin
                        S_note_frame_cnt <= 16'd0;
                        if (S_note_idx == 3'd7)
                            S_note_idx <= 3'd0;
                        else
                            S_note_idx <= S_note_idx + 3'd1;
                    end
                    else begin
                        S_note_frame_cnt <= S_note_frame_cnt + 16'd1;
                    end
                end
            end
            else begin
                S_bit_cnt <= S_bit_cnt + 6'd1;
            end
        end
    end
end

endmodule
