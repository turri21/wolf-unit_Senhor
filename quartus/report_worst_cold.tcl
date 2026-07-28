project_open Arcade-SmashTV -revision Arcade-SmashTV
create_timing_netlist -model slow -temperature -40 -voltage 1100
read_sdc
update_timing_netlist
puts "===== WORST COLD SETUP PATHS ====="
report_timing -setup -npaths 4 -detail summary -stdout
puts "===== WORST COLD SETUP PATH FULL DETAIL ====="
report_timing -setup -npaths 1 -detail full_path -stdout
project_close
