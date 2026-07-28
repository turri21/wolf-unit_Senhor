# SDRAM I/O timing (MT48LC16M16, ~96 MHz). The PLL hierarchy emu|pll|pll_inst|
# altera_pll_i matches this core (emu instantiates `pll pll`); general[1] = outclk_1
# = clk_sdram (the phase-shifted pin clock), general[0] = outclk_0 = clk_sys.
create_generated_clock -name SDRAM_CLK \
  -source [get_pins -compatibility_mode {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {SDRAM_CLK}]

# data access delay (tAC): MT48LC16M16 CAS2 tAC = 6.0 ns (matches jtframe's proven
# MiSTer/MiST SDRAM constraint; Tecmo's extra +0.5 was over-conservative).
set_input_delay -clock SDRAM_CLK -max 6.0 [get_ports {SDRAM_DQ[*]}]

# data output hold time (tOH)
set_input_delay -clock SDRAM_CLK -min 2.5 [get_ports {SDRAM_DQ[*]}]

# data input setup time (tIS)
set_output_delay -clock SDRAM_CLK -max 1.5 [get_ports {SDRAM_A* SDRAM_BA* SDRAM_D* SDRAM_CKE SDRAM_n*}]

# data input hold time (tIH)
set_output_delay -clock SDRAM_CLK -min -0.8 [get_ports {SDRAM_A* SDRAM_BA* SDRAM_D* SDRAM_CKE SDRAM_n*}]

# use proper edges for the timing calculations
set_multicycle_path -setup -end \
  -rise_from [get_clocks {SDRAM_CLK}] \
  -rise_to [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] 2

# Clock domains (PLL outputs): general[0]=clk_sys 96, [1]=clk_sdram 96, [2]=clk_snd 12,
# [3]=clk_cpu 24 (LEGACY, UNUSED since P0019). *** The CPU no longer runs on general[3]. ***
# ROOT CAUSE of the black screen: the old design ran the CPU on a separate clk_cpu (general[3])
# and declared it ASYNCHRONOUS, so STA never timed the CPU<->memsys crossing (yunit_mem_cdc);
# the fitter routed those paths freely and they failed on real silicon while passing zero-delay
# sim. FIX (P0019): run the CPU on clk_sys (general[0]) gated by a 1-in-4 clock-enable (cpu_ce),
# so the whole CPU<->memsys interface is a SINGLE-CLOCK path STA times natively -- no async CDC.
# general[3] now clocks nothing; keeping it in a group is vacuous but harmless. clk_snd
# (general[2], 12 MHz) keeps its own domain (its sound-latch CDC is separate).
set_clock_groups -asynchronous \
  -group [get_clocks [list \
     {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk} \
     {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk} \
     {emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk} ]] \
  -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]

# ---- CPU clock-enable multicycle (P0019) ------------------------------------------------
# Every CPU-domain flop is gated by cpu_ce (pulses 1-in-4 clk_sys), so a value launched from a
# CPU flop is captured by another CPU flop only on the next cpu_ce edge = 4 clk_sys later.
# The cpu_ce domain spans the core plus diagnostic capture registers. The same-clock memory
# adapter has mixed-rate state: its launch registers capture core requests on cpu_ce, but its
# response registers update on any clk_sys edge. Therefore adapter launch registers are valid
# multicycle DESTINATIONS from the core, never multicycle sources back into the core.
#   1. the whole core + submodules  = *tms34010_core:u_core|*   (pc/regfile/divider/status_reg
#      are children of u_core, so this one pattern covers them)
#   2. the derail/reset-vector capture block in wolf_top (rd_cnt/ack_q/.../dbg_*), which is
#      onto cpu_ce -- its long combinational inputs come straight off the core, so it must relax too.
# NOTE: use ONE-LINE get_registers (space-separated patterns). A backslash-continuation INSIDE
# the {} braces is a Tcl trap -- it mangles the pattern list so nothing matches (that was the
# first-build -12.5ns miss). Entity:instance names are the post-sv2v Quartus form; a wrong
# pattern matches nothing and fails LOUDLY as a setup violation.
set cpu_regs [get_registers {*tms34010_core:u_core|* *wolf_top:wolf_top|rd_cnt* *wolf_top:wolf_top|ack_q* *wolf_top:wolf_top|d_started* *wolf_top:wolf_top|d_prevpc* *wolf_top:wolf_top|dbg_derailed* *wolf_top:wolf_top|dbg_culprit_pc* *wolf_top:wolf_top|dbg_culprit_instr* *wolf_top:wolf_top|dbg_derail_pc*}]
set adapter_launch_regs [get_registers {*u_memcdc|scst* *u_memcdc|m_req* *u_memcdc|m_we* *u_memcdc|m_addr* *u_memcdc|m_size* *u_memcdc|m_wdata*}]
set_multicycle_path -setup 4 -from $cpu_regs -to $cpu_regs
set_multicycle_path -hold  3 -from $cpu_regs -to $cpu_regs
set_multicycle_path -setup 4 -from $cpu_regs -to $adapter_launch_regs
set_multicycle_path -hold  3 -from $cpu_regs -to $adapter_launch_regs
# int1 (DMA-done LINT1 = u_dma|blit_irq): a HELD interrupt level from the full-rate memsys domain
# into the CPU (I wired it straight in, replacing the old clk_cpu synchronizer). It is stable >> 4
# clk_sys between service events, so relax the crossing INTO the cpu_ce domain.
set_multicycle_path -setup 4 -from [get_registers {*u_dma|blit_irq*}] -to $cpu_regs
set_multicycle_path -hold  3 -from [get_registers {*u_dma|blit_irq*}] -to $cpu_regs

