/* SPDX-License-Identifier: GPL-2.0 */
#define _GNU_SOURCE
#include "core.h"
#include <errno.h>
#include <fcntl.h>
#include <linux/magic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <unistd.h>

static int invalid(struct roots *r, const char *why)
{
  r->valid = false;
  snprintf(r->error, sizeof(r->error), "%s", why);
  return -1;
}
static bool string_field(struct json_object *obj, const char *key, char *dst, size_t cap)
{
  struct json_object *v;
  if (!json_object_object_get_ex(obj, key, &v) || !json_object_is_type(v, json_type_string)) return false;
  size_t n = json_object_get_string_len(v);
  if (!n || n >= cap || strlen(json_object_get_string(v)) != n) return false;
  memcpy(dst, json_object_get_string(v), n + 1);
  for (size_t i = 0; i < n; i++) if ((unsigned char)dst[i] < 32 || (unsigned char)dst[i] == 127) return false;
  return true;
}
static bool relative_path(const char *path)
{
  if (!*path || *path == '/') return false;
  const char *p = path;
  for (;;) {
    const char *end = strchr(p, '/');
    size_t n = end ? (size_t)(end - p) : strlen(p);
    if (!n || (n == 1 && p[0] == '.') || (n == 2 && p[0] == '.' && p[1] == '.')) return false;
    if (!end) return true;
    p = end + 1;
  }
}
static bool overlaps(const char *a, const char *b)
{
  size_t n = strlen(a);
  return !strncmp(a, b, n) && (b[n] == 0 || b[n] == '/');
}
int roots_parse(const char *data, size_t len, const struct config *cfg, struct roots *out)
{
  memset(out, 0, sizeof(*out));
  if (!len || len > ROOT_JSON_LIMIT) return invalid(out, "roots JSON size exceeds its bound");
  struct json_tokener *tok = json_tokener_new_ex(16);
  if (!tok) return invalid(out, "roots parser allocation failed");
  json_tokener_set_flags(tok, JSON_TOKENER_STRICT);
  struct json_object *obj = json_tokener_parse_ex(tok, data, (int)len), *v, *roots;
  bool good = json_tokener_get_error(tok) == json_tokener_success;
  size_t used = json_tokener_get_parse_end(tok);
  for (size_t i = used; i < len; i++) if (data[i] != ' ' && data[i] != '\n' && data[i] != '\r' && data[i] != '\t') good = false;
  json_tokener_free(tok);
  if (!good || !obj || !json_object_is_type(obj, json_type_object)) { if (obj) json_object_put(obj); return invalid(out, "invalid roots JSON"); }
#define REQUIRE(expr, why) do { if (!(expr)) { json_object_put(obj); return invalid(out, why); } } while (0)
  REQUIRE(json_object_object_get_ex(obj, "schema", &v) && json_object_is_type(v, json_type_int) && json_object_get_int64(v) == 1, "unsupported roots schema");
  REQUIRE(json_object_object_get_ex(obj, "generated_monotonic_ns", &v) && json_object_is_type(v, json_type_int) && json_object_get_int64(v) > 0, "invalid mapping timestamp");
  out->generated_ns = json_object_get_uint64(v);
  REQUIRE(string_field(obj, "cgroup_mount", out->mount, sizeof(out->mount)) && out->mount[0] == '/', "invalid cgroup mount");
  REQUIRE(json_object_object_get_ex(obj, "roots", &roots) && json_object_is_type(roots, json_type_array), "missing roots array");
  size_t count = json_object_array_length(roots);
  REQUIRE(count <= cfg->max_roots && count <= MONITOR_ROOTS_LIMIT, "root capacity exceeded");
  unsigned levels[MONITOR_LEVELS] = {0}; size_t level_count = 0;
  for (size_t i = 0; i < count; i++) {
    struct root *r = &out->roots[i]; struct json_object *o = json_object_array_get_idx(roots, i);
    REQUIRE(json_object_is_type(o, json_type_object) && string_field(o, "pool", r->pool, sizeof(r->pool)) &&
      string_field(o, "id", r->id, sizeof(r->id)) && string_field(o, "path", r->path, sizeof(r->path)) &&
      string_field(o, "run_token", r->run, sizeof(r->run)), "invalid root fields");
    REQUIRE(!strchr(r->pool, '/') && !strchr(r->id, '/') && relative_path(r->path), "invalid root identity or escaping path");
    r->level = 1;
    for (const char *s = r->path; *s; s++) if (*s == '/') r->level++;
    REQUIRE(r->level <= 255, "ancestor level exceeds helper bound");
    bool seen = false;
    for (size_t j = 0; j < level_count; j++) if (levels[j] == r->level) seen = true;
    if (!seen) { REQUIRE(level_count < MONITOR_LEVELS, "too many ancestor levels"); levels[level_count++] = r->level; }
    for (size_t j = 0; j < i; j++) {
      struct root *p = &out->roots[j];
      REQUIRE(strcmp(p->pool, r->pool) || strcmp(p->id, r->id), "duplicate VPS identity");
      REQUIRE(!overlaps(p->path, r->path) && !overlaps(r->path, p->path), "duplicate or overlapping roots");
    }
  }
  out->count = count; out->valid = true;
  json_object_put(obj);
#undef REQUIRE
  return 0;
}
static int handle_id(int fd, uint64_t *id, int *mount_id)
{
  union { struct file_handle align; unsigned char data[sizeof(struct file_handle) + 8]; } storage;
  memset(&storage, 0, sizeof(storage));
  struct file_handle *h = (void *)&storage;
  h->handle_bytes = 8;
  if (name_to_handle_at(fd, "", h, mount_id, AT_EMPTY_PATH) || h->handle_bytes != 8) return -1;
  memcpy(id, h->f_handle, 8);
  return *id ? 0 : -1;
}
static int path_fd(int root, const char *path)
{
  char copy[PATH_MAX]; snprintf(copy, sizeof(copy), "%s", path);
  int fd = dup(root); char *save = NULL;
  for (char *part = strtok_r(copy, "/", &save); part && fd >= 0; part = strtok_r(NULL, "/", &save)) {
    int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    close(fd); fd = next;
  }
  return fd;
}
static bool hierarchy_mount(int mount_id, uint64_t root_id)
{
  FILE *f = fopen("/proc/self/mountinfo", "re");
  if (!f) return false;
  char *line = NULL; size_t n = 0; bool valid = false;
  while (getline(&line, &n, f) >= 0) {
    int id; char root[PATH_MAX], mount[PATH_MAX];
    if (sscanf(line, "%d %*d %*s %4095s %4095s", &id, root, mount) == 3 && id == mount_id) {
      if (strcmp(root, "/") || !strstr(line, " - cgroup2 ")) break;
      /* mountinfo escapes whitespace/backslashes as octal. Verify the selected
       * directory is the actual mount root, not just on its filesystem. */
      char *dst = mount;
      for (const char *src = mount; *src; src++) {
        if (*src == '\\' && src[1] >= '0' && src[1] <= '7' && src[2] >= '0' && src[2] <= '7' && src[3] >= '0' && src[3] <= '7') {
          *dst++ = (char)((src[1] - '0') * 64 + (src[2] - '0') * 8 + src[3] - '0'); src += 3;
        } else *dst++ = *src;
      }
      *dst = 0;
      int fd = open(mount, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), selected_mount;
      uint64_t selected_id;
      valid = fd >= 0 && !handle_id(fd, &selected_id, &selected_mount) && selected_mount == mount_id && selected_id == root_id;
      if (fd >= 0) close(fd);
      break;
    }
  }
  free(line); fclose(f); return valid;
}
int roots_resolve(struct roots *r, char *mount_path, size_t mount_len)
{
  int fd = open(r->mount, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  struct statfs fs; int mount_id; uint64_t id;
  if (fd < 0) return invalid(r, "cannot open cgroup mount");
  if (fstatfs(fd, &fs) || fs.f_type != CGROUP2_SUPER_MAGIC || handle_id(fd, &id, &mount_id) || !hierarchy_mount(mount_id, id)) {
    close(fd); return invalid(r, "mount must be a supported cgroup-v2 hierarchy root with an 8-byte handle");
  }
  for (size_t i = 0; i < r->count; i++) {
    int child = path_fd(fd, r->roots[i].path), child_mount;
    if (child < 0) { close(fd); return invalid(r, "root disappeared or path is a symlink"); }
    bool ok = !fstatfs(child, &fs) && fs.f_type == CGROUP2_SUPER_MAGIC &&
      !handle_id(child, &r->roots[i].cgid, &child_mount) && child_mount == mount_id;
    close(child);
    if (!ok) { close(fd); return invalid(r, "root handle or filesystem mismatch"); }
    for (size_t j = 0; j < i; j++) if (r->roots[j].cgid == r->roots[i].cgid) {
      close(fd); return invalid(r, "duplicate cgroup handle");
    }
  }
  close(fd); snprintf(mount_path, mount_len, "%s", r->mount); return 0;
}
void roots_tokens(struct roots *next, const struct roots *old, uint64_t *serial)
{
  for (size_t i = 0; i < next->count; i++) {
    struct root *n = &next->roots[i];
    n->token = 0;
    for (size_t j = 0; j < old->count; j++) {
      const struct root *p = &old->roots[j];
      if (n->cgid == p->cgid && !strcmp(n->pool, p->pool) && !strcmp(n->id, p->id) &&
          !strcmp(n->path, p->path) && !strcmp(n->run, p->run)) { n->token = p->token; break; }
    }
    if (!n->token) n->token = ++*serial;
  }
}

/* Stable across run/root replacement. Hash collisions only suppress diagnostics. */
uint64_t root_sampling_key(const struct root *root)
{
  uint64_t hash = 14695981039346656037ULL;
  const char *parts[] = { root->pool, root->id };
  for (unsigned i = 0; i < 2; i++) {
    const unsigned char *p = (const unsigned char *)parts[i];
    do { hash ^= *p; hash *= 1099511628211ULL; } while (*p++);
  }
  return hash ? hash : 1;
}
