/*
 * ebpf-livepatch-loader.c - Userspace loader for BPF livepatch programs.
 *
 * Loads and attaches BPF programs using libbpf skeletons.
 *
 * load <name>  - Load, attach, exit (programs detach on exit, for testing)
 * run  <name>  - Load, attach, sleep (programs persist, for runit service)
 * unload       - No-op placeholder (programs detach when loader exits)
 */
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>

struct ebpf_program {
  const char *name;
  int (*load_and_attach)(void);
};

#include "enabled_programs.h"

static volatile sig_atomic_t running = 1;

static void sig_handler(int sig)
{
  running = 0;
}

static void usage(const char *progname)
{
  size_t i;

  fprintf(stderr, "Usage: %s <load|run|unload> <program-name|all>\n", progname);
  fprintf(stderr, "  load <name>   Load and attach programs (detach on exit)\n");
  fprintf(stderr, "  run  <name>   Load, attach, wait forever (for runit)\n");
  fprintf(stderr, "  unload        Detach by killing the 'run' process\n");
  fprintf(stderr, "\nAvailable:");

  for (i = 0; i < ebpf_program_count; i++)
    fprintf(stderr, " %s", ebpf_programs[i].name);

  fprintf(stderr, "\n");
}

static int load_programs(const char *prog)
{
  int all = strcmp(prog, "all") == 0;
  int matched = all;
  int ret = 0;
  size_t i;

  for (i = 0; i < ebpf_program_count; i++) {
    if (!all && strcmp(prog, ebpf_programs[i].name) != 0)
      continue;

    matched = 1;

    if (ebpf_programs[i].load_and_attach() != 0)
      ret = 1;
  }

  if (!matched) {
    fprintf(stderr, "ebpf-livepatch: unknown program '%s'\n", prog);
    ret = 1;
  }

  return ret;
}

int main(int argc, char **argv)
{
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
    ret = load_programs(prog);

    if (ret)
      usage(argv[0]);

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
