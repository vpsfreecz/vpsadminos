/* SPDX-License-Identifier: GPL-2.0 */
#include "core.h"
#include <bpf/libbpf.h>
#include <string.h>

static bool root_shape(const struct bpf_map *map)
{
  return map && bpf_map__type(map) == BPF_MAP_TYPE_HASH &&
    bpf_map__key_size(map) == sizeof(struct root_key) &&
    bpf_map__value_size(map) == sizeof(struct root_value) &&
    bpf_map__max_entries(map) == MONITOR_ROOT_MAP_ENTRIES;
}
int object_configure(struct bpf_object *object, const struct config *cfg, bool stacks)
{
  if (!object) return -1;
  struct bpf_map *pending = bpf_object__find_map_by_name(object, "pending");
  struct bpf_map *roots = bpf_object__find_map_by_name(object, "root_template");
  struct bpf_map *outer = bpf_object__find_map_by_name(object, "root_sets");
  if (!outer || bpf_map__type(outer) != BPF_MAP_TYPE_ARRAY_OF_MAPS ||
      bpf_map__key_size(outer) != sizeof(uint32_t) || bpf_map__max_entries(outer) != 1) return -1;
  /* libbpf's inner BTF descriptor has no owning object. Its setters can
   * dereference NULL in libbpf 1.7; inspect it, never mutate it. Physical
   * capacity stays fixed for the template and every published generation.
   * --max-roots is enforced on inventory before publication. */
  if (!root_shape(roots) || !root_shape(bpf_map__inner_map(outer))) return -1;
  if (!pending || bpf_map__type(pending) != BPF_MAP_TYPE_HASH ||
      bpf_map__key_size(pending) != sizeof(uint64_t) ||
      bpf_map__value_size(pending) != sizeof(struct pending_call) ||
      bpf_map__set_max_entries(pending, cfg->max_pending)) return -1;
  bool found = false; struct bpf_map *map;
  bpf_object__for_each_map(map, object) {
    if (strstr(bpf_map__name(map), ".rodata")) {
      size_t len; const void *data = bpf_map__initial_value(map, &len);
      if (!data || len != sizeof(struct monitor_rodata)) return -1;
      struct monitor_rodata options = { .stacks_enabled = stacks };
      if (bpf_map__set_initial_value(map, &options, sizeof(options))) return -1;
      found = true;
    }
  }
  return found ? 0 : -1;
}
