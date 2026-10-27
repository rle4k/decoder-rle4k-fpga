# LED constraints only (to avoid conflicts with board pin file)
set_property PACKAGE_PIN AG14 [get_ports {led[0]}]
set_property PACKAGE_PIN AH14 [get_ports {led[1]}]
set_property PACKAGE_PIN AJ14 [get_ports {led[2]}]
set_property PACKAGE_PIN AD16 [get_ports {led[3]}]

set_property IOSTANDARD LVCMOS18 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS18 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS18 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS18 [get_ports {led[3]}]
