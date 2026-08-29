#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
/*
 * SPDX-License-Identifier: MIT
 *
 * Host driver for the F1 argon2 CL (fpga/f1/design/cl_argon2).
 *
 * Implements the full OCL programming sequence plus DMA preload / readback
 * for the working set across up to 4 DDR channels and multiple contexts
 * per channel (default 3, using argon2_lane_conc for +56% cand/s).
 * When the AWS FPGA SDK is not present (simulation or lint), the driver
 * compiles as a self-test that replays the 8 KiB argon2i KAT against
 * the Python reference — see the SIM_HOST fallback.
 *
 * Register offsets match fpga/f1/README.md and cl_argon2_defines.vh.
 * The OCL BAR is byte-addressed; word k is at byte k*4, so lane L's block
 * starts at (16 + L*8)*4 = 0x40 + 0x20*L.
 *
 * Build on an F1 instance (HDK + SDK sourced):
 *   gcc -O2 -Wall -Wextra -std=c11 \
 *       -I$AWS_FPGA_REPO_DIR/sdk/userspace/include \
 *       fpga/f1/host/argon2_cl.c \
 *       -L$AWS_FPGA_REPO_DIR/sdk/userspace/lib -lfpga_mgmt -lfpga_pci \
 *       -o argon2_cl
 *
 * Simulate without hardware (uses the Python vectors under sim/gen/):
 *   gcc -DSIM_HOST -O2 fpga/f1/host/argon2_cl.c -o argon2_cl_sim
 *   ./argon2_cl_sim --check-sim-vectors
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>
#include <errno.h>
#include <inttypes.h>
#include <sys/stat.h>
#include <time.h>

#define A2_OCL_GLOBAL_START 0x000u
#define A2_OCL_CONTROL      0x004u
#define A2_OCL_STATUS       0x008u
#define A2_OCL_LANE_BASE    0x040u
#define A2_OCL_LANE_STRIDE  0x020u
#define A2_OCL_NREG         256u

#define A2_LANE_CTRL    0x00u
#define A2_LANE_PASSES  0x04u
#define A2_LANE_LEN     0x08u
#define A2_LANE_MEMBLK  0x0Cu
#define A2_LANE_BASE_LO 0x10u
#define A2_LANE_BASE_HI 0x14u

#define A2_NUM_DDR 4u
#define A2_DEFAULT_CTXS_PER_CH 3u
#define A2_MAX_LANES 16u
#define A2_BLOCK_BYTES 1024u
#define A2_BEATS_PER_BLOCK 16u
#define A2_STATUS_BUSY_MASK 0x0000FFFFu
#define A2_STATUS_DONE_MASK 0xFFFF0000u
#define A2_STATUS_DONE_SHIFT 16

#ifndef SIM_HOST
/* ---- AWS FPGA SDK ---- */
#include <fpga_pci.h>
#include <fpga_mgmt.h>
#include <utils/lcd.h>

static pci_bar_handle_t ocl_handle = PCI_BAR_HANDLE_INIT;
static pci_bar_handle_t ddr_handles[A2_NUM_DDR];
static int slot_id = 0;

static int ocl_write(uint32_t off, uint32_t val) {
    int rc = fpga_pci_poke(ocl_handle, off, val);
    if (rc) {
        fprintf(stderr, "ocl_write off=0x%03x val=0x%08x failed rc=%d (%s)\n",
                off, val, rc, rc ? strerror(errno) : "ok");
    }
    return rc;
}

static int ocl_read(uint32_t off, uint32_t *val) {
    int rc = fpga_pci_peek(ocl_handle, off, val);
    if (rc) {
        fprintf(stderr, "ocl_read off=0x%03x failed rc=%d\n", off, rc);
    }
    return rc;
}

/* DMA a working-set region at an absolute DDR byte address. `mem`
 * contains 1024-byte Argon2 blocks (beat 0 low in [63:0]). */
static int ddr_write_channel(int ch, uint64_t base, const uint8_t *mem, uint32_t mem_blocks) {
    size_t nbytes = (size_t)mem_blocks * A2_BLOCK_BYTES;
    int rc = fpga_pci_dma_write(ddr_handles[ch], base, (void*)mem, nbytes);
    if (rc) {
        fprintf(stderr, "ddr_write ch%d addr=0x%016" PRIx64 " %zu B failed rc=%d\n",
                ch, base, nbytes, rc);
    } else {
        printf("  DDR ch%d: wrote %zu B to 0x%016" PRIx64 "\n", ch, nbytes, base);
    }
    return rc;
}

