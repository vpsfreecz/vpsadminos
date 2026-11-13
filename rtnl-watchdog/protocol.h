/* SPDX-License-Identifier: GPL-2.0 */
#ifndef RTNL_WATCHDOG_PROTOCOL_H
#define RTNL_WATCHDOG_PROTOCOL_H
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <stdint.h>
#include <sys/socket.h>
#include <stddef.h>
enum wd_error {
  WD_OK, WD_NAMESPACE, WD_SOCKET, WD_SEND, WD_RECEIVE, WD_REPLY, WD_IPC, WD_CHILD,
  WD_ERROR_COUNT
};
struct wd_request { struct nlmsghdr header; struct ifinfomsg interface; };
_Static_assert(sizeof(struct wd_request) == NLMSG_LENGTH(sizeof(struct ifinfomsg)), "request wire size");
void wd_request_init(struct wd_request *request, uint32_t sequence, uint32_t port);
int wd_reply(const void *data, size_t size, const struct sockaddr_nl *sender,
  socklen_t address_size, int flags, const struct wd_request *request);
#endif
