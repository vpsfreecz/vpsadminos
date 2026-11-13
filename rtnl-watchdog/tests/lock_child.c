/* SPDX-License-Identifier: GPL-2.0 */
/* Test-only exec target: no netlink or watchdog healthy-response backend. */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <unistd.h>
int main(void)
{
  struct stat st;
  if (fstat(3, &st) || !S_ISREG(st.st_mode) || fcntl(10, F_GETFD) >= 0 || errno != EBADF) return 1;
  if (write(4, "A", 1) != 1) return 2;
  char command;
  if (read(4, &command, 1) != 1) return 0;
  if (command == 'H') {
    if (write(4, "B", 1) != 1) return 3;
    poll(NULL, 0, 1000); /* Bounded outstanding-call seam across parent death. */
  }
  return 0;
}