# ---- DCS ADSP clock-enable multicycle ----------------------------------------------------
# wolf_dcs_board advances the instruction-atomic ADSP and its ROM-cache FSM on
# dcs_ce once every three clk_sys cycles. Host/DAC/DDR one-cycle events are
# stretched at the board/cache boundary, so only paths wholly inside this CE
# domain are relaxed.
# Match the integrated u_dcs_board and the standalone u_dcs_only_board used by
# the silicon audio diagnostic. Both instantiate the identical CE-gated core.
set dcs_regs [get_registers {*wolf_dcs_board:u_dcs*board|adsp2105:u_adsp|*}]
set_multicycle_path -setup 3 -from $dcs_regs -to $dcs_regs
set_multicycle_path -hold  2 -from $dcs_regs -to $dcs_regs

# DIAG_BOOT overlay: a slow diagnostic display whose pixel datapath is ce_pix-gated (1-in-12) and
# whose inputs are stable/slow core+derail signals. Relax ALL paths INTO it. Safe because a
# multicycle is an ANALYSIS directive only (flops still capture every clk); the sole 1-cycle-real
# paths inside it (the toggle-detect ORs) are trivial and cannot hide a real violation. In the
# production (non-DIAG) build u_diag2 does not exist and this matches nothing (harmless).
set_multicycle_path -setup 3 -to [get_registers {*smashtv_diag2_overlay:u_diag2|*}]
set_multicycle_path -hold  2 -to [get_registers {*smashtv_diag2_overlay:u_diag2|*}]

# yunit_mem field-engine (RAM/PAL/CMOS) BRAM writes are MULTICYCLE by the FSM: the
# CPU address a_q is latched in M_IDLE and the write happens in M_HFIN, always 3
# states later (M_ACK->M_HR1->M_HR2->M_HFIN), with a_q stable throughout. So the
# a_q -> field-BRAM address/we combinational chain (region decode + hidx adder +
# hval compare, ~12.5 ns) has >=2 whole clk_sys periods available, not 1. Scoped to
# the ram/pal/nvram BRAM cells only (NOT mem_rdata, which is single-cycle). Safe:
# a wrong -to pattern matches nothing and the violation simply persists.
set_multicycle_path -setup -end 2 \
  -from [get_registers {*u_sys|u_mem|a_q[*]}] \
  -to   [get_registers {*u_sys|u_mem|ram_rtl_0* *u_sys|u_mem|pal_rtl_0* *u_sys|u_mem|nvram_rtl_0*}]
set_multicycle_path -hold -end 1 \
  -from [get_registers {*u_sys|u_mem|a_q[*]}] \
  -to   [get_registers {*u_sys|u_mem|ram_rtl_0* *u_sys|u_mem|pal_rtl_0* *u_sys|u_mem|nvram_rtl_0*}]

# The autoerase VRAM sweep is a background op that HOLDS its SDRAM request for many
# cycles (grant-held arbiter), so er_row is stable well before the phy latches the
# address. Scoped from er_row ONLY (NOT the real-time scanout, whose scan_addr
# changes every word), so relaxing er_row -> SDRAM_A is safe.
set_multicycle_path -setup -end 2 \
  -from [get_registers {*u_vram_sdram|er_row[*]}] -to [get_registers {*u_phy|SDRAM_A[*]}]
set_multicycle_path -hold -end 1 \
  -from [get_registers {*u_vram_sdram|er_row[*]}] -to [get_registers {*u_phy|SDRAM_A[*]}]

