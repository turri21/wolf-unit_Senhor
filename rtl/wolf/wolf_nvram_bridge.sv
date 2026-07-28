// MiSTer index-4 persistence control for the 48 KiB Midway Wolf CMOS image.
//
// The optional MiSTer RTC battery keeps wall-clock time only. Wolf cabinet
// settings, audits, high scores, and unlocks instead travel through hps_io and
// a per-MRA .nvm file. The memory-side interface is byte-wide so the saved
// file is byte-for-byte compatible with MAME's 0x6000 little-endian u16 words.

`default_nettype none
module wolf_nvram_bridge #(
  parameter integer NVRAM_BYTES = 49152
)(
  input  wire logic        clk,
  input  wire logic        rst_pon,
  input  wire logic        ioctl_download,
  input  wire logic        ioctl_upload,
  input  wire logic        ioctl_wr,
  input  wire logic [7:0]  ioctl_index,
  input  wire logic [24:0] ioctl_addr,
  input  wire logic [7:0]  ioctl_dout,
  output logic [7:0]       ioctl_din,
  output logic             ioctl_upload_req,

  input  wire logic        autosave,
  input  wire logic        manual_save,
  input  wire logic        clear_nvram,
  input  wire logic        osd_status,
  input  wire logic        cpu_write_pulse,

  output logic             nvram_ext_en,
  output logic             nvram_ext_wr,
  output logic [15:0]      nvram_ext_addr,
  output logic [7:0]       nvram_ext_wdata,
  input  wire logic [7:0]  nvram_ext_rdata,
  output logic             nvram_busy,
  output logic             nvram_dirty
);
  logic clearing;
  logic [15:0] clear_addr;
  logic old_clear, old_manual, old_osd;
  logic save_pending;

  wire nvram_download = ioctl_download && (ioctl_index == 8'd4);
  wire nvram_upload = ioctl_upload && (ioctl_index == 8'd4);
  wire nvram_addr_valid = ioctl_addr < NVRAM_BYTES;

  // Restore/clear must hold the game reset because they write CMOS. Upload is
  // read-only: wolf_mem stalls only a simultaneous CPU CMOS access, avoiding a
  // visible game reboot whenever MiSTer saves from the OSD.
  assign nvram_busy = nvram_download || clearing;
  assign nvram_ext_en = nvram_busy || nvram_upload;
  assign nvram_ext_wr = clearing ||
                        (nvram_download && ioctl_wr && nvram_addr_valid);
  assign nvram_ext_addr = clearing ? clear_addr : ioctl_addr[15:0];
  assign nvram_ext_wdata = clearing ? 8'h00 : ioctl_dout;
  assign ioctl_din = (ioctl_index == 8'd4 && nvram_addr_valid)
                   ? nvram_ext_rdata : 8'h00;
  assign ioctl_upload_req = save_pending;

  always_ff @(posedge clk) begin
    if (rst_pon) begin
      clearing <= 1'b0;
      clear_addr <= 16'd0;
      old_clear <= 1'b0;
      old_manual <= 1'b0;
      old_osd <= 1'b0;
      save_pending <= 1'b0;
      nvram_dirty <= 1'b0;
    end else begin
      old_clear <= clear_nvram;
      old_manual <= manual_save;
      old_osd <= osd_status;

      if (cpu_write_pulse) nvram_dirty <= 1'b1;

      if (clear_nvram && !old_clear && !clearing) begin
        clearing <= 1'b1;
        clear_addr <= 16'd0;
      end else if (clearing) begin
        if (clear_addr == NVRAM_BYTES-1) begin
          clearing <= 1'b0;
          nvram_dirty <= 1'b1;
          save_pending <= 1'b1;
        end else begin
          clear_addr <= clear_addr + 1'b1;
        end
      end

      if ((manual_save && !old_manual) ||
          (autosave && nvram_dirty && osd_status && !old_osd))
        save_pending <= 1'b1;

      // hps_io accepted the request and began the index-4 upload.
      if (nvram_upload) begin
        save_pending <= 1'b0;
        nvram_dirty <= 1'b0;
      end

      // A restored save is authoritative and starts clean.
      if (nvram_download && ioctl_wr && nvram_addr_valid)
        nvram_dirty <= 1'b0;
    end
  end
endmodule
`default_nettype wire
