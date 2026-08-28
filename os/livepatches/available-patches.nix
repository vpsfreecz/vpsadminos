{
  lib,
  version ? null,
  ...
}:
with lib;

let

  availablePatches = [
    {
      name = "bp-6.12.95-cumulative";
      filterFn = availableFor "6.12.95";
      version = 7;
      autoLoad = false;
      contract = {
        anchor = {
          moduleName = "livepatch_6";
          functionCount = 204;
          inventoryId = {
            high = "0xe3cfa2e6f8aaa28eULL";
            low = "0x4a8aade1e48e06a0ULL";
          };
        };
        guard = {
          moduleName = "livepatch_transition_guard";
          functionCount = 6;
          inventoryId = {
            high = "0x3fa36db88927cf79ULL";
            low = "0x5754ae11e224339dULL";
          };
        };
        checkpointGuard = {
          moduleName = "lp7_checkpoint_guard";
          functionCount = 1;
          inventoryId = {
            high = "0x1ULL";
            low = "0x1ULL";
          };
        };
        reverseGuard = {
          moduleName = "lp7_reverse_guard";
          functionCount = 1;
          inventoryId = {
            high = "0x1ULL";
            low = "0x1ULL";
          };
        };
        foundation = {
          moduleName = "lp61295_foundation";
          functionCount = 11;
          inventoryId = {
            high = "0x990643c95072c2c1ULL";
            low = "0xcdb753719b7f7b9fULL";
          };
        };
        final = {
          moduleName = "lp7_sctp_correct";
          functionCount = 4;
          inventoryId = {
            high = "0xb004f0281bdcc99dULL";
            low = "0xda6e93443e222b83ULL";
          };
        };
        checkpoint = {
          moduleName = "livepatch_7";
          functionCount = 1;
          inventoryId = {
            high = "0x1ULL";
            low = "0x1ULL";
          };
        };
      };
      anchors = {
        v6Remediation = {
          class = "remediation";
          bootKernelVersion = "6.12.95";
          publishedIdentity = "6.12.95.6";
          moduleName = "livepatch_6";
          moduleFile =
            "/nix/store/ncq9v28a2ddp4875mbw5ql7hr6rkyh0w-livepatch_6-6.12.95/"
            + "lib/modules/6.12.95/extra/livepatch_6.ko";
          moduleSha256 = "960b13f1b461b95e29cccff58ddf0d3f3badf151046eb46eba36a9c8c7e5efe3";
          moduleBuildId = "568e29221e0fa98cfec22ab8cf17a280e6db330e";
          replace = true;
          replacementCount = 204;
          isolationMarker = "/run/vpsadminos/livepatches/v6-remediation-isolated";
          allowedBootBzImageSha256 = [
            "244ec9f7277617885cce47c564210f560ec9e6cfcdbfaf503626a2236f1b911e"
            "58390aa25aae9d8b3c313ebcb60b7a1bef30fae4759f704a7c2baacff6e9e29f"
            "3d208a0208a6d45ce9bc25a69fa9a29515c0f89fd9e6e9f6aef80ffe94872ee3"
          ];
          allowedSystemMapSha256 = [
            "38fdabb177fcfd9ca11e52d2a118a55347192ecf446428ceeead1ea384412be9"
          ];
          path = "v7Corrective";
        };
        cleanBoot = {
          class = "supported";
          bootKernelVersion = "6.12.95";
          publishedIdentity = "6.12.95";
          allowedBootBzImageSha256 = [
            "244ec9f7277617885cce47c564210f560ec9e6cfcdbfaf503626a2236f1b911e"
            "58390aa25aae9d8b3c313ebcb60b7a1bef30fae4759f704a7c2baacff6e9e29f"
            "3d208a0208a6d45ce9bc25a69fa9a29515c0f89fd9e6e9f6aef80ffe94872ee3"
          ];
          allowedSystemMapSha256 = [
            "38fdabb177fcfd9ca11e52d2a118a55347192ecf446428ceeead1ea384412be9"
          ];
          path = "v7CheckpointBootstrap";
        };
        checkpointComplete = {
          class = "supported";
          bootKernelVersion = "6.12.95";
          publishedIdentity = "6.12.95.7";
          moduleName = "livepatch_7";
          path = "v7ReverseValidation";
        };
      };
      paths.v7Corrective = [
        {
          role = "bootstrap-guard";
          moduleName = "livepatch_transition_guard";
          buildPatches = [
            "bp-6.12.95-v7-headers"
            "bp-6.12.95-v7-transition-common"
          ];
          targets = [ "vmlinux" ];
          nonReplace = true;
          expectedSha256 = "14971b88daa0fa3a6a91058fb486e7f84a4b02a29c3017b2e19890d80c04c563";
          bootstrap = {
            moduleName = "livepatch_transition_bootstrap";
            sourceDir = "transition-bootstrap";
            kickParameter = "kick_idle";
            expectedSha256 = "5883b23743b5194fd5094e73912009ce67d84d414f4f725e082ac54733bdbc5f";
          };
        }
        {
          role = "foundation";
          moduleName = "lp61295_foundation";
          buildPatches = [
            "bp-6.12.95-v7-headers"
            "bp-6.12.95-v7-transition-common"
          ];
          targets = [ "vmlinux" ];
          nonReplace = true;
          expectedSha256 = "4dc14a6a8675e1ea37e17169237b482d32b87dd005f540b0a81793bd5be0db08";
          foundationState = {
            id = "0x6129500000000001";
            version = 1;
          };
        }
        {
          role = "generation-final";
          moduleName = "lp7_sctp_correct";
          buildPatches = [
            "bp-6.12.95-v7-headers"
            "bp-6.12.95-v7-sctp-corrective"
            "bp-6.12.95-v7-generation"
          ];
          # kpatch-build groups these .ko targets into one modpost pass. Include
          # direct module dependencies so modpost sees their exported symbols.
          targets = [
            "vmlinux"
            "lib/libcrc32c.ko"
            "net/ipv4/udp_tunnel.ko"
            "net/ipv6/ip6_udp_tunnel.ko"
            "net/sctp/sctp.ko"
          ];
          nonReplace = true;
          expectedSha256 = "eef6bba12a15262cd352e6b2dcffd0fae8914520bb339ecb7090cac14b31b659";
          coverageState = {
            id = "0x6129500000000002";
            version = 7;
            complete = true;
          };
          publishedIdentity = "6.12.95.7";
        }
      ];
      paths.v7CheckpointBootstrap = [
        {
          role = "checkpoint-guard";
          moduleName = "lp7_checkpoint_guard";
          buildPatches = [
            "bp-6.12.95-v7-headers"
            "bp-6.12.95-v7-transition-common"
          ];
          targets = [ "vmlinux" ];
          nonReplace = true;
          expectedSha256 = null;
          bootstrap = {
            moduleName = "livepatch_transition_bootstrap";
            sourceDir = "transition-bootstrap";
            kickParameter = "kick_idle";
            expectedSha256 = "5883b23743b5194fd5094e73912009ce67d84d414f4f725e082ac54733bdbc5f";
          };
        }
      ];
      paths.v7ReverseValidation = [
        {
          role = "reverse-guard";
          moduleName = "lp7_reverse_guard";
          buildPatches = [
            "bp-6.12.95-v7-headers"
            "bp-6.12.95-v7-transition-common"
          ];
          targets = [ "vmlinux" ];
          nonReplace = true;
          expectedSha256 = null;
          bootstrap = {
            moduleName = "livepatch_transition_bootstrap";
            sourceDir = "transition-bootstrap";
            kickParameter = "kick_idle";
            expectedSha256 = "5883b23743b5194fd5094e73912009ce67d84d414f4f725e082ac54733bdbc5f";
          };
        }
      ];
      checkpoint = {
        role = "checkpoint";
        moduleName = "livepatch_7";
        buildPatches = [
          "bp-6.12.95-cumulative-v7"
        ];
        expectedSha256 = null;
        nonReplace = false;
        publishedIdentity = "6.12.95.7";
        foundationState = {
          id = "0x6129500000000001";
          version = 1;
        };
        coverageState = {
          id = "0x6129500000000002";
          version = 7;
          complete = true;
        };
        # kpatch-build groups these .ko targets into one modpost pass. Include
        # direct module dependencies so modpost sees their exported symbols.
        targets = [
        "vmlinux"
        "fs/fuse/fuse.ko"
        "net/dns_resolver/dns_resolver.ko"
        "fs/nfs/nfsv4.ko"
        "net/llc/llc.ko"
        "net/802/stp.ko"
        "net/bridge/bridge.ko"
        "net/bridge/br_netfilter.ko"
        "net/netfilter/nfnetlink.ko"
        "net/netfilter/ipset/ip_set.ko"
        "net/netfilter/ipset/ip_set_hash_ip.ko"
        "net/netfilter/ipset/ip_set_hash_ipmac.ko"
        "net/netfilter/ipset/ip_set_hash_ipmark.ko"
        "net/netfilter/ipset/ip_set_hash_ipport.ko"
        "net/netfilter/ipset/ip_set_hash_ipportip.ko"
        "net/netfilter/ipset/ip_set_hash_ipportnet.ko"
        "net/netfilter/ipset/ip_set_hash_mac.ko"
        "net/netfilter/ipset/ip_set_hash_net.ko"
        "net/netfilter/ipset/ip_set_hash_netiface.ko"
        "net/netfilter/ipset/ip_set_hash_netnet.ko"
        "net/netfilter/ipset/ip_set_hash_netport.ko"
        "net/netfilter/ipset/ip_set_hash_netportnet.ko"
        "lib/libcrc32c.ko"
        "net/ipv4/netfilter/nf_defrag_ipv4.ko"
        "net/ipv4/inet_diag.ko"
        "net/ipv6/netfilter/nf_defrag_ipv6.ko"
        "net/netfilter/nf_conntrack.ko"
        "net/netfilter/nf_nat.ko"
        "net/netfilter/nf_conntrack_sip.ko"
        "net/netfilter/nf_nat_sip.ko"
        "net/netfilter/ipvs/ip_vs.ko"
        "net/netfilter/nf_tables.ko"
        "net/netfilter/nfnetlink_queue.ko"
        "drivers/net/slip/slhc.ko"
        "drivers/net/ppp/ppp_generic.ko"
        "net/ipv4/udp_tunnel.ko"
        "net/ipv6/ip6_udp_tunnel.ko"
        "drivers/net/vxlan/vxlan.ko"
        "net/packet/af_packet.ko"
        "net/sctp/sctp.ko"
        "net/sctp/sctp_diag.ko"
        "fs/ceph/ceph.ko"
        "net/ceph/libceph.ko"
        "crypto/sha1_generic.ko"
        "drivers/base/firmware_loader/firmware_class.ko"
        "drivers/crypto/ccp/ccp.ko"
        "virt/lib/irqbypass.ko"
        "arch/x86/kvm/kvm.ko"
        "arch/x86/kvm/kvm-intel.ko"
        "arch/x86/kvm/kvm-amd.ko"
        "net/vmw_vsock/vsock.ko"
        "net/vmw_vsock/vmw_vsock_virtio_transport_common.ko"
        ];
      };
      drafts = {
        v8FromCorrectedV7 = rec {
          status = "draft";
          patchVersion = 8;
          releaseIdentity = "6.12.95.8";
          predecessorIdentity = "6.12.95.7";
          predecessorInventory = [
            "livepatch_transition_guard"
            "lp61295_foundation"
            "lp7_sctp_correct"
          ];
          notes = [
            "Corrected-v7 supported-anchor draft; final publication still depends on parallel supported-v5 freeze-back."
            "Corrected-v7-side predecessor guard, lp8_from_v7 self-contract, and exact-final hash are frozen; checkpoint/rebuild freeze-back still remains pending."
          ];
          onlineAnchors = {
            correctedV7 = {
              class = "supported";
              activeIdentity = "6.12.95.7";
              activeInventory = predecessorInventory;
              expectedInventory = predecessorInventory ++ [
                correctedV7Online.moduleName
              ];
              activeArtifacts = [
                {
                  moduleName = "livepatch_transition_guard";
                  replace = false;
                  replacementCount = 6;
                }
                {
                  moduleName = "lp61295_foundation";
                  replace = false;
                  replacementCount = 11;
                }
                {
                  moduleName = "lp7_sctp_correct";
                  replace = false;
                  replacementCount = 4;
                }
              ];
              allowedBootBzImageSha256 = [
                "244ec9f7277617885cce47c564210f560ec9e6cfcdbfaf503626a2236f1b911e"
                "58390aa25aae9d8b3c313ebcb60b7a1bef30fae4759f704a7c2baacff6e9e29f"
                "3d208a0208a6d45ce9bc25a69fa9a29515c0f89fd9e6e9f6aef80ffe94872ee3"
              ];
              allowedSystemMapSha256 = [
                "38fdabb177fcfd9ca11e52d2a118a55347192ecf446428ceeead1ea384412be9"
              ];
              path = "correctedV7";
            };
          };
          anchors = {
            cleanBoot = {
              kind = "clean-boot";
              class = "supported";
              bootKernelVersion = "6.12.95";
              activeIdentity = "6.12.95";
              publishedIdentity = "6.12.95";
              activeInventory = [ ];
              allowedBootBzImageSha256 = [
                "244ec9f7277617885cce47c564210f560ec9e6cfcdbfaf503626a2236f1b911e"
                "58390aa25aae9d8b3c313ebcb60b7a1bef30fae4759f704a7c2baacff6e9e29f"
                "3d208a0208a6d45ce9bc25a69fa9a29515c0f89fd9e6e9f6aef80ffe94872ee3"
              ];
              allowedSystemMapSha256 = [
                "38fdabb177fcfd9ca11e52d2a118a55347192ecf446428ceeead1ea384412be9"
              ];
              path = "checkpointBootstrap";
            };
            checkpointComplete = {
              kind = "checkpoint-complete";
              class = "supported";
              bootKernelVersion = "6.12.95";
              activeIdentity = "6.12.95.8";
              publishedIdentity = "6.12.95.8";
              activeInventory = [
                checkpoint.moduleName
              ];
              path = "reverseValidation";
            };
          };
          contract = {
            anchor = {
              moduleName = "lp7_sctp_correct";
              functionCount = 4;
              inventoryId = {
                high = "0xb004f0281bdcc99dULL";
                low = "0xda6e93443e222b83ULL";
              };
            };
            guard = {
              moduleName = "livepatch_transition_guard";
              functionCount = 6;
              inventoryId = {
                high = "0x3fa36db88927cf79ULL";
                low = "0x5754ae11e224339dULL";
              };
            };
            checkpointGuard = {
              moduleName = "lp8_checkpoint_guard";
              functionCount = 10;
              inventoryId = {
                high = "0x97170d88bc49f655ULL";
                low = "0x5049771d386e2124ULL";
              };
            };
            reverseGuard = {
              moduleName = "lp8_reverse_guard";
              functionCount = 10;
              inventoryId = {
                high = "0x97170d88bc49f655ULL";
                low = "0x5049771d386e2124ULL";
              };
            };
            foundation = {
              moduleName = "lp61295_foundation";
              functionCount = 11;
              inventoryId = {
                high = "0x990643c95072c2c1ULL";
                low = "0xcdb753719b7f7b9fULL";
              };
            };
            final = {
              moduleName = "lp8_from_v7";
              functionCount = 20;
              inventoryId = {
                high = "0xed58aef41987e6b2ULL";
                low = "0x8e3606c89c7d8d14ULL";
              };
            };
            checkpoint = {
              moduleName = "livepatch_8";
              functionCount = 1;
              inventoryId = {
                high = "0x1ULL";
                low = "0x1ULL";
              };
            };
          };
          paths = {
            correctedV7 = [ correctedV7Online ];
            checkpointBootstrap = [ checkpointGuard ];
            reverseValidation = [ reverseValidation ];
          };
          correctedV7Online = {
            role = "generation-final";
            moduleName = "lp8_from_v7";
            buildPatches = [
              "bp-6.12.95-v7-headers"
              "bp-6.12.95-v7-transition-common"
              "bp-6.12.95-v7-sctp-corrective"
              "bp-6.12.95-v7-generation"
              "bp-6.12.95-v8-generation"
            ];
            targets = [
              "vmlinux"
              "lib/libcrc32c.ko"
              "net/ipv4/udp_tunnel.ko"
              "net/ipv6/ip6_udp_tunnel.ko"
              "net/sctp/sctp.ko"
              "net/ceph/libceph.ko"
              "fs/ceph/ceph.ko"
              "virt/lib/irqbypass.ko"
              "arch/x86/kvm/kvm.ko"
            ];
            nonReplace = true;
            expectedSha256 = "b25115dc50275ef7078a7a18254c99eda516ee8d9ab0998d2e07261cc7122b59";
            coverageState = {
              id = "0x6129500000000002";
              version = 8;
              complete = true;
            };
            publishedIdentity = "6.12.95.8";
            buildDefines = {
              VPSADMINOS_KLP_RELEASE_GENERATION = "8";
              VPSADMINOS_KLP_RELEASE_IDENTITY = "\"6.12.95.8\"";
              VPSADMINOS_KLP_ONLINE_PREDECESSOR_IDENTITY = "\"6.12.95.7\"";
              VPSADMINOS_KLP_ONLINE_EXPECT_PREDECESSOR_COVERAGE = "1";
              VPSADMINOS_KLP_ONLINE_PREDECESSOR_GENERATION = "7";
              VPSADMINOS_KLP_ONLINE_PREDECESSOR_FINAL_IDENTITY = "\"6.12.95.7\"";
              VPSADMINOS_KLP_ONLINE_PREDECESSOR_FINAL_ID_HI = "VPSADMINOS_KLP_V7_FINAL_ID_HI";
              VPSADMINOS_KLP_ONLINE_PREDECESSOR_FINAL_ID_LO = "VPSADMINOS_KLP_V7_FINAL_ID_LO";
              VPSADMINOS_KLP_ANCHOR_MODULE_NAME = "\"lp7_sctp_correct\"";
              VPSADMINOS_KLP_ANCHOR_ID_HI = "VPSADMINOS_KLP_V7_FINAL_ID_HI";
              VPSADMINOS_KLP_ANCHOR_ID_LO = "VPSADMINOS_KLP_V7_FINAL_ID_LO";
              VPSADMINOS_KLP_ONLINE_ANCHOR_CLASS = "VPSADMINOS_KLP_ANCHOR_SUPPORTED";
              VPSADMINOS_KLP_ONLINE_ANCHOR_IDENTITY = "\"6.12.95.7\"";
              VPSADMINOS_KLP_GUARD_MODULE_NAME = "\"livepatch_transition_guard\"";
              VPSADMINOS_KLP_GUARD_ID_HI = "VPSADMINOS_KLP_V7_GUARD_ID_HI";
              VPSADMINOS_KLP_GUARD_ID_LO = "VPSADMINOS_KLP_V7_GUARD_ID_LO";
              VPSADMINOS_KLP_FOUNDATION_MODULE_NAME = "\"lp61295_foundation\"";
              VPSADMINOS_KLP_FOUNDATION_ID_HI = "VPSADMINOS_KLP_V7_FOUNDATION_ID_HI";
              VPSADMINOS_KLP_FOUNDATION_ID_LO = "VPSADMINOS_KLP_V7_FOUNDATION_ID_LO";
              VPSADMINOS_KLP_PREDECESSOR_FOUNDATION_MODULE_NAME = "\"lp61295_foundation\"";
              VPSADMINOS_KLP_PREDECESSOR_FOUNDATION_ID_HI = "VPSADMINOS_KLP_V7_FOUNDATION_ID_HI";
              VPSADMINOS_KLP_PREDECESSOR_FOUNDATION_ID_LO = "VPSADMINOS_KLP_V7_FOUNDATION_ID_LO";
              VPSADMINOS_KLP_FINAL_MODULE_NAME = "\"lp8_from_v7\"";
              VPSADMINOS_KLP_FINAL_ID_HI = "0x176066a537034e8dULL";
              VPSADMINOS_KLP_FINAL_ID_LO = "0x9aa9df491bbb03e6ULL";
              VPSADMINOS_KLP_CHECKPOINT_GUARD_MODULE_NAME = "\"lp8_checkpoint_guard\"";
              VPSADMINOS_KLP_CHECKPOINT_GUARD_ID_HI = "0x289c89a6778a45ccULL";
              VPSADMINOS_KLP_CHECKPOINT_GUARD_ID_LO = "0xaf57c74ac6aea6a8ULL";
              VPSADMINOS_KLP_REVERSE_GUARD_MODULE_NAME = "\"lp8_reverse_guard\"";
              VPSADMINOS_KLP_REVERSE_GUARD_ID_HI = "0x6f83c80f3c024e4dULL";
              VPSADMINOS_KLP_REVERSE_GUARD_ID_LO = "0xa31ef8a35057d560ULL";
              VPSADMINOS_KLP_CHECKPOINT_MODULE_NAME = "\"livepatch_8\"";
              VPSADMINOS_KLP_CHECKPOINT_ID_HI = "0x0004ec996c174d51ULL";
              VPSADMINOS_KLP_CHECKPOINT_ID_LO = "0x9410368bdba2dee9ULL";
            };
          };
          checkpointGuard = {
            role = "checkpoint-guard";
            moduleName = "lp8_checkpoint_guard";
            buildPatches = [
              "bp-6.12.95-v7-headers"
              "bp-6.12.95-v7-transition-common"
              "bp-6.12.95-v7-sctp-corrective"
              "bp-6.12.95-v7-generation"
              "bp-6.12.95-v8-generation"
            ];
            targets = [ "vmlinux" ];
            nonReplace = true;
            expectedSha256 = "13e0fe1f7044244edc049f03ddba346c6d229b5854dad397ce4c2113c902b582";
            buildDefines = {
              VPSADMINOS_KLP_RELEASE_GENERATION = "8";
              VPSADMINOS_KLP_RELEASE_IDENTITY = "\"6.12.95.8\"";
              VPSADMINOS_KLP_CHECKPOINT_GUARD_MODULE_NAME = "\"lp8_checkpoint_guard\"";
              VPSADMINOS_KLP_CHECKPOINT_GUARD_ID_HI = "0x289c89a6778a45ccULL";
              VPSADMINOS_KLP_CHECKPOINT_GUARD_ID_LO = "0xaf57c74ac6aea6a8ULL";
              VPSADMINOS_KLP_CHECKPOINT_MODULE_NAME = "\"livepatch_8\"";
              VPSADMINOS_KLP_CHECKPOINT_ID_HI = "0x0004ec996c174d51ULL";
              VPSADMINOS_KLP_CHECKPOINT_ID_LO = "0x9410368bdba2dee9ULL";
            };
          };
          reverseValidation = {
            role = "reverse-guard";
            moduleName = "lp8_reverse_guard";
            buildPatches = [
              "bp-6.12.95-v7-headers"
              "bp-6.12.95-v7-transition-common"
              "bp-6.12.95-v7-sctp-corrective"
              "bp-6.12.95-v7-generation"
              "bp-6.12.95-v8-generation"
            ];
            targets = [ "vmlinux" ];
            nonReplace = true;
            expectedSha256 = null;
            buildDefines = {
              VPSADMINOS_KLP_RELEASE_GENERATION = "8";
              VPSADMINOS_KLP_RELEASE_IDENTITY = "\"6.12.95.8\"";
              VPSADMINOS_KLP_CHECKPOINT_MODULE_NAME = "\"livepatch_8\"";
              VPSADMINOS_KLP_CHECKPOINT_ID_HI = "0x0004ec996c174d51ULL";
              VPSADMINOS_KLP_CHECKPOINT_ID_LO = "0x9410368bdba2dee9ULL";
              VPSADMINOS_KLP_REVERSE_GUARD_MODULE_NAME = "\"lp8_reverse_guard\"";
              VPSADMINOS_KLP_REVERSE_GUARD_ID_HI = "0x6f83c80f3c024e4dULL";
              VPSADMINOS_KLP_REVERSE_GUARD_ID_LO = "0xa31ef8a35057d560ULL";
            };
          };
          checkpoint = {
            role = "checkpoint";
            moduleName = "livepatch_8";
            buildPatches = [
              "bp-6.12.95-cumulative-v8"
            ];
            expectedSha256 = null;
            nonReplace = false;
            coverageState = {
              id = "0x6129500000000002";
              version = 8;
              complete = true;
            };
            publishedIdentity = "6.12.95.8";
            targets = [
              "vmlinux"
              "fs/fuse/fuse.ko"
              "net/dns_resolver/dns_resolver.ko"
              "fs/nfs/nfsv4.ko"
              "net/llc/llc.ko"
              "net/802/stp.ko"
              "net/bridge/bridge.ko"
              "net/bridge/br_netfilter.ko"
              "net/netfilter/nfnetlink.ko"
              "net/netfilter/ipset/ip_set.ko"
              "net/netfilter/ipset/ip_set_hash_ip.ko"
              "net/netfilter/ipset/ip_set_hash_ipmac.ko"
              "net/netfilter/ipset/ip_set_hash_ipmark.ko"
              "net/netfilter/ipset/ip_set_hash_ipport.ko"
              "net/netfilter/ipset/ip_set_hash_ipportip.ko"
              "net/netfilter/ipset/ip_set_hash_ipportnet.ko"
              "net/netfilter/ipset/ip_set_hash_mac.ko"
              "net/netfilter/ipset/ip_set_hash_net.ko"
              "net/netfilter/ipset/ip_set_hash_netiface.ko"
              "net/netfilter/ipset/ip_set_hash_netnet.ko"
              "net/netfilter/ipset/ip_set_hash_netport.ko"
              "net/netfilter/ipset/ip_set_hash_netportnet.ko"
              "lib/libcrc32c.ko"
              "net/ipv4/netfilter/nf_defrag_ipv4.ko"
              "net/ipv4/inet_diag.ko"
              "net/ipv6/netfilter/nf_defrag_ipv6.ko"
              "net/netfilter/nf_conntrack.ko"
              "net/netfilter/nf_nat.ko"
              "net/netfilter/nf_conntrack_sip.ko"
              "net/netfilter/nf_nat_sip.ko"
              "net/netfilter/ipvs/ip_vs.ko"
              "net/netfilter/nf_tables.ko"
              "net/netfilter/nfnetlink_queue.ko"
              "drivers/net/slip/slhc.ko"
              "drivers/net/ppp/ppp_generic.ko"
              "net/ipv4/udp_tunnel.ko"
              "net/ipv6/ip6_udp_tunnel.ko"
              "drivers/net/vxlan/vxlan.ko"
              "net/packet/af_packet.ko"
              "net/sctp/sctp.ko"
              "net/sctp/sctp_diag.ko"
              "fs/ceph/ceph.ko"
              "net/ceph/libceph.ko"
              "crypto/sha1_generic.ko"
              "drivers/base/firmware_loader/firmware_class.ko"
              "drivers/crypto/ccp/ccp.ko"
              "virt/lib/irqbypass.ko"
              "arch/x86/kvm/kvm.ko"
              "arch/x86/kvm/kvm-intel.ko"
              "arch/x86/kvm/kvm-amd.ko"
              "net/vmw_vsock/vsock.ko"
              "net/vmw_vsock/vmw_vsock_virtio_transport_common.ko"
            ];
            buildDefines = {
              VPSADMINOS_KLP_RELEASE_GENERATION = "8";
              VPSADMINOS_KLP_RELEASE_IDENTITY = "\"6.12.95.8\"";
              VPSADMINOS_KLP_CHECKPOINT_MODULE_NAME = "\"livepatch_8\"";
              VPSADMINOS_KLP_CHECKPOINT_ID_HI = "0x0004ec996c174d51ULL";
              VPSADMINOS_KLP_CHECKPOINT_ID_LO = "0x9410368bdba2dee9ULL";
            };
          };
        };
        v8FromV5 = rec {
          status = "draft";
          patchVersion = 8;
          releaseIdentity = "6.12.95.8";
          predecessorIdentity = "6.12.95.5";
          predecessorInventory = [
            "livepatch_5"
          ];
          notes = [
            "Supported-v5 draft using v5-specific guard/foundation overrides plus the merged cumulative-v8 source projection."
            "Multi-anchor loader/schema support is wired locally, but final publication still needs exact artifact freeze-back and final release metadata."
            "Shared checkpoint-guard hash and shared reverse-guard self-contract are now frozen; v5-specific guard/final/checkpoint exact bytes still need successful build freeze-back."
          ];
          onlineAnchors = {
            supportedV5 = {
              class = "supported";
              activeIdentity = "6.12.95.5";
              activeInventory = predecessorInventory;
              expectedInventory = predecessorInventory ++ [
                v5Guard.moduleName
                v5Foundation.moduleName
                v5Final.moduleName
              ];
              activeArtifacts = [
                {
                  moduleName = "livepatch_5";
                  moduleFile =
                    "/nix/store/56hszgjcfqksfm820ybakwv3kmnvs76p-livepatch_5-6.12.95/"
                    + "lib/modules/6.12.95/extra/livepatch_5.ko";
                  moduleSha256 = "b31f64403d9d55f62e3d59e4bbefcbddcbda4fa66a2dc0689f9bb7cd7e927984";
                  moduleBuildId = "cee099d26bfb183a8008174bf4f2a38310beabc7";
                  replace = true;
                  replacementCount = 144;
                }
              ];
              allowedBootBzImageSha256 = [
                "244ec9f7277617885cce47c564210f560ec9e6cfcdbfaf503626a2236f1b911e"
                "58390aa25aae9d8b3c313ebcb60b7a1bef30fae4759f704a7c2baacff6e9e29f"
                "3d208a0208a6d45ce9bc25a69fa9a29515c0f89fd9e6e9f6aef80ffe94872ee3"
              ];
              allowedSystemMapSha256 = [
                "38fdabb177fcfd9ca11e52d2a118a55347192ecf446428ceeead1ea384412be9"
              ];
              path = "supportedV5";
            };
          };
          anchors = {
            cleanBoot = {
              kind = "clean-boot";
              class = "supported";
              bootKernelVersion = "6.12.95";
              activeIdentity = "6.12.95";
              publishedIdentity = "6.12.95";
              activeInventory = [ ];
              allowedBootBzImageSha256 = [
                "244ec9f7277617885cce47c564210f560ec9e6cfcdbfaf503626a2236f1b911e"
                "58390aa25aae9d8b3c313ebcb60b7a1bef30fae4759f704a7c2baacff6e9e29f"
                "3d208a0208a6d45ce9bc25a69fa9a29515c0f89fd9e6e9f6aef80ffe94872ee3"
              ];
              allowedSystemMapSha256 = [
                "38fdabb177fcfd9ca11e52d2a118a55347192ecf446428ceeead1ea384412be9"
              ];
              path = "checkpointBootstrap";
            };
            checkpointComplete = {
              kind = "checkpoint-complete";
              class = "supported";
              bootKernelVersion = "6.12.95";
              activeIdentity = "6.12.95.8";
              publishedIdentity = "6.12.95.8";
              activeInventory = [
                checkpoint.moduleName
              ];
              path = "reverseValidation";
            };
          };
          contract = {
            anchor = {
              moduleName = "livepatch_5";
              functionCount = 144;
              inventoryId = {
                high = "0x552df4c0b20dc145ULL";
                low = "0x7516b53af18968e8ULL";
              };
            };
            guard = {
              moduleName = "livepatch_transition_guard";
              functionCount = 6;
              inventoryId = {
                high = "0x3fa36db88927cf79ULL";
                low = "0x5754ae11e224339dULL";
              };
            };
            checkpointGuard = {
              moduleName = "lp8_checkpoint_guard";
              functionCount = 10;
              inventoryId = {
                high = "0x97170d88bc49f655ULL";
                low = "0x5049771d386e2124ULL";
              };
            };
            reverseGuard = {
              moduleName = "lp8_reverse_guard";
              functionCount = 10;
              inventoryId = {
                high = "0x97170d88bc49f655ULL";
                low = "0x5049771d386e2124ULL";
              };
            };
            foundation = {
              moduleName = "lp61295_foundation";
              functionCount = 11;
              inventoryId = {
                high = "0x990643c95072c2c1ULL";
                low = "0xcdb753719b7f7b9fULL";
              };
            };
            final = {
              moduleName = "lp8_from_v5";
              functionCount = 1;
              inventoryId = {
                high = "0x1ULL";
                low = "0x1ULL";
              };
            };
            checkpoint = {
              moduleName = "livepatch_8";
              functionCount = 1;
              inventoryId = {
                high = "0x1ULL";
                low = "0x1ULL";
              };
            };
          };
          paths = {
            supportedV5 = [
              v5Guard
              v5Foundation
              v5Final
            ];
            checkpointBootstrap = [ checkpointGuard ];
            reverseValidation = [ reverseValidation ];
          };
          v5Guard = {
            role = "bootstrap-guard";
            moduleName = "livepatch_transition_guard";
            buildPatches = [
              "bp-6.12.95-v7-headers"
              "bp-6.12.95-v7-transition-common"
            ];
            targets = [ "vmlinux" ];
            nonReplace = true;
            expectedSha256 = null;
            bootstrap = {
              moduleName = "livepatch_transition_bootstrap";
              sourceDir = "transition-bootstrap";
              kickParameter = "kick_idle";
              expectedSha256 = "5883b23743b5194fd5094e73912009ce67d84d414f4f725e082ac54733bdbc5f";
            };
            buildDefines = {
              VPSADMINOS_KLP_ONLINE_PREDECESSOR_IDENTITY = "\"6.12.95.5\"";
              VPSADMINOS_KLP_ANCHOR_MODULE_NAME = "\"livepatch_5\"";
              VPSADMINOS_KLP_ANCHOR_ID_HI = "0x2375dfca85fc5717ULL";
              VPSADMINOS_KLP_ANCHOR_ID_LO = "0x0afbfe981adcd877ULL";
            };
          };
          v5Foundation = {
            role = "foundation";
            moduleName = "lp61295_foundation";
            buildPatches = [
              "bp-6.12.95-v7-headers"
              "bp-6.12.95-v7-transition-common"
            ];
            targets = [ "vmlinux" ];
            nonReplace = true;
            expectedSha256 = null;
            foundationState = {
              id = "0x6129500000000001";
              version = 1;
            };
            buildDefines = {
              VPSADMINOS_KLP_ONLINE_PREDECESSOR_IDENTITY = "\"6.12.95.5\"";
              VPSADMINOS_KLP_ANCHOR_MODULE_NAME = "\"livepatch_5\"";
              VPSADMINOS_KLP_ANCHOR_ID_HI = "0x2375dfca85fc5717ULL";
              VPSADMINOS_KLP_ANCHOR_ID_LO = "0x0afbfe981adcd877ULL";
            };
          };
          v5Final = {
            role = "generation-final";
            moduleName = "lp8_from_v5";
            buildPatches = [
              "bp-6.12.95-cumulative-v8"
            ];
            targets = checkpoint.targets;
            nonReplace = true;
            expectedSha256 = null;
            coverageState = {
              id = "0x6129500000000002";
              version = 8;
              complete = true;
            };
            publishedIdentity = "6.12.95.8";
            buildDefines = {
              VPSADMINOS_KLP_RELEASE_GENERATION = "8";
              VPSADMINOS_KLP_RELEASE_IDENTITY = "\"6.12.95.8\"";
              VPSADMINOS_KLP_ONLINE_PREDECESSOR_IDENTITY = "\"6.12.95.5\"";
              VPSADMINOS_KLP_ONLINE_EXPECT_PREDECESSOR_COVERAGE = "0";
              VPSADMINOS_KLP_ANCHOR_MODULE_NAME = "\"livepatch_5\"";
              VPSADMINOS_KLP_ANCHOR_ID_HI = "0x2375dfca85fc5717ULL";
              VPSADMINOS_KLP_ANCHOR_ID_LO = "0x0afbfe981adcd877ULL";
              VPSADMINOS_KLP_ONLINE_ANCHOR_CLASS = "VPSADMINOS_KLP_ANCHOR_SUPPORTED";
              VPSADMINOS_KLP_ONLINE_ANCHOR_IDENTITY = "\"6.12.95.5\"";
              VPSADMINOS_KLP_GUARD_MODULE_NAME = "\"livepatch_transition_guard\"";
              VPSADMINOS_KLP_GUARD_ID_HI = "VPSADMINOS_KLP_V7_GUARD_ID_HI";
              VPSADMINOS_KLP_GUARD_ID_LO = "VPSADMINOS_KLP_V7_GUARD_ID_LO";
              VPSADMINOS_KLP_FOUNDATION_MODULE_NAME = "\"lp61295_foundation\"";
              VPSADMINOS_KLP_FOUNDATION_ID_HI = "VPSADMINOS_KLP_V7_FOUNDATION_ID_HI";
              VPSADMINOS_KLP_FOUNDATION_ID_LO = "VPSADMINOS_KLP_V7_FOUNDATION_ID_LO";
              VPSADMINOS_KLP_PREDECESSOR_FOUNDATION_MODULE_NAME = "\"lp61295_foundation\"";
              VPSADMINOS_KLP_PREDECESSOR_FOUNDATION_ID_HI = "VPSADMINOS_KLP_V7_FOUNDATION_ID_HI";
              VPSADMINOS_KLP_PREDECESSOR_FOUNDATION_ID_LO = "VPSADMINOS_KLP_V7_FOUNDATION_ID_LO";
              VPSADMINOS_KLP_FINAL_MODULE_NAME = "\"lp8_from_v5\"";
              VPSADMINOS_KLP_FINAL_ID_HI = "0x89db049168094d6aULL";
              VPSADMINOS_KLP_FINAL_ID_LO = "0x92b3d9404ba441d3ULL";
              VPSADMINOS_KLP_CHECKPOINT_GUARD_MODULE_NAME = "\"lp8_checkpoint_guard\"";
              VPSADMINOS_KLP_CHECKPOINT_GUARD_ID_HI = "0x289c89a6778a45ccULL";
              VPSADMINOS_KLP_CHECKPOINT_GUARD_ID_LO = "0xaf57c74ac6aea6a8ULL";
              VPSADMINOS_KLP_REVERSE_GUARD_MODULE_NAME = "\"lp8_reverse_guard\"";
              VPSADMINOS_KLP_REVERSE_GUARD_ID_HI = "0x6f83c80f3c024e4dULL";
              VPSADMINOS_KLP_REVERSE_GUARD_ID_LO = "0xa31ef8a35057d560ULL";
              VPSADMINOS_KLP_CHECKPOINT_MODULE_NAME = "\"livepatch_8\"";
              VPSADMINOS_KLP_CHECKPOINT_ID_HI = "0x0004ec996c174d51ULL";
              VPSADMINOS_KLP_CHECKPOINT_ID_LO = "0x9410368bdba2dee9ULL";
            };
          };
          checkpointGuard = {
            role = "checkpoint-guard";
            moduleName = "lp8_checkpoint_guard";
            buildPatches = [
              "bp-6.12.95-v7-headers"
              "bp-6.12.95-v7-transition-common"
              "bp-6.12.95-v7-sctp-corrective"
              "bp-6.12.95-v7-generation"
              "bp-6.12.95-v8-generation"
            ];
            targets = [ "vmlinux" ];
            nonReplace = true;
            expectedSha256 = "13e0fe1f7044244edc049f03ddba346c6d229b5854dad397ce4c2113c902b582";
            buildDefines = {
              VPSADMINOS_KLP_RELEASE_GENERATION = "8";
              VPSADMINOS_KLP_RELEASE_IDENTITY = "\"6.12.95.8\"";
              VPSADMINOS_KLP_CHECKPOINT_GUARD_MODULE_NAME = "\"lp8_checkpoint_guard\"";
              VPSADMINOS_KLP_CHECKPOINT_GUARD_ID_HI = "0x289c89a6778a45ccULL";
              VPSADMINOS_KLP_CHECKPOINT_GUARD_ID_LO = "0xaf57c74ac6aea6a8ULL";
              VPSADMINOS_KLP_CHECKPOINT_MODULE_NAME = "\"livepatch_8\"";
              VPSADMINOS_KLP_CHECKPOINT_ID_HI = "0x0004ec996c174d51ULL";
              VPSADMINOS_KLP_CHECKPOINT_ID_LO = "0x9410368bdba2dee9ULL";
            };
          };
          reverseValidation = {
            role = "reverse-guard";
            moduleName = "lp8_reverse_guard";
            buildPatches = [
              "bp-6.12.95-v7-headers"
              "bp-6.12.95-v7-transition-common"
              "bp-6.12.95-v7-sctp-corrective"
              "bp-6.12.95-v7-generation"
              "bp-6.12.95-v8-generation"
            ];
            targets = [ "vmlinux" ];
            nonReplace = true;
            expectedSha256 = null;
            buildDefines = {
              VPSADMINOS_KLP_RELEASE_GENERATION = "8";
              VPSADMINOS_KLP_RELEASE_IDENTITY = "\"6.12.95.8\"";
              VPSADMINOS_KLP_CHECKPOINT_MODULE_NAME = "\"livepatch_8\"";
              VPSADMINOS_KLP_CHECKPOINT_ID_HI = "0x0004ec996c174d51ULL";
              VPSADMINOS_KLP_CHECKPOINT_ID_LO = "0x9410368bdba2dee9ULL";
              VPSADMINOS_KLP_REVERSE_GUARD_MODULE_NAME = "\"lp8_reverse_guard\"";
              VPSADMINOS_KLP_REVERSE_GUARD_ID_HI = "0x6f83c80f3c024e4dULL";
              VPSADMINOS_KLP_REVERSE_GUARD_ID_LO = "0xa31ef8a35057d560ULL";
            };
          };
          checkpoint = {
            role = "checkpoint";
            moduleName = "livepatch_8";
            buildPatches = [
              "bp-6.12.95-cumulative-v8"
            ];
            expectedSha256 = null;
            nonReplace = false;
            coverageState = {
              id = "0x6129500000000002";
              version = 8;
              complete = true;
            };
            publishedIdentity = "6.12.95.8";
            targets = [
              "vmlinux"
              "fs/fuse/fuse.ko"
              "net/dns_resolver/dns_resolver.ko"
              "fs/nfs/nfsv4.ko"
              "net/llc/llc.ko"
              "net/802/stp.ko"
              "net/bridge/bridge.ko"
              "net/bridge/br_netfilter.ko"
              "net/netfilter/nfnetlink.ko"
              "net/netfilter/ipset/ip_set.ko"
              "net/netfilter/ipset/ip_set_hash_ip.ko"
              "net/netfilter/ipset/ip_set_hash_ipmac.ko"
              "net/netfilter/ipset/ip_set_hash_ipmark.ko"
              "net/netfilter/ipset/ip_set_hash_ipport.ko"
              "net/netfilter/ipset/ip_set_hash_ipportip.ko"
              "net/netfilter/ipset/ip_set_hash_ipportnet.ko"
              "net/netfilter/ipset/ip_set_hash_mac.ko"
              "net/netfilter/ipset/ip_set_hash_net.ko"
              "net/netfilter/ipset/ip_set_hash_netiface.ko"
              "net/netfilter/ipset/ip_set_hash_netnet.ko"
              "net/netfilter/ipset/ip_set_hash_netport.ko"
              "net/netfilter/ipset/ip_set_hash_netportnet.ko"
              "lib/libcrc32c.ko"
              "net/ipv4/netfilter/nf_defrag_ipv4.ko"
              "net/ipv4/inet_diag.ko"
              "net/ipv6/netfilter/nf_defrag_ipv6.ko"
              "net/netfilter/nf_conntrack.ko"
              "net/netfilter/nf_nat.ko"
              "net/netfilter/nf_conntrack_sip.ko"
              "net/netfilter/nf_nat_sip.ko"
              "net/netfilter/ipvs/ip_vs.ko"
              "net/netfilter/nf_tables.ko"
              "net/netfilter/nfnetlink_queue.ko"
              "drivers/net/slip/slhc.ko"
              "drivers/net/ppp/ppp_generic.ko"
              "net/ipv4/udp_tunnel.ko"
              "net/ipv6/ip6_udp_tunnel.ko"
              "drivers/net/vxlan/vxlan.ko"
              "net/packet/af_packet.ko"
              "net/sctp/sctp.ko"
              "net/sctp/sctp_diag.ko"
              "fs/ceph/ceph.ko"
              "net/ceph/libceph.ko"
              "crypto/sha1_generic.ko"
              "drivers/base/firmware_loader/firmware_class.ko"
              "drivers/crypto/ccp/ccp.ko"
              "virt/lib/irqbypass.ko"
              "arch/x86/kvm/kvm.ko"
              "arch/x86/kvm/kvm-intel.ko"
              "arch/x86/kvm/kvm-amd.ko"
              "net/vmw_vsock/vsock.ko"
              "net/vmw_vsock/vmw_vsock_virtio_transport_common.ko"
            ];
            buildDefines = {
              VPSADMINOS_KLP_RELEASE_GENERATION = "8";
              VPSADMINOS_KLP_RELEASE_IDENTITY = "\"6.12.95.8\"";
              VPSADMINOS_KLP_CHECKPOINT_MODULE_NAME = "\"livepatch_8\"";
              VPSADMINOS_KLP_CHECKPOINT_ID_HI = "0x0004ec996c174d51ULL";
              VPSADMINOS_KLP_CHECKPOINT_ID_LO = "0x9410368bdba2dee9ULL";
            };
          };
        };
      };
    }
    {
      name = "bp-6.12.48-6.12.89-cumulative";
      filterFn = availableForRange "6.12.48" "6.12.89";
      version = 1;
    }
    # The uname patch is the canonical livepatch example.
    # It changes init_uts_ns.name.release to "<kernelVer>.<patchVer>"
    # so that `uname -r` shows the livepatch is active.
    # Uncomment to enable:
    # {
    #   name = "uname";
    #   filterFn = availableForAllKernels;
    # }
  ];

  availableForAllKernels = kernelVersion: true;
  availableFor = compatVersion: kernelVersion: kernelVersion == compatVersion;
  availableSince = verLow: kernelVersion: (versionAtLeast kernelVersion verLow);
  availableForRange =
    verLow: verHigh: kernelVersion:
    (versionAtLeast kernelVersion verLow && versionUpTo kernelVersion verHigh);
  versionUpTo = v1: v2: builtins.compareVersions v1 v2 < 1;

  getPatchVersion = patch: if (hasAttr "version" patch) then patch.version else 1;
  filterPatches = kernelVersion: filter (patch: patch.filterFn kernelVersion) availablePatches;
  filterPatchesVersions = kernelVersion: map getPatchVersion (filterPatches kernelVersion);
  filterPatchesVersionsSum =
    kernelVersion: foldl (x: y: x + y) 0 (filterPatchesVersions kernelVersion);

  patchListForVersion =
    kernelVersion:
    concatMap (patch: patch.buildPatches or [ patch.name ]) (filterPatches kernelVersion);
  patchTargetsForVersion =
    kernelVersion: unique (concatMap (patch: patch.targets or [ ]) (filterPatches kernelVersion));
  transitionGuardsForVersion =
    kernelVersion:
    concatMap (patch: optional (patch ? transitionGuard) patch.transitionGuard) (
      filterPatches kernelVersion
    );
  releaseForVersion = kernelVersion:
    let
      releases = filterPatches kernelVersion;
    in
    if length releases == 1 then head releases else null;
in
{
  getPatchVersion = getPatchVersion;
  patchList = patchListForVersion version;
  patchTargets = patchTargetsForVersion version;
  transitionGuards = transitionGuardsForVersion version;
  release = releaseForVersion version;
  patchVersion = filterPatchesVersionsSum version;
  filteredPatches = filterPatches version;
  allPatches = availablePatches;
}
