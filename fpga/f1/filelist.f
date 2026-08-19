# Standalone compile order for the F1 CL (no AWS HDK required).
# Paths are relative to fpga/f1/.  Example (iverilog):
#
#   cd fpga/f1
#   iverilog -g2012 -I../../rtl/include -I design -o cl_argon2.out \
#       design/cl_argon2.sv -f filelist.f
#
# Verilator:
#   verilator --lint-only -I../../rtl/include -I design -f filelist.f design/cl_argon2.sv
#
# The AWS HDK build instead compiles the rtl/ + design/ files as part of
# the cl_dram_dma example (see README.md).

../../rtl/blake2b/blake2b_g.sv
../../rtl/blake2b/blake2b_round.sv
../../rtl/blake2b/blake2b_compress.sv
../../rtl/blake2b/blake2b_core.sv
../../rtl/argon2/blamka_g.sv
../../rtl/argon2/argon2_p.sv
../../rtl/argon2/argon2_compress.sv
../../rtl/argon2/argon2_index.sv
../../rtl/argon2/argon2_addr_gen.sv
../../rtl/argon2/argon2_fill_ctrl.sv
../../rtl/argon2/argon2_fill_job.sv
../../rtl/argon2/argon2_axi_mm.sv
../../rtl/argon2/argon2_fill_axi.sv
design/cl_argon2_ocl.sv
design/cl_argon2_core.sv
