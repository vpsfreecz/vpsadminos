args@{ pkgs, ... }:

let
  nfqSource = pkgs.writeText "livepatch-nfq-accept.c" ''
    #include <arpa/inet.h>
    #include <errno.h>
    #include <linux/netfilter.h>
    #include <libnetfilter_queue/libnetfilter_queue.h>
    #include <stdint.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <sys/socket.h>
    #include <unistd.h>

    static unsigned int accepted;

    static int accept_packet(
      struct nfq_q_handle *queue,
      struct nfgenmsg *message,
      struct nfq_data *data,
      void *opaque
    ) {
      struct nfqnl_msg_packet_hdr *header = nfq_get_msg_packet_hdr(data);
      uint32_t id = header == NULL ? 0 : ntohl(header->packet_id);
      (void)message;
      (void)opaque;
      accepted++;
      return nfq_set_verdict(queue, id, NF_ACCEPT, 0, NULL);
    }

    int main(int argc, char **argv) {
      struct nfq_handle *handle;
      struct nfq_q_handle *queue;
      unsigned int queue_number;
      unsigned int limit;
      int fd;
      char buffer[65536] __attribute__((aligned));

      if (argc != 3)
        return 2;
      queue_number = (unsigned int)strtoul(argv[1], NULL, 10);
      limit = (unsigned int)strtoul(argv[2], NULL, 10);
      handle = nfq_open();
      if (handle == NULL)
        return 3;
      (void)nfq_unbind_pf(handle, AF_INET);
      if (nfq_bind_pf(handle, AF_INET) < 0)
        return 5;
      queue = nfq_create_queue(handle, (uint16_t)queue_number, accept_packet, NULL);
      if (queue == NULL)
        return 6;
      if (nfq_set_mode(queue, NFQNL_COPY_PACKET, 0xffff) < 0)
        return 7;
      fd = nfq_fd(handle);
      printf("ready\n");
      fflush(stdout);
      while (accepted < limit) {
        ssize_t length = recv(fd, buffer, sizeof(buffer), 0);
        if (length < 0) {
          if (errno == EINTR)
            continue;
          return 8;
        }
        if (nfq_handle_packet(handle, buffer, (int)length) < 0)
          return 9;
      }
      printf("accepted=%u\n", accepted);
      nfq_destroy_queue(queue);
      nfq_close(handle);
      return 0;
    }
  '';

  nfqAcceptor = pkgs.stdenv.mkDerivation {
    pname = "livepatch-nfq-accept";
    version = "1";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [
      pkgs.libmnl
      pkgs.libnfnetlink
      pkgs.libnetfilter_queue
    ];
    buildPhase = ''
      $CC -Wall -Wextra -Werror ${nfqSource} -o nfq-accept \
        $(pkg-config --cflags --libs libnetfilter_queue)
    '';
    installPhase = ''
      install -D -m 0755 nfq-accept $out/bin/nfq-accept
    '';
  };
in
import ./network-backlog-unregister-serialization.nix (
  args
  // {
    profile = {
      fixId = "skb-zerocopy-shared-frag";
      oracleId = "nfqueue-xfrm-operation-safety";
      toolName = "nfqueue-xfrm-operation";
      operationLabel = "NFQUEUE acceptance of ordinary XFRM traffic";
      kernelModules = [
        "esp4"
        "nf_conntrack"
        "nfnetlink_queue"
        "xfrm_user"
      ];
      extraPackages = [ nfqAcceptor ];
      cleanupFixture = ''
        ip netns del lp-xfrm-a >/dev/null 2>&1 || true
        ip netns del lp-xfrm-b >/dev/null 2>&1 || true
        rm -f "$state_dir/nfq.log"
      '';
      setupFixture = ''
              cleanup_fixture
              ip netns add lp-xfrm-a
              ip netns add lp-xfrm-b
              ip link add xfa0 type veth peer name xfb0
              ip link set xfa0 netns lp-xfrm-a
              ip link set xfb0 netns lp-xfrm-b
              ip -n lp-xfrm-a link set lo up
              ip -n lp-xfrm-b link set lo up
              ip -n lp-xfrm-a addr add 10.83.0.1/30 dev xfa0
              ip -n lp-xfrm-b addr add 10.83.0.2/30 dev xfb0
              ip -n lp-xfrm-a link set xfa0 up
              ip -n lp-xfrm-b link set xfb0 up
              ip -n lp-xfrm-a xfrm state add src 10.83.0.1 dst 10.83.0.2 \
                proto esp spi 0x100 mode transport \
                auth 'hmac(sha256)' 0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff \
                enc 'cbc(aes)' 0x00112233445566778899aabbccddeeff
              ip -n lp-xfrm-a xfrm policy add src 10.83.0.1 dst 10.83.0.2 dir out \
                tmpl src 10.83.0.1 dst 10.83.0.2 proto esp mode transport
              ip -n lp-xfrm-b xfrm state add src 10.83.0.1 dst 10.83.0.2 \
                proto esp spi 0x100 mode transport \
                auth 'hmac(sha256)' 0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff \
                enc 'cbc(aes)' 0x00112233445566778899aabbccddeeff
              ip -n lp-xfrm-b xfrm policy add src 10.83.0.1 dst 10.83.0.2 dir in \
                tmpl src 10.83.0.1 dst 10.83.0.2 proto esp mode transport
              ip netns exec lp-xfrm-b nft -f - <<'NFT'
        table inet lpq {
          chain input {
            type filter hook input priority 0; policy accept;
            ip protocol udp queue num 42
          }
        }
        NFT
      '';
      oneIteration = ''
              : > "$state_dir/nfq.log"
              ip netns exec lp-xfrm-b ${nfqAcceptor}/bin/nfq-accept 42 1 \
                > "$state_dir/nfq.log" 2>&1 &
              queue_pid=$!
              for _ in $(seq 1 100); do
                ! grep -Fx 'ready' "$state_dir/nfq.log" >/dev/null 2>&1 || break
                sleep 0.05
              done
              grep -Fx 'ready' "$state_dir/nfq.log" >/dev/null || fail "NFQUEUE listener did not become ready"
              ip netns exec lp-xfrm-a python3 - <<'PY'
        import socket
        sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sender.bind(("10.83.0.1", 0))
        sender.sendto(b"ordinary-nfqueue-xfrm-traffic" * 64, ("10.83.0.2", 25100))
        sender.close()
        PY
              timeout 10 tail --pid="$queue_pid" -f /dev/null
              wait "$queue_pid"
              grep -Fx 'accepted=1' "$state_dir/nfq.log" >/dev/null
      '';
    };
  }
)