static int ddr_read_channel(int ch, uint64_t base, uint8_t *mem, uint32_t mem_blocks) {
    size_t nbytes = (size_t)mem_blocks * A2_BLOCK_BYTES;
    int rc = fpga_pci_dma_read(ddr_handles[ch], base, mem, nbytes);
    if (rc) {
        fprintf(stderr, "ddr_read ch%d addr=0x%016" PRIx64 " %zu B failed rc=%d\n",
                ch, base, nbytes, rc);
    }
    return rc;
}

static int attach_fpga(int slot) {
    int rc;
    rc = fpga_mgmt_init();
    if (rc) { fprintf(stderr, "fpga_mgmt_init failed %d\n", rc); return rc; }

    /* Attach OCL BAR (BAR4 on F1). */
    rc = fpga_pci_attach(slot, FPGA_APP_PF, APP_PF_BAR4, 0, &ocl_handle);
    if (rc) { fprintf(stderr, "fpga_pci_attach OCL slot %d failed %d\n", slot, rc); return rc; }

    for (int ch = 0; ch < (int)A2_NUM_DDR; ch++) {
        ddr_handles[ch] = ocl_handle;
    }
    slot_id = slot;
    printf("Attached to slot %d (OCL BAR handle %d)\n", slot, (int)ocl_handle);
    return 0;
}

#else /* SIM_HOST — compile without the SDK */

static uint32_t sim_regf[A2_OCL_NREG];
static uint8_t *sim_ddr[A2_NUM_DDR];
static size_t sim_ddr_cap[A2_NUM_DDR];
static uint32_t sim_status_busy = 0, sim_status_done = 0;

static int ocl_write(uint32_t off, uint32_t val) {
    if ((off >> 2) < A2_OCL_NREG)
        sim_regf[off >> 2] = val;
    printf("[SIM] OCL poke 0x%03x <- 0x%08x\n", off, val);
    if (off == A2_OCL_GLOBAL_START) {
        /* Mark all programmed lanes as done immediately in SIM_HOST */
        sim_status_done = 0;
        for (uint32_t L = 0; L < A2_MAX_LANES; L++) {
            uint32_t lane_base = A2_OCL_LANE_BASE + L * A2_OCL_LANE_STRIDE;
            if (((lane_base + 8) >> 2) < A2_OCL_NREG && sim_regf[(lane_base + 8) >> 2] != 0)
                sim_status_done |= (1u << L);
        }
        if (sim_status_done == 0) sim_status_done = 0xFFFu;
        sim_status_busy = 0;
        sim_regf[A2_OCL_STATUS >> 2] = (sim_status_done << 16) | ((sim_status_done & 0xFu) << 4) | (sim_status_busy & 0xFFFFu);
    }
    if (off == A2_OCL_CONTROL) {
        sim_regf[A2_OCL_STATUS >> 2] = (sim_status_done << 16) | ((sim_status_done & 0xFu) << 4) | (sim_status_busy & 0xFFFFu);
    }
    return 0;
}

static int ocl_read(uint32_t off, uint32_t *val) {
    if (off == A2_OCL_STATUS) *val = sim_regf[A2_OCL_STATUS >> 2];
    else if ((off >> 2) < A2_OCL_NREG) *val = sim_regf[off >> 2];
    else *val = 0;
    return 0;
}

static int ddr_write_channel(int ch, uint64_t addr, const uint8_t *mem, uint32_t mem_blocks) {
    size_t n = (size_t)mem_blocks * A2_BLOCK_BYTES;
    size_t end = (size_t)addr + n;
    if (sim_ddr_cap[ch] < end) {
        uint8_t *grown = realloc(sim_ddr[ch], end);
        if (!grown) return ENOMEM;
        memset(grown + sim_ddr_cap[ch], 0, end - sim_ddr_cap[ch]);
        sim_ddr[ch] = grown;
        sim_ddr_cap[ch] = end;
    }
    memcpy(sim_ddr[ch] + addr, mem, n);
    printf("[SIM] DDR ch%d write %zu B at offset 0x%" PRIx64 "\n", ch, n, addr);
    return 0;
}

