project_open Arcade-SmashTV -revision Arcade-SmashTV
create_timing_netlist -model slow -temperature -40 -voltage 1100
read_sdc
update_timing_netlist

set alias_nets [get_nets -no_duplicates {*u_sys|u_dma|sc_mul_args_w*}]
set scaled_nets [get_nets -no_duplicates {*u_sys|u_dma|sc_next_o_w*}]
set alias_source_regs [get_registers \
  {*u_sys|u_dma|ix[*] *u_sys|u_dma|xstep_c[*] *u_sys|u_dma|bpp_c[*]}]
set scaled_source_regs [get_registers {*u_sys|u_dma|o_r[*] *u_sys|u_dma|bpp_c[*]}]
set target_regs [get_registers {*u_sys|u_dma|src_state_addr_r[*]}]
set dma_regs [get_registers {*u_sys|u_dma|*}]
set mult0_regs [get_registers -no_duplicates {*u_sys|u_dma|Mult0~*}]

puts "DMA_ALIAS_NET_COUNT=[get_collection_size $alias_nets]"
puts "DMA_SCALED_NET_COUNT=[get_collection_size $scaled_nets]"
puts "DMA_ALIAS_SOURCE_REG_COUNT=[get_collection_size $alias_source_regs]"
puts "DMA_SCALED_SOURCE_REG_COUNT=[get_collection_size $scaled_source_regs]"
puts "DMA_TARGET_REG_COUNT=[get_collection_size $target_regs]"
puts "DMA_MULT0_REG_COUNT=[get_collection_size $mult0_regs]"
foreach_in_collection n $alias_nets {
  puts "DMA_ALIAS_NET=[get_net_info -name $n]"
}
foreach_in_collection n $scaled_nets {
  puts "DMA_SCALED_NET=[get_net_info -name $n]"
}
foreach_in_collection r $mult0_regs {
  puts "DMA_MULT0_REG=[get_register_info -name $r]"
}

set alias_paths [get_timing_paths -setup -from $alias_source_regs \
  -through $alias_nets -to $dma_regs -npaths 5000 -nworst 1 \
  -detail path_only]
array set alias_endpoints {}
array set alias_sources {}
foreach_in_collection p $alias_paths {
  set from_name [get_node_info -name [get_path_info -from $p]]
  set to_name [get_node_info -name [get_path_info -to $p]]
  set alias_sources($from_name) 1
  set alias_endpoints($to_name) 1
}
puts "DMA_ALIAS_PATH_COUNT=[get_collection_size $alias_paths]"
puts "DMA_ALIAS_UNIQUE_SOURCE_COUNT=[array size alias_sources]"
puts "DMA_ALIAS_UNIQUE_ENDPOINT_COUNT=[array size alias_endpoints]"
foreach name [lsort [array names alias_sources]] {
  puts "DMA_ALIAS_SOURCE=$name"
}
foreach name [lsort [array names alias_endpoints]] {
  puts "DMA_ALIAS_ENDPOINT=$name"
}

puts "===== ALIAS-CONSTRAINED PATHS ====="
report_timing -setup -from $alias_source_regs -through $alias_nets \
  -to $dma_regs -npaths 20 -detail summary -stdout

puts "===== SCALED NEXT-O PATHS ====="
report_timing -setup -from $scaled_source_regs -through $scaled_nets \
  -to $target_regs \
  -npaths 4 -detail summary -stdout

puts "===== ORDINARY O_R TO SRC_STATE PATHS ====="
report_timing -setup -from [get_registers {*u_sys|u_dma|o_r[*]}] \
  -to $target_regs -npaths 8 -detail summary -stdout

project_close
