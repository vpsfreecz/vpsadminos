/*
 * ebpf-livepatch-loader.c - Userspace loader for BPF livepatch programs.
 *
 * Loads and attaches BPF programs using libbpf skeletons.
 * Each BPF program has a corresponding skeleton header generated
 * by bpftool during the build.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>

/* Skeleton headers are generated at build time and placed alongside this file. */
#include "override_uname.skel.h"
#include "lsm_example.skel.h"

static volatile sig_atomic_t running = 1;

static void sig_handler(int sig) {
    running = 0;
}

static int load_override_uname(void) {
    struct override_uname_bpf *skel;
    int err;

    skel = override_uname_bpf__open();
    if (!skel) {
        fprintf(stderr, "ebpf-livepatch: failed to open override_uname BPF obj\n");
        return -1;
    }

    err = override_uname_bpf__load(skel);
    if (err) {
        fprintf(stderr, "ebpf-livepatch: failed to load override_uname: %d\n", err);
        override_uname_bpf__destroy(skel);
        return -1;
    }

    err = override_uname_bpf__attach(skel);
    if (err) {
        fprintf(stderr, "ebpf-livepatch: failed to attach override_uname: %d\n", err);
        override_uname_bpf__destroy(skel);
        return -1;
    }

    fprintf(stderr, "ebpf-livepatch: override_uname loaded and attached\n");
    return 0;
}

static int load_lsm_example(void) {
    struct lsm_example_bpf *skel;
    int err;

    skel = lsm_example_bpf__open();
    if (!skel) {
        fprintf(stderr, "ebpf-livepatch: failed to open lsm_example BPF obj\n");
        return -1;
    }

    err = lsm_example_bpf__load(skel);
    if (err) {
        fprintf(stderr, "ebpf-livepatch: failed to load lsm_example: %d\n", err);
        lsm_example_bpf__destroy(skel);
        return -1;
    }

    err = lsm_example_bpf__attach(skel);
    if (err) {
        fprintf(stderr, "ebpf-livepatch: failed to attach lsm_example: %d\n", err);
        lsm_example_bpf__destroy(skel);
        return -1;
    }

    fprintf(stderr, "ebpf-livepatch: lsm_example loaded and attached\n");
    return 0;
}

static void usage(const char *progname) {
    fprintf(stderr, "Usage: %s <load|unload|run> <program-name|all>\n", progname);
    fprintf(stderr, "  load <name|all>  Load and attach BPF program(s)\n");
    fprintf(stderr, "  run  <name|all>  Load, attach, and wait (foreground)\n");
    fprintf(stderr, "  unload all       Unload all BPF programs (process exit)\n");
    fprintf(stderr, "\nAvailable programs: override_uname, lsm_example\n");
}

int main(int argc, char **argv) {
    const char *cmd, *prog;
    int err, ret = 0;

    if (argc < 2) {
        usage(argv[0]);
        return 1;
    }

    cmd = argv[1];
    prog = argc >= 3 ? argv[2] : "all";

    libbpf_set_print(NULL); /* suppress libbpf debug output */

    if (strcmp(cmd, "load") == 0 || strcmp(cmd, "run") == 0) {
        if (strcmp(prog, "all") == 0 || strcmp(prog, "override_uname") == 0) {
            err = load_override_uname();
            if (err) {
                fprintf(stderr, "ebpf-livepatch: failed to load override_uname\n");
                ret = 1;
            }
        }
        if (strcmp(prog, "all") == 0 || strcmp(prog, "lsm_example") == 0) {
            err = load_lsm_example();
            if (err) {
                fprintf(stderr, "ebpf-livepatch: failed to load lsm_example\n");
                ret = 1;
            }
        }
        if (strcmp(prog, "all") != 0 &&
            strcmp(prog, "override_uname") != 0 &&
            strcmp(prog, "lsm_example") != 0) {
            fprintf(stderr, "ebpf-livepatch: unknown program '%s'\n", prog);
            ret = 1;
        }
    } else if (strcmp(cmd, "unload") == 0) {
        /*
         * BPF programs are auto-detached when the loader process exits
         * and its file descriptors are closed. For pinned programs,
         * we would clean up bpffs entries here.
         */
        fprintf(stderr, "ebpf-livepatch: unload relies on process exit in POC\n");
        ret = 0;
    } else {
        usage(argv[0]);
        ret = 1;
    }

    if (ret == 0 && strcmp(cmd, "run") == 0) {
        signal(SIGINT, sig_handler);
        signal(SIGTERM, sig_handler);
        fprintf(stderr, "ebpf-livepatch: running, press Ctrl+C to stop\n");
        while (running)
            sleep(1);
        fprintf(stderr, "ebpf-livepatch: shutting down\n");
    }

    return ret;
}
