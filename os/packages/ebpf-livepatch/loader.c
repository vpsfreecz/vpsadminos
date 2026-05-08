/*
 * ebpf-livepatch-loader.c - Userspace loader for BPF livepatch programs.
 *
 * Loads and attaches BPF programs using libbpf skeletons.
 *
 * load <name>  - Load, attach, exit (programs detach on exit, for testing)
 * run  <name>  - Load, attach, sleep (programs persist, for runit service)
 * unload       - No-op placeholder (programs detach when loader exits)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>

#include "override_uname.skel.h"
#include "lsm_example.skel.h"

static volatile sig_atomic_t running = 1;

static void sig_handler(int sig) {
    running = 0;
}

static int load_and_attach_override_uname(void) {
    struct override_uname_bpf *skel;
    int err;

    skel = override_uname_bpf__open_and_load();
    if (!skel) {
        fprintf(stderr, "ebpf-livepatch: failed to open/load override_uname\n");
        return -1;
    }

    err = override_uname_bpf__attach(skel);
    if (err < 0) {
        fprintf(stderr, "ebpf-livepatch: failed to attach override_uname: %d\n", err);
        override_uname_bpf__destroy(skel);
        return -1;
    }

    fprintf(stderr, "ebpf-livepatch: override_uname loaded and attached\n");
    /* Don't destroy - keep alive if caller needs persistence. */
    return 0;
}

static int load_and_attach_lsm_example(void) {
    struct lsm_example_bpf *skel;
    int err;

    skel = lsm_example_bpf__open_and_load();
    if (!skel) {
        fprintf(stderr, "ebpf-livepatch: failed to open/load lsm_example\n");
        return -1;
    }

    err = lsm_example_bpf__attach(skel);
    if (err < 0) {
        fprintf(stderr, "ebpf-livepatch: failed to attach lsm_example: %d\n", err);
        lsm_example_bpf__destroy(skel);
        return -1;
    }

    fprintf(stderr, "ebpf-livepatch: lsm_example loaded and attached\n");
    return 0;
}

static void usage(const char *progname) {
    fprintf(stderr, "Usage: %s <load|run|unload> <program-name|all>\n", progname);
    fprintf(stderr, "  load <name>   Load and attach programs (detach on exit)\n");
    fprintf(stderr, "  run  <name>   Load, attach, wait forever (for runit)\n");
    fprintf(stderr, "  unload        Detach by killing the 'run' process\n");
    fprintf(stderr, "\nAvailable: override_uname, lsm_example\n");
}

int main(int argc, char **argv) {
    const char *cmd, *prog;
    int ret = 0;

    if (argc < 2) {
        usage(argv[0]);
        return 1;
    }

    cmd = argv[1];
    prog = argc >= 3 ? argv[2] : "all";

    libbpf_set_strict_mode(LIBBPF_STRICT_ALL);
    libbpf_set_print(NULL);

    if (strcmp(cmd, "load") == 0 || strcmp(cmd, "run") == 0) {
        if (strcmp(prog, "all") == 0 || strcmp(prog, "override_uname") == 0)
            if (load_and_attach_override_uname() != 0)
                ret = 1;

        if (strcmp(prog, "all") == 0 || strcmp(prog, "lsm_example") == 0)
            if (load_and_attach_lsm_example() != 0)
                ret = 1;
    } else if (strcmp(cmd, "unload") == 0) {
        fprintf(stderr, "ebpf-livepatch: kill the 'run' process to detach programs\n");
    } else {
        usage(argv[0]);
        ret = 1;
    }

    if (ret == 0 && strcmp(cmd, "run") == 0) {
        signal(SIGINT, sig_handler);
        signal(SIGTERM, sig_handler);
        fprintf(stderr, "ebpf-livepatch: running (Ctrl+C to stop)\n");
        while (running)
            sleep(1);
        fprintf(stderr, "ebpf-livepatch: shutting down, programs detached\n");
    }

    return ret;
}
