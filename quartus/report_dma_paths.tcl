project_open Arcade-SmashTV -revision Arcade-SmashTV
create_timing_netlist -model slow
read_sdc
update_timing_netlist

set sys_clock [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
puts "===== WORST SYSTEM-CLOCK SETUP PATHS ====="
report_timing -setup -to_clock $sys_clock -npaths 10 -detail summary -stdout

puts "===== WORST PATHS LAUNCHED BY DMA o_r ====="
set dma_o [get_registers {*u_sys|u_dma|o_r[*]}]
report_timing -setup -from $dma_o -npaths 10 -detail summary -stdout

puts "===== REGISTERED DMA ADDRESS INTO GFX SOURCE DATA ====="
set dma_src_addr [get_registers {*u_sys|u_dma|src_state_addr_r[*]}]
set gfx_src_data [get_registers {*u_sys|u_gfxddr|src_data[*]}]
report_timing -setup -from $dma_src_addr -to $gfx_src_data -npaths 10 -detail summary -stdout

project_close
