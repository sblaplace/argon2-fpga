# Synthesis / implementation timing hooks for the argon2 CL at 250 MHz.
#
# The core already runs on the F1 shell's clk_main_a0 (250 MHz); core, OCL,
# and the four DDR AXI ports are all synchronous to it, so there are no
# CDC false-paths to cut and no create_clock to add (the shell's SDC owns
# clk_main_a0). After the argon2_index divider removal, the only remaining
# 250 MHz path is the BlaMka multiply-add, which closes via DSP48 register
# packing — a global retiming switch, not an RTL/XDC change.
#
# This is NOT verified in this repo (no Vivado/HDK here). It is the
# starting point for the first real `aws_build_dcp_from_cl` run; source it
# (or paste its lines) into the HDK synthesis tcl before launch_runs, or
# set the properties on the run objects interactively. See
# docs/TIMING_250MHZ.md for the full critical-path map and the measured
# 250 MHz projection (argon2id 1.240 cand/s/lane target).
#
# --------------------------------------------------------------------
# 1. BlaMka mult-add: let the synth slide the pipeline registers into the
#    DSP48 M/P sites. The 32x32 multiplies already infer DSP48 (BlaMka
#    fbla + the two multiplies in argon2_index); retiming packs their
#    internal registers WITHOUT adding latency, so the N_P=8 overlap
#    schedule (2 P-waves x ~9 cyc) is untouched.
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true  [get_runs synth_1]
# Optional second bite at the apple post-synth:
set_property STEPS.OPT_DESIGN.ARGS.RETIMING      true  [get_runs impl_1]

# 2. Keep DSP inference aggressive (belt-and-suspenders; Vivado infers DSP
#    for 32x32 anyway). No-op if the parts are not Xilinx.
if {[llength [get_parts -quiet]] > 0} {
    # nothing family-specific to set here — documented for completeness
}

# 3. No CDC constraints needed: sh_cl_ocl, sh_ddr, and the core all share
#    clk_main_a0. If a future HDK release moves the OCL config onto a
#    separate clock, add here:
#      set_false_path -from [get_clocks <ocl_clk>] -to [get_clocks clk_main_a0]
#    and register the config write into clk_main_a0 in cl_argon2_core.

# 4. If after place-and-route the worst path is still BlaMka, fold the
#    "+x +y" post-add into the DSP48 C-adder instead of fabric. That is a
#    small fbla() rewrite in rtl/argon2/blamka_g.sv (still 3-cyc latency),
#    not a constraint — see docs/TIMING_250MHZ.md step 2.
