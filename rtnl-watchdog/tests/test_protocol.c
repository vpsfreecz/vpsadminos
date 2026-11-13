/* SPDX-License-Identifier: GPL-2.0 */
#include "protocol.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
struct response { struct nlmsghdr header; struct nlmsgerr error; struct ifinfomsg interface; };
int main(void)
{
  struct wd_request request; wd_request_init(&request, 123, 456);
  struct ifinfomsg empty = {0};
  assert(request.header.nlmsg_len == sizeof(request) && request.header.nlmsg_type == RTM_GETLINK);
  assert(request.header.nlmsg_flags == NLM_F_REQUEST && request.header.nlmsg_seq == 123 && request.header.nlmsg_pid == 456);
  assert(!memcmp(&request.interface, &empty, sizeof(empty)));
  struct sockaddr_nl sender = { .nl_family = AF_NETLINK };
  struct response valid = { .header = { .nlmsg_len = sizeof(struct response), .nlmsg_type = NLMSG_ERROR, .nlmsg_seq = 123 },
    .error = { .error = -EINVAL, .msg = request.header } };
#define CHECK(r, length, addr, addrlen, flags) wd_reply(&(r), length, &(addr), addrlen, flags, &request)
  assert(CHECK(valid, sizeof(valid), sender, sizeof(sender), 0) == WD_OK);
  /* Parsing must also tolerate an unaligned buffer without undefined reads. */
  unsigned char unaligned[sizeof(valid) + 1]; memcpy(unaligned + 1, &valid, sizeof(valid));
  assert(wd_reply(unaligned + 1, sizeof(valid), &sender, sizeof(sender), 0, &request) == WD_OK);
  assert(CHECK(valid, sizeof(valid) - 1, sender, sizeof(sender), 0) == WD_REPLY);
  assert(CHECK(valid, sizeof(valid), sender, sizeof(sender), MSG_TRUNC) == WD_REPLY);
  assert(CHECK(valid, sizeof(valid), sender, 0, 0) == WD_REPLY);
  struct sockaddr_nl other = sender; other.nl_pid = 2;
  assert(CHECK(valid, sizeof(valid), other, sizeof(other), 0) == WD_REPLY);
  other = sender; other.nl_groups = 1;
  assert(CHECK(valid, sizeof(valid), other, sizeof(other), 0) == WD_REPLY);
  struct response bad = valid; bad.header.nlmsg_seq++;
  assert(CHECK(bad, sizeof(bad), sender, sizeof(sender), 0) == WD_REPLY);
  bad = valid; bad.header.nlmsg_type = RTM_NEWLINK;
  assert(CHECK(bad, sizeof(bad), sender, sizeof(sender), 0) == WD_REPLY);
  bad = valid; bad.error.msg.nlmsg_seq++;
  assert(CHECK(bad, sizeof(bad), sender, sizeof(sender), 0) == WD_REPLY);
  bad = valid; bad.error.msg.nlmsg_type = RTM_NEWLINK;
  assert(CHECK(bad, sizeof(bad), sender, sizeof(sender), 0) == WD_REPLY);
  bad = valid; bad.error.msg.nlmsg_flags |= NLM_F_DUMP;
  assert(CHECK(bad, sizeof(bad), sender, sizeof(sender), 0) == WD_REPLY);
  bad = valid; bad.error.error = 0;
  assert(CHECK(bad, sizeof(bad), sender, sizeof(sender), 0) == WD_REPLY);
  bad = valid; bad.error.error = -EPERM;
  assert(CHECK(bad, sizeof(bad), sender, sizeof(sender), 0) == WD_REPLY);
  bad = valid; bad.header.nlmsg_len = 1;
  assert(CHECK(bad, sizeof(bad), sender, sizeof(sender), 0) == WD_REPLY);
  puts("netlink wire/protocol tests passed; no socket or send performed");
  return 0;
}