# DMA blitter per-pixel source-address chain: ix/xstep_c -> dx_w (add/shift/sub) ->
# 9-bit multiply -> 32-bit add -> o_r, ~11 ns. MEASURED as THE design's timing debt
# (gfx5 STA path extraction: 191 of the top 200 failing endpoints; worst -1.38).
# Architecturally >=2 clk_sys between any ix/xstep_c write and the next o_r or
# registered source-address capture:
# real pixels are spaced by the PXB0/PXB1/WR ack waits (>=3 states), and the one
# back-to-back case (clip-run advances in S_PIX, plus first-entry from S_RPAPP/S_WR)
# is bubbled by clip_gap in wolf_dma.sv (advance every OTHER cycle) — so multicycle 2
# is safe by construction, same pattern as the a_q/er_row/regf relaxations here.
# src_state_addr_r is the local timing boundary before the GFX cache; all paths from
# it into the cache remain one-cycle. Scoped tightly: ONLY ix/xstep_c -> o_r and
# ix/xstep_c -> src_state_addr_r; pix_remain/state/fb_addr/cache inputs stay 1-cycle.
set_multicycle_path -setup -end 2 \
  -from [get_registers {*u_sys|u_dma|ix[*] *u_sys|u_dma|xstep_c[*]}] \
  -to   [get_registers {*u_sys|u_dma|o_r[*] *u_sys|u_dma|src_state_addr_r[*]}]
set_multicycle_path -hold -end 1 \
  -from [get_registers {*u_sys|u_dma|ix[*] *u_sys|u_dma|xstep_c[*]}] \
  -to   [get_registers {*u_sys|u_dma|o_r[*] *u_sys|u_dma|src_state_addr_r[*]}]

# Scaled look-ahead multiplier operands only: ix/xstep_c/bpp_c ->
# sc_mul_args_w -> the fitter-selected register boundary. Quartus may keep the
# logical destination at src_state_addr_r or legally pack/retime it into this
# one multiplier's DSP input DFFs. The exclusive kept alias makes the
# exception independent of inferred Mult* names while preventing it from
# touching the separate o_r-update multiplier or any current-address path.
set dma_scaled_arg_nets [get_nets -no_duplicates {*u_sys|u_dma|sc_mul_args_w*}]
set_multicycle_path -setup -end 2 \
  -from [get_registers {*u_sys|u_dma|ix[*] *u_sys|u_dma|xstep_c[*] *u_sys|u_dma|bpp_c[*]}] \
  -through $dma_scaled_arg_nets \
  -to [get_registers {*u_sys|u_dma|*}]
set_multicycle_path -hold -end 1 \
  -from [get_registers {*u_sys|u_dma|ix[*] *u_sys|u_dma|xstep_c[*] *u_sys|u_dma|bpp_c[*]}] \
  -through $dma_scaled_arg_nets \
  -to [get_registers {*u_sys|u_dma|*}]

# Scaled look-ahead address only: o_r/bpp_c -> sc_next_o_w -> src_state_addr_r.
# S_RPGAP provides a full intervening edge after S_RPAPP; drawn pixels have
# S_PIX (plus any source wait) between S_WR updates; and clipped S_PIX updates
# are separated by clip_gap. Thus every sensitizable path through
# sc_next_o_w has >=2 cycles. The ordinary current-address ROWCHK/ROWPREP path
# does not pass through this kept net and remains a normal single-cycle path.
set dma_scaled_next_o_nets [get_nets -no_duplicates {*u_sys|u_dma|sc_next_o_w*}]
set_multicycle_path -setup -end 2 \
  -from [get_registers {*u_sys|u_dma|o_r[*] *u_sys|u_dma|bpp_c[*]}] \
  -through $dma_scaled_next_o_nets \
  -to [get_registers {*u_sys|u_dma|src_state_addr_r[*]}]
set_multicycle_path -hold -end 1 \
  -from [get_registers {*u_sys|u_dma|o_r[*] *u_sys|u_dma|bpp_c[*]}] \
  -through $dma_scaled_next_o_nets \
  -to [get_registers {*u_sys|u_dma|src_state_addr_r[*]}]

# DMA blitter setup clipping: regf (WIDTH/HEIGHT/XSTART/YSTART/...) -> width_f/height1
# -> the S_SETUP state decision + width_c/height_c latch (~12 ns). The CPU programs the
# blit registers over many SLOW accesses (24 MHz through yunit_mem_cdc, each access is
# >=8 clk_sys cycles) BEFORE the DMA_COMMAND trigger, and COMMAND -> busy_r -> S_SETUP
# is +2 cycles, so regf is stable >=10 clk_sys cycles before it's used -> multicycle.
# Scoped from regf to the S_SETUP-latched targets only (the per-pixel draw counters
# use REGISTERED width_c/height_c, not regf, so they are unaffected / single-cycle).
set_multicycle_path -setup -end 2 \
  -from [get_registers {*u_sys|u_dma|regf[*][*]}] \
  -to   [get_registers {*u_sys|u_dma|state* *u_sys|u_dma|width_c[*] *u_sys|u_dma|height_c[*]}]
set_multicycle_path -hold -end 1 \
  -from [get_registers {*u_sys|u_dma|regf[*][*]}] \
  -to   [get_registers {*u_sys|u_dma|state* *u_sys|u_dma|width_c[*] *u_sys|u_dma|height_c[*]}]