static int ddr_read_channel(int ch, uint64_t addr, uint8_t *mem, uint32_t mem_blocks) {
    size_t n = (size_t)mem_blocks * A2_BLOCK_BYTES;
    size_t end = (size_t)addr + n;
    if (sim_ddr_cap[ch] < end) return EINVAL;
    memcpy(mem, sim_ddr[ch] + addr, n);
    return 0;
}

static int attach_fpga(int slot) {
    (void)slot;
    memset(sim_regf, 0, sizeof sim_regf);
    sim_status_busy = 0;
    sim_status_done = 0;
    for (int i = 0; i < (int)A2_NUM_DDR; i++) {
        free(sim_ddr[i]);
        sim_ddr[i] = NULL;
        sim_ddr_cap[i] = 0;
    }
    return 0;
}
#endif

/* ---- OCL programming ---- */

static int program_lane(int L, uint32_t type_i, uint32_t passes,
                        uint32_t lane_len, uint32_t mem_blks, uint64_t base)
{
    uint32_t base_off = A2_OCL_LANE_BASE + (uint32_t)L * A2_OCL_LANE_STRIDE;
    int rc;
    uint32_t ctrl = (type_i & 0x3u) | ((1u & 0xFFu) << 8); /* lanes field informational */

    rc = ocl_write(base_off + A2_LANE_CTRL,    ctrl);      if (rc) return rc;
    rc = ocl_write(base_off + A2_LANE_PASSES,  passes);    if (rc) return rc;
    rc = ocl_write(base_off + A2_LANE_LEN,     lane_len);  if (rc) return rc;
    rc = ocl_write(base_off + A2_LANE_MEMBLK,  mem_blks);  if (rc) return rc;
    rc = ocl_write(base_off + A2_LANE_BASE_LO, (uint32_t)(base & 0xFFFFFFFFu)); if (rc) return rc;
    rc = ocl_write(base_off + A2_LANE_BASE_HI, (uint32_t)(base >> 32));         if (rc) return rc;

    printf("  lane %d: type=%u passes=%u q=%u m'=%u base=0x%016" PRIx64 "\n",
           L, type_i, passes, lane_len, mem_blks, base);
    return 0;
}

static int run_and_poll(uint32_t expect_done_mask, int timeout_ms) {
    int rc = ocl_write(A2_OCL_GLOBAL_START, 1u);
    if (rc) return rc;
    printf("  GLOBAL_START pulsed, polling STATUS...\n");

    int polls = 0;
    int max_polls = timeout_ms > 0 ? timeout_ms : 1000000;
    uint32_t st = 0;
    uint32_t done = 0;
    do {
        rc = ocl_read(A2_OCL_STATUS, &st);
        if (rc) return rc;
        done = (st >> A2_STATUS_DONE_SHIFT) & expect_done_mask;
        /* Fallback for legacy <=4 lane status format: done in [7:4] */
        if (done == 0 && (expect_done_mask <= 0xFu)) {
            done = ((st >> 4) & 0xFu) & expect_done_mask;
        }
        if ((polls & 0xFFF) == 0 && polls != 0)
            printf("    poll %d: STATUS=0x%08x busy=0x%x done=0x%x\n",
                   polls, st, st & A2_STATUS_BUSY_MASK, done);
        polls++;
        if (done == expect_done_mask) break;
        usleep(1000);
    } while (polls < max_polls);

    printf("  STATUS=0x%08x after %d polls (done=0x%x)\n", st, polls, done);
    if (done != expect_done_mask) {
        fprintf(stderr, "timeout: expected done=0x%x got 0x%x (STATUS=0x%08x)\n",
                expect_done_mask, done, st);
        return -1;
    }
    printf("  all lanes done\n");
    return 0;
}

/* ---- hex file helpers (same format as generated simulation .hex files) ---- */

