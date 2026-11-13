/* SPDX-License-Identifier: GPL-2.0 */
#include "protocol.h"
#include <errno.h>
#include <string.h>

void wd_request_init(struct wd_request *request, uint32_t sequence, uint32_t port)
{
  memset(request, 0, sizeof(*request));
  request->header.nlmsg_len = sizeof(*request);
  request->header.nlmsg_type = RTM_GETLINK;
  request->header.nlmsg_flags = NLM_F_REQUEST;
  request->header.nlmsg_seq = sequence;
  request->header.nlmsg_pid = port;
  request->interface.ifi_family = AF_UNSPEC;
}
int wd_reply(const void *data, size_t size, const struct sockaddr_nl *sender,
  socklen_t address_size, int flags, const struct wd_request *request)
{
  if (!sender || address_size != sizeof(*sender) || sender->nl_family != AF_NETLINK ||
      sender->nl_pid != 0 || sender->nl_groups != 0 || flags & (MSG_TRUNC | MSG_CTRUNC) ||
      size < NLMSG_LENGTH(sizeof(struct nlmsgerr))) return WD_REPLY;
  struct nlmsghdr header; struct nlmsgerr error;
  memcpy(&header, data, sizeof(header));
  if (header.nlmsg_type != NLMSG_ERROR || header.nlmsg_seq != request->header.nlmsg_seq ||
      header.nlmsg_len < NLMSG_LENGTH(sizeof(error)) || header.nlmsg_len > size ||
      NLMSG_ALIGN(header.nlmsg_len) != size ||
      header.nlmsg_flags & ~(NLM_F_CAPPED | NLM_F_ACK_TLVS)) return WD_REPLY;
  memcpy(&error, (const char *)data + NLMSG_HDRLEN, sizeof(error));
  if (error.error != -EINVAL || error.msg.nlmsg_type != RTM_GETLINK ||
      error.msg.nlmsg_seq != request->header.nlmsg_seq ||
      error.msg.nlmsg_len != request->header.nlmsg_len ||
      error.msg.nlmsg_flags != NLM_F_REQUEST || error.msg.nlmsg_pid != request->header.nlmsg_pid) return WD_REPLY;
  return WD_OK;
}
