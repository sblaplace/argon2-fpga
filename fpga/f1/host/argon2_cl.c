/*
 * SPDX-License-Identifier: MIT
 *
 * Host-side driver skeleton for the F1 argon2 CL (fpga/f1/design/cl_argon2).
 *
 * This is a SKETCH: it shows the exact OCL register sequence needed to
 * program a job and poll for completion. The actual AWS FPGA Management /
 * PCIe calls and the working-set DMA are left as TODOs (see comments) — the
 * CL itself only drives the DRAM AXI ports, so the working set must be
 * DMAd into each channel's region beforehand (or, for the first KAT, the
 * sim pre-loads it; on hardware you DMA it via sh_cl_dma_pcis).
 *
 * Register offsets match fpga/f1/README.md. The OCL BAR is 32-bit; word k
 * is at byte k*4, so lane L's block starts at (16 + L*8)*4 = 0x40 + 0x20*L.
 *
 * Build (on an F1 instance, with the HDK sourced):
 *   gcc -I$AWS_FPGA_REPO_DIR/sdk/userspace/include \
 *       -L$AWS_FPGA_REPO_DIR/sdk/userspace/lib -lfpga_mgmt -lfpga_pci \
 *       argon2_cl.c -o argon2_cl
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/* ---- OCL register offsets (bytes) -------------------------------------- */
#define A2_OCL_GLOBAL_START 0x000
#define A2_OCL_CONTROL      0x004
#define A2_OCL_STATUS       0x008
#define A2_OCL_LANE_BASE    0x040
#define A2_OCL_LANE_STRIDE  0x020

#define A2_LANE_CTRL    0x00
#define A2_LANE_PASSES  0x04
#define A2_LANE_LEN     0x08
#define A2_LANE_MEMBLK  0x0C
#define A2_LANE_BASE_LO 0x10
#define A2_LANE_BASE_HI 0x14

#define A2_NUM_DDR 4

/* CONTROL bits */
#define A2_CTRL_P4_MODE  (1u << 0)
#define A2_CTRL_SOFT_RST (1u << 1)

/* ---- AWS FPGA handles (TODO: real init in main) ---------------------- */
/* fpga_pci_handle handle;  -- obtained from fpga_pci_attach */
/* For OCL register peeks/pokes the AWS SDK exposes fpga_pci_peek/poke,   */
/* which address the OCL BAR (BAR4) at the offset given below.            */

static int ocl_write(uint64_t off, uint32_t val);
static int ocl_read(uint64_t off, uint32_t *val);

/*
 * Program one lane (channel) for a p=1 fill job and return.
 * type_i: 0=d, 1=i, 2=id.
 */
static int program_lane(int L, uint32_t type_i, uint32_t passes,
                        uint32_t lane_len, uint32_t mem_blks, uint64_t base)
{
    uint32_t base_off = A2_OCL_LANE_BASE + L * A2_OCL_LANE_STRIDE;
    int rc;

    rc = ocl_write(base_off + A2_LANE_CTRL,   (type_i & 0x3) | (1u << 8));
    if (rc) return rc;
    rc = ocl_write(base_off + A2_LANE_PASSES,  passes);   if (rc) return rc;
    rc = ocl_write(base_off + A2_LANE_LEN,     lane_len); if (rc) return rc;
    rc = ocl_write(base_off + A2_LANE_MEMBLK,  mem_blks); if (rc) return rc;
    rc = ocl_write(base_off + A2_LANE_BASE_LO, (uint32_t)(base & 0xFFFFFFFFu));
    if (rc) return rc;
    rc = ocl_write(base_off + A2_LANE_BASE_HI, (uint32_t)(base >> 32));
    return rc;
}

/*
 * Run an independent p=1 job on every channel (p4_mode = 0), then poll
 * STATUS until all lanes report done.
 *
 * TODO: before calling this, DMA the working set for each lane into that
 * channel's DDR region at `base` (sh_cl_dma_pcis), and after done DMA the
 * final working set / tag back to host memory.
 */
static int run_independent(uint32_t type_i, uint32_t passes, uint32_t lane_len,
                           uint32_t mem_blks, uint64_t base)
{
    int rc;
    uint32_t st, done;
    int polls = 0;

    for (int L = 0; L < A2_NUM_DDR; L++) {
        rc = program_lane(L, type_i, passes, lane_len, mem_blks, base);
        if (rc) return rc;
        /* Each channel owns its own region; bump base per channel if
         * the working sets are placed contiguously in one DIMM. */
        base += (uint64_t)mem_blks * 1024u;
    }

    /* Kick all lanes at once. */
    rc = ocl_write(A2_OCL_GLOBAL_START, 1u);
    if (rc) return rc;

    do {
        rc = ocl_read(A2_OCL_STATUS, &st);
        if (rc) return rc;
        done = (st >> 4) & 0xF;            /* done[3:0] */
        polls++;
    } while (done != 0xF && polls < 1000000);

    if (done != 0xF) {
        fprintf(stderr, "argon2_cl: timeout (STATUS=0x%08x)\n", st);
        return -1;
    }
    printf("argon2_cl: all lanes done after %d polls\n", polls);
    return 0;
}

/* ---- OCL access (TODO: fill in with real AWS SDK calls) -------------- */
static int ocl_write(uint64_t off, uint32_t val)
{
    /* TODO: fpga_pci_poke(handle, OCL_BAR, OCL_BASE + off, val); */
    (void)off; (void)val;
    fprintf(stderr, "ocl_write: not implemented (skeleton)\n");
    return -1;
}

static int ocl_read(uint64_t off, uint32_t *val)
{
    /* TODO: fpga_pci_peek(handle, OCL_BAR, OCL_BASE + off, val); */
    (void)off;
    if (val) *val = 0;
    fprintf(stderr, "ocl_read: not implemented (skeleton)\n");
    return -1;
}

int main(void)
{
    /* TODO: fpga_mgmt_init(); fpga_pci_attach(slot, pf_id, &handle); */
    printf("argon2_cl: skeleton — wire up fpga_pci / fpga_mgmt, then:\n");
    printf("  run_independent(type_i=1, passes=2, lane_len=8, mem_blks=8, base=0)\n");
    printf("  (8 KiB argon2i KAT, matching sim/tb_cl_argon2.sv)\n");
    return 0;
}