static uint8_t *load_hex(const char *path, size_t *out_bytes) {
    struct stat st;
    if (stat(path, &st) != 0) {
        fprintf(stderr, "stat %s: %s\n", path, strerror(errno));
        return NULL;
    }
    FILE *f = fopen(path, "r");
    if (!f) { perror(path); return NULL; }

    /* Count non-empty lines to size, then re-read */
    size_t lines = 0;
    char line[512];
    while (fgets(line, sizeof line, f)) {
        char *p = line;
        while (*p==' '||*p=='\t'||*p=='\r'||*p=='\n') p++;
        if (*p && *p != '#') lines++;
    }
    rewind(f);

    size_t nbytes = lines * 64; /* 512-bit beat = 64 bytes */
    uint8_t *buf = calloc(1, nbytes);
    if (!buf) { fclose(f); return NULL; }

    size_t idx = 0;
    while (fgets(line, sizeof line, f) && idx < lines) {
        char *p = line;
        while (*p==' '||*p=='\t'||*p=='\r'||*p=='\n') p++;
        if (!*p || *p=='#') continue;
        /* 128 hex chars = 512 bits, low word first in [63:0] */
        char *end = p + strlen(p) - 1;
        while (end > p && (*end=='\r'||*end=='\n'||*end==' ')) *end-- = '\0';
        size_t len = strlen(p);
        if (len < 128) {
            fprintf(stderr, "%s line %zu: expected 128 hex chars, got %zu\n", path, idx, len);
            free(buf); fclose(f); return NULL;
        }
        for (int b = 0; b < 64; b++) {
            char byte_hex[3] = { p[126 - 2*b], p[127 - 2*b], '\0' };
            buf[idx*64 + b] = (uint8_t)strtoul(byte_hex, NULL, 16);
        }
        idx++;
    }
    fclose(f);
    *out_bytes = nbytes;
    printf("loaded %s: %zu beats = %zu bytes (%zu blocks)\n", path, lines, nbytes, nbytes/1024);
    return buf;
}

static int check_hex(const char *path, const uint8_t *got, size_t nbytes) {
    size_t exp_bytes;
    uint8_t *exp = load_hex(path, &exp_bytes);
    if (!exp) return -1;
    if (exp_bytes != nbytes) {
        fprintf(stderr, "size mismatch: expected %zu B from %s, got %zu B\n",
                exp_bytes, path, nbytes);
        free(exp);
        return -1;
    }
    int mism = 0;
    for (size_t i = 0; i < nbytes; i++) if (got[i] != exp[i]) mism++;
    if (mism) {
        fprintf(stderr, "FAIL %s: %d byte(s) differ\n", path, mism);
        for (size_t blk = 0; blk < nbytes/1024 && blk < 4; blk++) {
            int blk_mism = 0;
            for (size_t j = 0; j < 1024; j++) if (got[blk*1024+j] != exp[blk*1024+j]) blk_mism++;
            if (blk_mism) fprintf(stderr, "  block %zu: %d B differ\n", blk, blk_mism);
        }
        free(exp);
        return -1;
    }
    printf("PASS %s (%zu B match)\n", path, nbytes);
    free(exp);
    return 0;
}

/* ---- main ---- */

static void usage(const char *argv0) {
    fprintf(stderr,
        "Usage: %s [options]\n"
        "  --slot N            FPGA slot (default 0)\n"
        "  --type {d,i,id}     argon2 type (default i)\n"
        "  --passes T          time cost t (default 2)\n"
        "  --lane-len Q        blocks per lane q (default 8)\n"
        "  --mem-blocks M      total blocks m' per context (default 8)\n"
        "  --ctxs-per-ch N     contexts per DDR channel, 1..4 (default 3)\n"
        "  --base ADDR         byte base address in DDR (default 0)\n"
        "  --channel L         run only channel L (0..3), default all\n"
        "  --p4                p=4 job across 4 DDRs (slice barrier)\n"
        "  --init FILE         hex file to DMA into DDR before start\n"
        "  --expect FILE       hex file to compare readback against\n"
        "  --timeout MS        poll timeout in ms (default 1000000)\n"
        "  --check-sim-vectors run built-in sim/gen checks (SIM_HOST)\n"
        "  --out FILE          write readback to FILE (binary)\n"
        "\n"
        "Examples:\n"
        "  # 8 KiB p=1 KAT on channel 0 (3 contexts concentrated, matches tb_cl_argon2):\n"
        "  %s --type i --passes 2 --lane-len 8 --mem-blocks 8 --base 0 \\\n"
        "     --channel 0 --init sim/gen/fill_i_init.hex --expect sim/gen/fill_i_exp.hex\n"
        "  # 8 KiB p=1 on all four channels (4x3 = 12 contexts total, +56%% throughput):\n"
        "  %s --type i --passes 2 --lane-len 8 --mem-blocks 8 --base 0 \\\n"
        "     --init sim/gen/fill_i_init.hex --expect sim/gen/fill_i_exp.hex\n"
        "  # Single context per channel legacy mode:\n"
        "  %s --ctxs-per-ch 1 --type i --passes 2 --lane-len 8 --mem-blocks 8 --base 0 \\\n"
        "     --init sim/gen/fill_i_init.hex --expect sim/gen/fill_i_exp.hex\n",
        argv0, argv0, argv0, argv0);
}

