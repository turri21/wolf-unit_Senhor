project_open Arcade-SmashTV -revision Arcade-SmashTV
create_timing_netlist -model slow
read_sdc
update_timing_netlist
puts "===== WORST SETUP PATHS (slow corner) ====="
report_timing -setup -npaths 4 -detail summary -stdout
puts "===== WORST SETUP PATH FULL DETAIL ====="
report_timing -setup -npaths 1 -detail full_path -stdout
puts "===== WORST HDMI SETUP PATHS ====="
set hdmi_clock [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
report_timing -setup -to_clock $hdmi_clock -npaths 4 -detail summary -stdout
puts "===== WORST HDMI SETUP PATH FULL DETAIL ====="
report_timing -setup -to_clock $hdmi_clock -npaths 1 -detail full_path -stdout
project_close
