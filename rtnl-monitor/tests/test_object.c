/* SPDX-License-Identifier: GPL-2.0 */
#include "core.h"
#include <bpf/libbpf.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

static struct bpf_object *open_object(const char *path)
{
  struct bpf_object *object = bpf_object__open_file(path, NULL);
  assert(object && !libbpf_get_error(object));
  return object;
}
static void configured_object(const char *path, unsigned pending, unsigned roots, bool stacks)
{
  struct config cfg; config_defaults(&cfg); cfg.max_pending = pending; cfg.max_roots = roots;
  struct bpf_object *object = open_object(path);
  /* This is the real production boundary, deliberately before load/attach. */
  assert(!object_configure(object, &cfg, stacks));
  struct bpf_map *map = bpf_object__find_map_by_name(object, "pending");
  assert(bpf_map__max_entries(map) == pending && bpf_map__fd(map) == -1);
  map = bpf_object__find_map_by_name(object, "root_template");
  assert(bpf_map__max_entries(map) == MONITOR_ROOT_MAP_ENTRIES && bpf_map__fd(map) == -1);
  map = bpf_object__find_map_by_name(object, "root_sets");
  assert(bpf_map__max_entries(bpf_map__inner_map(map)) == MONITOR_ROOT_MAP_ENTRIES);
  map = bpf_object__find_map_by_name(object, "stacks");
  assert(bpf_map__max_entries(map) == MONITOR_STACKS);
  assert(bpf_map__value_size(map) == MONITOR_STACK_DEPTH * sizeof(uint64_t));
  bool found = false;
  bpf_object__for_each_map(map, object) {
    if (!strstr(bpf_map__name(map), ".rodata")) continue;
    size_t len; const struct monitor_rodata *options = bpf_map__initial_value(map, &len);
    assert(options && len == sizeof(*options) && options->stacks_enabled == stacks); found = true;
  }
  assert(found);
  struct bpf_program *program;
  bpf_object__for_each_program(program, object) assert(bpf_program__fd(program) < 0);
  bpf_object__close(object);
}
static void invalid_shapes(const char *path)
{
  struct config cfg; config_defaults(&cfg);
  assert(object_configure(NULL, &cfg, false) < 0);
  struct bpf_object *object = open_object(path);
  struct bpf_map *map = bpf_object__find_map_by_name(object, "root_template");
  /* Mutating an ordinary object-owned map is safe; disagreement with the
   * fixed inner template must fail visibly rather than reaching kernel load. */
  assert(!bpf_map__set_max_entries(map, MONITOR_ROOT_MAP_ENTRIES - 1));
  assert(object_configure(object, &cfg, false) < 0);
  bpf_object__close(object);
  object = open_object(path); map = bpf_object__find_map_by_name(object, "pending");
  assert(!bpf_map__set_key_size(map, sizeof(uint32_t)));
  assert(object_configure(object, &cfg, false) < 0);
  bpf_object__close(object);
}
int main(int argc, char **argv)
{
  assert(argc > 1);
  for (int i = 1; i < argc; i++) {
    configured_object(argv[i], 4096, 1024, true);
    configured_object(argv[i], 1, 1, false);
    configured_object(argv[i], 2, 2, true);
    configured_object(argv[i], MONITOR_PENDING_LIMIT, MONITOR_ROOTS_LIMIT, false);
    invalid_shapes(argv[i]);
  }
  puts("actual-object open/configuration tests passed; no kernel load/attach");
  return 0;
}
