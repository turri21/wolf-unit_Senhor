project_open Arcade-SmashTV -revision Arcade-SmashTV
create_timing_netlist -post_map
read_sdc
update_timing_netlist

set alias_nets [get_nets -no_duplicates {*u_sys|u_dma|sc_mul_args_w*}]
set product_nets [get_nets -no_duplicates {*u_sys|u_dma|sc_next_o_w*}]
set source_regs [get_registers {*u_sys|u_dma|ix[*] *u_sys|u_dma|xstep_c[*] *u_sys|u_dma|bpp_c[*]}]
set dma_regs [get_registers {*u_sys|u_dma|*}]
set src_addr_regs [get_registers {*u_sys|u_dma|src_state_addr_r[*]}]

puts "DMA_ALIAS_NET_COUNT=[get_collection_size $alias_nets]"
puts "DMA_PRODUCT_NET_COUNT=[get_collection_size $product_nets]"
puts "DMA_ALIAS_SOURCE_REG_COUNT=[get_collection_size $source_regs]"
puts "DMA_ALL_TARGET_REG_COUNT=[get_collection_size $dma_regs]"

foreach_in_collection n $alias_nets {
  puts "DMA_ALIAS_NET=[get_net_info -name $n]"
}

set alias_paths [get_timing_paths -setup -from $source_regs -through $alias_nets \
  -to $dma_regs -npaths 5000 -nworst 1 -detail path_only]
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
report_timing -setup -from $source_regs -through $alias_nets -to $dma_regs \
  -npaths 100 -detail summary -stdout

puts "===== ORDINARY O_R TO SRC_STATE PATHS ====="
report_timing -setup \
  -from [get_registers {*u_sys|u_dma|o_r[*]}] -to $src_addr_regs \
  -npaths 8 -detail summary -stdout

puts "===== WORST POST-MAP SETUP PATHS ====="
report_timing -setup -npaths 8 -detail summary -stdout

project_close