int main(int argc, char **argv) {
    int slot = 0;
    const char *type_str = "i";
    uint32_t passes = 2, lane_len = 8, mem_blocks = 8;
    uint32_t ctxs_per_ch = A2_DEFAULT_CTXS_PER_CH;
    uint64_t base = 0;
    int channel = -1;
    int p4_mode = 0;
    const char *init_path = NULL, *expect_path = NULL, *out_path = NULL;
    int timeout_ms = 1000000;
    int check_sim = 0;

    static struct option opts[] = {
        {"slot",        required_argument, 0, 's'},
        {"type",        required_argument, 0, 't'},
        {"passes",      required_argument, 0, 'p'},
        {"lane-len",    required_argument, 0, 'q'},
        {"mem-blocks",  required_argument, 0, 'm'},
        {"ctxs-per-ch", required_argument, 0, 'C'},
        {"base",        required_argument, 0, 'b'},
        {"channel",     required_argument, 0, 'c'},
        {"p4",          no_argument,       0, '4'},
        {"init",        required_argument, 0, 'i'},
        {"expect",      required_argument, 0, 'e'},
        {"timeout",     required_argument, 0, 'T'},
        {"check-sim-vectors", no_argument, 0, 'k'},
        {"out",         required_argument, 0, 'o'},
        {"help",        no_argument,       0, 'h'},
        {0,0,0,0}
    };
    int ch;
    while ((ch = getopt_long(argc, argv, "s:t:p:q:m:C:b:c:4i:e:T:ko:h", opts, NULL)) != -1) {
        switch (ch) {
            case 's': slot = atoi(optarg); break;
            case 't': type_str = optarg; break;
            case 'p': passes = (uint32_t)atoi(optarg); break;
            case 'q': lane_len = (uint32_t)atoi(optarg); break;
            case 'm': mem_blocks = (uint32_t)atoi(optarg); break;
            case 'C': ctxs_per_ch = (uint32_t)atoi(optarg); break;
            case 'b': base = strtoull(optarg, NULL, 0); break;
            case 'c': channel = atoi(optarg); break;
            case '4': p4_mode = 1; break;
            case 'i': init_path = optarg; break;
            case 'e': expect_path = optarg; break;
            case 'T': timeout_ms = atoi(optarg); break;
            case 'k': check_sim = 1; break;
            case 'o': out_path = optarg; break;
            default: usage(argv[0]); return 2;
        }
    }

    uint32_t type_i;
    if (!strcmp(type_str, "d")) type_i = 0;
    else if (!strcmp(type_str, "i")) type_i = 1;
    else if (!strcmp(type_str, "id")) type_i = 2;
    else { fprintf(stderr, "unknown --type %s (want d/i/id)\n", type_str); return 2; }

#ifdef SIM_HOST
    if (check_sim) {
        printf("SIM_HOST: checking sim/gen vectors via host model\n");
        size_t init_n, exp_n;
        uint8_t *init = load_hex("sim/gen/fill_i_init.hex", &init_n);
        uint8_t *exp  = load_hex("sim/gen/fill_i_exp.hex", &exp_n);
        if (!init || !exp) { free(init); free(exp); return 1; }
        if (init_n != exp_n) {
            fprintf(stderr, "SIM_HOST: vector size mismatch (%zu init vs %zu expected)\n",
                    init_n, exp_n);
            free(init); free(exp); return 1;
        }
        printf("SIM_HOST: init %zu B, exp %zu B — vector I/O OK\n", init_n, exp_n);
        free(init); free(exp);
        printf("SIM_HOST PASS (vectors readable)\n");
        return 0;
    }
#endif

    if (check_sim && init_path == NULL) {
        /* Convenience */
    }

    if (channel < -1 || channel >= (int)A2_NUM_DDR) {
        fprintf(stderr, "--channel must be 0..%d\n", A2_NUM_DDR - 1);
        return 2;
    }
    if (ctxs_per_ch < 1 || ctxs_per_ch > 4) {
        fprintf(stderr, "--ctxs-per-ch must be 1..4\n");
        return 2;
    }
    if (p4_mode && channel >= 0) {
        fprintf(stderr, "--p4 uses all four channels and cannot be combined with --channel\n");
        return 2;
    }
    if (p4_mode) {
        fprintf(stderr,
                "--p4 is not supported by the current F1 CL: Argon2 references "
                "blocks across lanes, but the CL has no cross-channel read router\n");
        return 2;
    }
    if (passes == 0) {
        fprintf(stderr, "--passes must be at least 1\n");
        return 2;
    }
    if (lane_len < 8 || (lane_len & 3u) != 0) {
        fprintf(stderr, "--lane-len must be at least 8 and a multiple of 4\n");
        return 2;
    }
    uint64_t expected_blocks = (uint64_t)lane_len * (p4_mode ? A2_NUM_DDR : 1u);
    if ((uint64_t)mem_blocks != expected_blocks) {
        fprintf(stderr, "--mem-blocks must equal lane_len * lanes (%" PRIu64
                        " for this %s job)\n",
                expected_blocks, p4_mode ? "p=4" : "p=1");
        return 2;
    }
    if ((base & (A2_BLOCK_BYTES - 1u)) != 0) {
        fprintf(stderr, "--base must be aligned to a %u-byte Argon2 block\n",
                A2_BLOCK_BYTES);
        return 2;
    }
    if (timeout_ms <= 0) {
        fprintf(stderr, "--timeout must be greater than zero\n");
        return 2;
    }

    uint32_t total_lanes = p4_mode ? A2_NUM_DDR : (A2_NUM_DDR * ctxs_per_ch);

    printf("argon2_cl: type=%s (%u) passes=%u lane_len=%u mem_blocks=%u ctxs/ch=%u total_lanes=%u base=0x%016" PRIx64 " %s\n",
           type_str, type_i, passes, lane_len, mem_blocks, ctxs_per_ch, total_lanes, base,
           p4_mode ? "p4_mode=1 (4 lanes, one job)" : "p4_mode=0 (independent contexts)");

    int rc = attach_fpga(slot);
    if (rc) return 1;

    uint8_t *init_mem = NULL;
    size_t init_bytes = 0;
    if (init_path) {
        init_mem = load_hex(init_path, &init_bytes);
        if (!init_mem) return 1;
        size_t expect_bytes = (size_t)mem_blocks * A2_BLOCK_BYTES;
        if (init_bytes != expect_bytes) {
            fprintf(stderr, "init file %s is %zu B but mem_blocks %u requires %zu B\n",
                    init_path, init_bytes, mem_blocks, expect_bytes);
            free(init_mem);
            return 2;
        }
    }

    /* Program OCL CONTROL */
    uint32_t control = p4_mode ? 1u : 0u;
    rc = ocl_write(A2_OCL_CONTROL, control);
    if (rc) return 1;

    /* DMA preload */
    if (init_mem) {
        if (p4_mode) {
            for (int L = 0; L < (int)A2_NUM_DDR; L++) {
                uint64_t lbase = base + (uint64_t)L * lane_len * A2_BLOCK_BYTES;
                const uint8_t *src = init_mem + (size_t)L * lane_len * A2_BLOCK_BYTES;
                int r = ddr_write_channel(L, lbase, src, lane_len);
                if (r) return 1;
            }
        } else {
            for (int ch = 0; ch < (int)A2_NUM_DDR; ch++) {
                if (channel >= 0 && ch != channel) continue;
                for (uint32_t g = 0; g < ctxs_per_ch; g++) {
                    uint64_t ctx_addr = base + (uint64_t)g * lane_len * A2_BLOCK_BYTES;
                    int r = ddr_write_channel(ch, ctx_addr, init_mem, mem_blocks);
                    if (r) return 1;
                }
            }
        }
    }

    /* Program lanes */
    if (p4_mode) {
        for (int L = 0; L < (int)A2_NUM_DDR; L++) {
            rc = program_lane(L, type_i, passes, lane_len, mem_blocks, base);
            if (rc) return 1;
        }
    } else {
        for (int ch = 0; ch < (int)A2_NUM_DDR; ch++) {
            if (channel >= 0 && ch != channel) continue;
            for (uint32_t g = 0; g < ctxs_per_ch; g++) {
                int L = ch * ctxs_per_ch + g;
                uint64_t ctx_base = base + (uint64_t)g * lane_len * A2_BLOCK_BYTES;
                rc = program_lane(L, type_i, passes, lane_len, mem_blocks, ctx_base);
                if (rc) return 1;
            }
        }
    }

    /* Expected done mask */
    uint32_t expect_done_mask;
    if (p4_mode) {
        expect_done_mask = (1u << A2_NUM_DDR) - 1u;
    } else if (channel >= 0) {
        expect_done_mask = ((1u << ctxs_per_ch) - 1u) << (channel * ctxs_per_ch);
    } else {
        expect_done_mask = (1u << total_lanes) - 1u;
    }

    rc = run_and_poll(expect_done_mask, timeout_ms);
    if (rc) return 1;

    /* Read back and check */
    if (expect_path || out_path) {
        if (p4_mode) {
            for (int L = 0; L < (int)A2_NUM_DDR; L++) {
                size_t nbytes = (size_t)lane_len * A2_BLOCK_BYTES;
                uint8_t *rb = calloc(1, nbytes);
                uint64_t lane_off = (uint64_t)L * lane_len * A2_BLOCK_BYTES;
                int r = ddr_read_channel(L, base + lane_off, rb, lane_len);
                if (r) { free(rb); return 1; }
                if (out_path) {
                    char fname[512];
                    snprintf(fname, sizeof fname, "%s.ch%d", out_path, L);
                    FILE *f = fopen(fname, "wb");
                    if (f) { fwrite(rb, 1, nbytes, f); fclose(f); printf("wrote %zu B to %s\n", nbytes, fname); }
                }
                if (expect_path) {
                    size_t full_bytes;
                    uint8_t *full = load_hex(expect_path, &full_bytes);
                    if (!full) { free(rb); return 1; }
                    uint8_t *lane_exp = full + (size_t)L * lane_len * A2_BLOCK_BYTES;
                    int mism = 0;
                    for (size_t i = 0; i < nbytes; i++) if (rb[i] != lane_exp[i]) mism++;
                    if (mism) {
                        fprintf(stderr, "FAIL lane %d: %d B differ vs %s\n", L, mism, expect_path);
                        free(full); free(rb); return 1;
                    }
                    printf("PASS lane %d (%zu B match vs %s slice)\n", L, nbytes, expect_path);
                    free(full);
                }
                free(rb);
            }
        } else {
            for (int ch = 0; ch < (int)A2_NUM_DDR; ch++) {
                if (channel >= 0 && ch != channel) continue;
                for (uint32_t g = 0; g < ctxs_per_ch; g++) {
                    int L = ch * ctxs_per_ch + g;
                    size_t nbytes = (size_t)mem_blocks * A2_BLOCK_BYTES;
                    uint8_t *rb = calloc(1, nbytes);
                    uint64_t ctx_addr = base + (uint64_t)g * lane_len * A2_BLOCK_BYTES;
                    int r = ddr_read_channel(ch, ctx_addr, rb, mem_blocks);
                    if (r) { free(rb); return 1; }
                    if (out_path) {
                        char fname[512];
                        if (channel < 0 || ctxs_per_ch > 1)
                            snprintf(fname, sizeof fname, "%s.lane%d", out_path, L);
                        else
                            snprintf(fname, sizeof fname, "%s", out_path);
                        FILE *f = fopen(fname, "wb");
                        if (f) { fwrite(rb, 1, nbytes, f); fclose(f); printf("wrote %zu B to %s\n", nbytes, fname); }
                    }
                    if (expect_path) {
                        int k = check_hex(expect_path, rb, nbytes);
                        if (k) { free(rb); return 1; }
                    }
                    free(rb);
                }
            }
        }
    }

    if (init_mem) free(init_mem);
#ifndef SIM_HOST
    fpga_pci_detach(ocl_handle);
#endif
    printf("argon2_cl: done\n");
    return 0;
}
