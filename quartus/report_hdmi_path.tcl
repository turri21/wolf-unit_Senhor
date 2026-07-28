# Read-only STA against the fit database already on disk. ~9 seconds, no map, no
# fit. Answers the ONE question the summary cannot: WHAT is the failing pll_hdmi
# path -- source register, destination register, and how the delay is spent.
#
# Why it matters: if the endpoint is PLL reconfiguration / mode-change logic, it
# is quasi-static (written once per video-mode change) and a DERIVED multicycle
# is the CORRECT constraint rather than a relaxation. If it is real scaler
# datapath, it is shared sys/ RTL and the blast radius covers every core here.
# Those are different jobs and the summary line cannot tell them apart.
#
# Usage: quartus_sta -t quartus/report_hdmi_path.tcl <revision>

set rev [lindex $quartus(args) 0]
if {$rev eq ""} { set rev "Arcade-SmashTV" }

project_open $rev -revision $rev
create_timing_netlist -model slow
read_sdc
update_timing_netlist

# The failure is at Slow 1100mV -40C specifically; the 100C corner passes.
set_operating_conditions -model slow -temperature -40 -voltage 1100
update_timing_netlist

puts "================ WORST SETUP PATHS, ALL CLOCKS ================"
report_timing -setup -npaths 12 -detail full_path -stdout

puts "================ pll_hdmi DOMAIN ONLY ================"
# Endpoint clock is the pll_hdmi output counter; scope to it so the rows are
# the ones that actually fail rather than the globally worst.
if {[llength [get_clocks -nowarn *pll_hdmi*]] > 0} {
    report_timing -setup -npaths 12 -detail full_path \
        -to_clock [get_clocks *pll_hdmi*] -stdout
} else {
    puts "NOTE: no clock object matched *pll_hdmi* -- reporting by keeper instead"
}

puts "================ SUMMARY ================"
report_clock_fmax_summary -stdout
project_close
