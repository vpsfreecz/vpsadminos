#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysinfo.h>

int main(void)
{
  struct sysinfo info;
  unsigned long long unit;

  if (sysinfo(&info) < 0) {
    fprintf(stderr, "sysinfo: %s\n", strerror(errno));
    return 1;
  }

  unit = info.mem_unit;
  printf("{\"totalram\":%llu,\"freeram\":%llu,"
         "\"totalswap\":%llu,\"freeswap\":%llu,\"procs\":%u}\n",
         info.totalram * unit, info.freeram * unit,
         info.totalswap * unit, info.freeswap * unit,
         (unsigned int)info.procs);
  return 0;
}
