#define _POSIX_C_SOURCE 200809L
/*
 * SPDX-License-Identifier: MIT
 *
 * DDR bandwidth microbench for the F1 CL (fpga/f1/design/cl_argon2).
 *
 * Uses the same AXI geometry as the fill core (512-bit, 16-beat bursts)
 * to measure isolated per-channel bandwidth and the aggregate 4-channel
 * bandwidth. This is the stage-2 bring-up called out in docs/F1_BRINGUP.md
 * and fpga/f1/README.md: prove each sh_ddr port is independent before
 * running argon2 on it.
 *
 * When the CL is loaded, the bandwidth path can be measured either through
 * the CL's own AXI-MM (if the CL exposes a BW-test mode) or, more simply,
 * by timing raw DMA to DDR via the SDK's DMA API — the latter measures the
 * same sh_ddr path the CL will drive. This program does the latter so it
 * works with both the stock cl_dram_dma and cl_argon2 (both expose the four
 * DDRs as DMA-able regions).
 *
 * Build:
 *   gcc -O2 -Wall -Wextra -std=c11 \
 *       -I$AWS_FPGA_REPO_DIR/sdk/userspace/include \
 *       fpga/f1/host/bw_test.c \
 *       -L$AWS_FPGA_REPO_DIR/sdk/userspace/lib -lfpga_mgmt -lfpga_pci \
 *       -o bw_test
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>
#include <time.h>
#include <inttypes.h>
#include <errno.h>

#ifndef SIM_HOST
#include <fpga_pci.h>
#include <fpga_mgmt.h>

static pci_bar_handle_t ddr_handles[4];
static int slot_id = 0;

static int attach_fpga(int slot) {
    int rc = fpga_mgmt_init();
    if (rc) { fprintf(stderr, "fpga_mgmt_init failed %d\n", rc); return rc; }
    for (int ch = 0; ch < 4; ch++) {
        rc = fpga_pci_attach(slot, FPGA_APP_PF, APP_PF_BAR4, 0, &ddr_handles[ch]);
        if (rc) { fprintf(stderr, "attach ch%d slot %d failed %d\n", ch, slot, rc); return rc; }
    }
    slot_id = slot;
    return 0;
}

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static int dma_write(int ch, uint64_t addr, const void *buf, size_t n) {
    return fpga_pci_dma_write(ddr_handles[ch], addr, (void*)buf, n);
}
static int dma_read(int ch, uint64_t addr, void *buf, size_t n) {
    return fpga_pci_dma_read(ddr_handles[ch], addr, buf, n);
}

#else
/* SIM_HOST fallback: memcpy loop so the binary still builds without the SDK */
static double now_s(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec*1e-9;
}
static uint8_t *sim_mem[4];
static int attach_fpga(int slot){ (void)slot; for(int i=0;i<4;i++){ if(!sim_mem[i]) sim_mem[i]=calloc(1, 1<<20); } return 0; }
static int dma_write(int ch, uint64_t addr, const void *b, size_t n){ (void)addr; if(ch>=0&&ch<4&&sim_mem[ch]) memcpy(sim_mem[ch], b, n); return 0; }
static int dma_read(int ch, uint64_t addr, void *b, size_t n){ (void)addr; if(ch>=0&&ch<4&&sim_mem[ch]) memcpy(b, sim_mem[ch], n); else memset(b,0,n); return 0; }
static void *ddr_handles[4];
#endif

static void usage(const char *a0) {
    fprintf(stderr,
        "Usage: %s [options]\n"
        "  --slot N        FPGA slot (default 0)\n"
        "  --channel C     0..3, or --all for 4-channel aggregate (default --all)\n"
        "  --bytes N       bytes per channel per iteration (default 1 GiB)\n"
        "  --iters N       iterations (default 3)\n"
        "  --burst B       burst beats (informational, default 16)\n"
        "  --base ADDR     base DDR byte address (default 0)\n"
        "\n"
        "Examples:\n"
        "  %s --all --bytes $((32*1024))              # 32 KiB sanity (RFC size)\n"
        "  %s --all --bytes $((1<<30)) --iters 3      # 1 GiB × 3, measure cand/s ceiling\n"
        "  %s --channel 0 --bytes $((1<<30))          # isolate one channel\n",
        a0, a0, a0, a0);
}

