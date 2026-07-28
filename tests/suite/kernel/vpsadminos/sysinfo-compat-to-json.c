#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysinfo.h>

static unsigned long long to_bytes(unsigned long value, unsigned int unit)
{
	return (unsigned long long)value * unit;
}

int main(void)
{
	struct sysinfo info;

	if (sysinfo(&info) != 0) {
		fprintf(stderr, "sysinfo: %s\n", strerror(errno));
		return 1;
	}

	printf("{"
	       "\"word_bits\":%zu,"
	       "\"loads_raw\":[%lu,%lu,%lu],"
	       "\"bufferram\":%llu,"
	       "\"totalswap\":%llu,"
	       "\"freeswap\":%llu,"
	       "\"mem_unit\":%u"
	       "}\n",
	       sizeof(unsigned long) * 8,
	       info.loads[0], info.loads[1], info.loads[2],
	       to_bytes(info.bufferram, info.mem_unit),
	       to_bytes(info.totalswap, info.mem_unit),
	       to_bytes(info.freeswap, info.mem_unit),
	       info.mem_unit);

	return 0;
}
