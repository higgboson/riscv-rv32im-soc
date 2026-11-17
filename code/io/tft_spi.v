// tft_spi.v - memory-mapped SPI transmitter for a 240x320 TFT (ILI9341 / ST7789, RGB565)
//
// Registers (base 0x3000_0000, word offsets):
//   0x00  CTRL    read / write: bit 0 = reset pin (1 = released), bit 1 = backlight,
//                 bit 2 = chip select forced high (deselect), bit 3 = fast clock (SCK = clk / 2)
//   0x04  STATUS  read: bit 0 = full (a write now would be lost), bit 1 = busy (still sending)
//   0x08  CMD     write: send one byte as a command (DC = 0)
//   0x0C  DATA    write: send one byte as data (DC = 1)
//   0x10  PIXEL   write: send one RGB565 pixel, bits 15:0 (two data bytes, high byte first)
//   0x14  PIXEL2  write: send two pixels: bits 15:0 first, then bits 31:16
//   0x18  FILL    write: send the last PIXEL value N more times (N = bits 23:0), in hardware
//
// One word can wait while the previous one is being shifted out, so a program writes, checks
// STATUS.full only when it has to, and keeps computing while the pixels go out. SPI mode 0,
// MSB first, SCK = clk / (2 * HALF): 12.5 MHz from the 50 MHz CPU clock, or 25 MHz with the
// fast bit (most panels manage it; the datasheets only promise about 10 MHz for writes).

`default_nettype none

module tft_spi #(
    parameter integer HALF = 2                // clock cycles per SCK half period
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        wr_en,
    input  wire [31:0] addr,
    input  wire [31:0] wr_data,
    output reg  [31:0] rd_data,
    output wire        tft_cs,
    output wire        tft_rst,
    output wire        tft_dc,
    output wire        tft_mosi,
    output reg         tft_sck,
    output wire        tft_led
);
    wire [2:0] sel = addr[4:2];
    localparam R_CTRL = 3'd0, R_STATUS = 3'd1, R_CMD = 3'd2, R_DATA = 3'd3,
               R_PIX = 3'd4, R_PIX2 = 3'd5, R_FILL = 3'd6;

    reg  [3:0]  ctrl;
    assign tft_rst = ctrl[0];
    assign tft_led = ctrl[1];

    // holding register: one word waiting to be sent
    reg         h_valid;
    reg  [31:0] h_data;
    reg  [5:0]  h_bits;                       // 8, 16 or 32
    reg         h_dc;
    reg  [15:0] last_pix;                     // what FILL repeats
    reg  [23:0] fill_n;

    // shifter
    reg         active;
    reg  [31:0] sh;
    reg  [5:0]  bits_left;
    reg         sh_dc;
    reg  [7:0]  div;
    reg         cs_low;                       // chip select stays low once a transfer started

    assign tft_mosi = sh[31];
    assign tft_dc   = sh_dc;
    assign tft_cs   = ctrl[2] | ~cs_low;

    wire full = h_valid || (fill_n != 24'd0);
    wire busy = full || active;
    wire wr   = wr_en && !full;               // writes while full are dropped (check STATUS)

    always @(*) begin
        case (sel)
            R_CTRL:   rd_data = {28'b0, ctrl};
            R_STATUS: rd_data = {30'b0, busy, full};
            default:  rd_data = 32'b0;
        endcase
    end

    always @(posedge clk) begin
        if (reset) begin
            ctrl <= 4'b0000;  h_valid <= 1'b0;  fill_n <= 24'd0;  active <= 1'b0;
            tft_sck <= 1'b0;  cs_low <= 1'b0;  sh_dc <= 1'b0;  sh <= 32'b0;  div <= 8'd0;
            last_pix <= 16'd0;
        end else begin
            // CPU writes
            if (wr_en && sel == R_CTRL) ctrl <= wr_data[3:0];
            if (wr) case (sel)
                R_CMD:  begin h_valid <= 1'b1; h_dc <= 1'b0; h_bits <= 6'd8;  h_data <= {wr_data[7:0], 24'b0}; end
                R_DATA: begin h_valid <= 1'b1; h_dc <= 1'b1; h_bits <= 6'd8;  h_data <= {wr_data[7:0], 24'b0}; end
                R_PIX:  begin h_valid <= 1'b1; h_dc <= 1'b1; h_bits <= 6'd16; h_data <= {wr_data[15:0], 16'b0};
                              last_pix <= wr_data[15:0]; end
                R_PIX2: begin h_valid <= 1'b1; h_dc <= 1'b1; h_bits <= 6'd32;
                              h_data <= {wr_data[15:0], wr_data[31:16]};  last_pix <= wr_data[31:16]; end
                R_FILL: fill_n <= wr_data[23:0];
                default: ;
            endcase

            // shifter: SCK low for HALF cycles (data stable), high for HALF cycles (sampled)
            if (!active) begin
                tft_sck <= 1'b0;  div <= 8'd0;
                if (h_valid) begin
                    active <= 1'b1;  sh <= h_data;  bits_left <= h_bits;  sh_dc <= h_dc;
                    h_valid <= 1'b0;  cs_low <= 1'b1;
                end else if (fill_n != 24'd0) begin
                    active <= 1'b1;  sh <= {last_pix, 16'b0};  bits_left <= 6'd16;  sh_dc <= 1'b1;
                    fill_n <= fill_n - 24'd1;  cs_low <= 1'b1;
                end
            end else if (!ctrl[3] && div != HALF - 1) begin
                div <= div + 8'd1;
            end else begin
                div <= 8'd0;
                if (!tft_sck) tft_sck <= 1'b1;
                else begin
                    tft_sck <= 1'b0;
                    sh <= sh << 1;
                    if (bits_left == 6'd1) active <= 1'b0;
                    bits_left <= bits_left - 6'd1;
                end
            end
        end
    end
endmodule

`default_nettype wire