int main(int argc, char **argv) {
    int slot = 0;
    int channel = -1; /* -1 = all */
    size_t nbytes = (size_t)1 << 30;
    int iters = 3;
    int burst = 16;
    uint64_t base = 0;

    static struct option opts[] = {
        {"slot",    required_argument, 0, 's'},
        {"channel", required_argument, 0, 'c'},
        {"all",     no_argument,       0, 'a'},
        {"bytes",   required_argument, 0, 'b'},
        {"iters",   required_argument, 0, 'n'},
        {"burst",   required_argument, 0, 'B'},
        {"base",    required_argument, 0, 'o'},
        {"help",    no_argument,       0, 'h'},
        {0,0,0,0}
    };
    int ch;
    while ((ch = getopt_long(argc, argv, "s:c:ab:n:B:o:h", opts, NULL)) != -1) {
        switch (ch) {
            case 's': slot = atoi(optarg); break;
            case 'c': channel = atoi(optarg); break;
            case 'a': channel = -1; break;
            case 'b': nbytes = strtoull(optarg, NULL, 0); break;
            case 'n': iters = atoi(optarg); break;
            case 'B': burst = atoi(optarg); break;
            case 'o': base = strtoull(optarg, NULL, 0); break;
            default: usage(argv[0]); return 2;
        }
    }

    if (channel < -1 || channel > 3) { fprintf(stderr, "channel must be 0..3 or --all\n"); return 2; }
    printf("bw_test: slot=%d %s bytes=%zu iters=%d burst=%d base=0x%016" PRIx64 "\n",
           slot, channel==-1?"all 4 channels":channel==0?"channel 0":channel==1?"channel 1":channel==2?"channel 2":"channel 3",
           nbytes, iters, burst, base);

    int rc = attach_fpga(slot);
    if (rc) return 1;

    size_t align = 4096;
    void *wbuf = NULL, *rbuf = NULL;
    if (posix_memalign(&wbuf, align, nbytes) || posix_memalign(&rbuf, align, nbytes)) {
        perror("posix_memalign"); return 1;
    }
    for (size_t i = 0; i < nbytes; i++) ((uint8_t*)wbuf)[i] = (uint8_t)(i * 31 + 17);

    int channels[4], nch;
    if (channel == -1) { channels[0]=0; channels[1]=1; channels[2]=2; channels[3]=3; nch=4; }
    else { channels[0]=channel; nch=1; }

    double best_write = 0, best_read = 0, best_bidir = 0;

    for (int iter = 0; iter < iters; iter++) {
        /* Write */
        double t0 = now_s();
        for (int ci = 0; ci < nch; ci++) {
            int c = channels[ci];
            uint64_t addr = base + (uint64_t)c * nbytes;
            rc = dma_write(c, addr, wbuf, nbytes);
            if (rc) { fprintf(stderr, "dma_write ch%d failed %d\n", c, rc); return 1; }
        }
        double t1 = now_s();
        double write_gbs = (double)nbytes * nch / (t1 - t0) / 1e9;
        if (write_gbs > best_write) best_write = write_gbs;
        printf("iter %d write: %.3f s  %.2f GB/s aggregate (%.2f GB/s per ch)\n",
               iter, t1 - t0, write_gbs, write_gbs / nch);

        /* Read + verify first 1 MiB */
        t0 = now_s();
        for (int ci = 0; ci < nch; ci++) {
            int c = channels[ci];
            uint64_t addr = base + (uint64_t)c * nbytes;
            rc = dma_read(c, addr, rbuf, nbytes);
            if (rc) { fprintf(stderr, "dma_read ch%d failed %d\n", c, rc); return 1; }
        }
        t1 = now_s();
        double read_gbs = (double)nbytes * nch / (t1 - t0) / 1e9;
        if (read_gbs > best_read) best_read = read_gbs;
        printf("iter %d read : %.3f s  %.2f GB/s aggregate (%.2f GB/s per ch)\n",
               iter, t1 - t0, read_gbs, read_gbs / nch);

        /* Quick verify */
        size_t chk = nbytes < (1<<20) ? nbytes : (1<<20);
        if (memcmp(wbuf, rbuf, chk) != 0) {
            fprintf(stderr, "iter %d: data mismatch in first %zu B\n", iter, chk);
            return 1;
        }

        /* Bidir: interleave write+read to stress independent R/W (argon2 does) */
        t0 = now_s();
        for (int ci = 0; ci < nch; ci++) {
            int c = channels[ci];
            uint64_t addr = base + (uint64_t)c * nbytes;
            rc = dma_write(c, addr, wbuf, nbytes);
            if (rc) return 1;
            rc = dma_read(c, addr, rbuf, nbytes);
            if (rc) return 1;
        }
        t1 = now_s();
        double bidir_gbs = (double)nbytes * nch * 2 / (t1 - t0) / 1e9;
        if (bidir_gbs > best_bidir) best_bidir = bidir_gbs;
        printf("iter %d bidir: %.3f s  %.2f GB/s aggregate (%.2f GB/s per ch)\n",
               iter, t1 - t0, bidir_gbs, bidir_gbs / nch);
    }

    printf("\nBest write : %.2f GB/s aggregate  (%.2f GB/s per channel)\n", best_write, best_write / nch);
    printf("Best read  : %.2f GB/s aggregate  (%.2f GB/s per channel)\n", best_read, best_read / nch);
    printf("Best bidir : %.2f GB/s aggregate  (%.2f GB/s per channel)\n", best_bidir, best_bidir / nch);

    /* Rough cand/s ceiling */
    double random_gbs_per_ch = best_read / nch; /* argon2 is random 1 KiB, sequential is faster */
    double cand_per_s_per_ch = random_gbs_per_ch / 4.0; /* ~4 GB random per guess at 1 GiB t=4 */
    printf("\nRough argon2 ceiling (1 GiB, t=4, ~4 GB random/guess):\n");
    printf("  per channel: ~%.2f cand/s  (%.2f GB/s random / 4 GB)\n", cand_per_s_per_ch, random_gbs_per_ch);
    printf("  4 channels : ~%.2f cand/s\n", cand_per_s_per_ch * 4);
    printf("  HBM2 32ch  : ~%.2f cand/s (extrapolated, assumes same per-pseudo-channel)\n", cand_per_s_per_ch * 32);

    free(wbuf); free(rbuf);
#ifndef SIM_HOST
    for (int i=0;i<nch;i++) fpga_pci_detach(ddr_handles[channels[i]]);
#endif
    return 0;
}
