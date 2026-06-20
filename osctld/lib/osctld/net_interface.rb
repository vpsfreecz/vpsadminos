module OsCtld
  module NetInterface
    class HostLinkClaimError < StandardError; end

    HOST_LINK_REGISTRY_LOCK = Mutex.new

    def self.register(type, klass)
      @types ||= {}
      @types[type] = klass
    end

    def self.for(type)
      @types[type]
    end

    def self.setup
      @types.each_value(&:setup)
    end

    # Serialize publication, removal, validation, and kernel mutation of
    # daemon-owned host-link identities across all containers.
    #
    # The lock is re-entrant for the owning thread because recovery holds it
    # across preflight and then delegates deletion to the owning netif.
    def self.sync_host_link_registry(&block)
      return block.call if HOST_LINK_REGISTRY_LOCK.owned?

      HOST_LINK_REGISTRY_LOCK.synchronize(&block)
    end

    # Reject a host-link name or ifindex claimed by any other daemon netif.
    # Callers must hold +HOST_LINK_REGISTRY_LOCK+ from this check through every
    # related in-memory publication and host-network mutation.
    def self.validate_host_link_claim!(
      owner_ct:,
      owner_netif:,
      name:,
      veth_ifindex:,
      ifb_ifindex:,
      ifb_name: nil,
      owner_netifs: nil
    )
      unless HOST_LINK_REGISTRY_LOCK.owned?
        raise 'host-link claim validation requires the registry lock'
      end

      claim_names = [name, ifb_name].compact
      claim_indices = [veth_ifindex, ifb_ifindex].compact
      containers = DB::Containers.get
      containers = [owner_ct] + containers unless containers.any? { |ct| ct.equal?(owner_ct) }

      containers.each do |other_ct|
        other_netifs =
          if owner_netifs && other_ct.equal?(owner_ct)
            owner_netifs
          else
            other_ct.netifs
          end

        other_netifs.each do |other_netif|
          next if other_ct.equal?(owner_ct) && other_netif.equal?(owner_netif)
          next unless other_netif.respond_to?(:host_link_identity)

          other_name, other_veth_ifindex, other_ifb_ifindex =
            other_netif.host_link_identity
          other_names = []
          if other_name.is_a?(String) && !other_name.empty?
            other_names << other_name
            other_names << "ifb#{other_name}" if other_ifb_ifindex
          end
          other_indices = [other_veth_ifindex, other_ifb_ifindex].select do |ifindex|
            ifindex.is_a?(Integer) && ifindex > 0
          end
          next unless claim_names.intersect?(other_names) ||
                      claim_indices.intersect?(other_indices)

          raise HostLinkClaimError,
                "host-link identity #{claim_names.inspect}/#{claim_indices.inspect} " \
                "is also claimed by container #{other_ct.ident}"
        end
      end
    end

    def self.validate_host_link_owner!(owner_ct:, owner_netif:, owner_netifs: nil)
      return unless owner_netif.respond_to?(:host_link_identity)

      name, veth_ifindex, ifb_ifindex = owner_netif.host_link_identity
      return if name.nil? && veth_ifindex.nil? && ifb_ifindex.nil?

      validate_host_link_claim!(
        owner_ct:,
        owner_netif:,
        name:,
        veth_ifindex:,
        ifb_ifindex:,
        ifb_name: name && ifb_ifindex && "ifb#{name}",
        owner_netifs:
      )
    end

    def self.validate_container_host_link_claims!(ct, owner_netifs: nil)
      unless HOST_LINK_REGISTRY_LOCK.owned?
        raise 'container host-link validation requires the registry lock'
      end

      netifs = owner_netifs || ct.netifs

      netifs.each do |netif|
        validate_host_link_owner!(
          owner_ct: ct,
          owner_netif: netif,
          owner_netifs: netifs
        )
      end
    end

    def self.validate_container_host_links_released!(ct)
      unless HOST_LINK_REGISTRY_LOCK.owned?
        raise 'container host-link removal requires the registry lock'
      end

      ct.netifs.each do |netif|
        next unless netif.respond_to?(:host_link_identity)
        next unless netif.host_link_identity.any?

        raise HostLinkClaimError,
              "container #{ct.ident} still owns host links through " \
              "network interface #{netif.name.inspect}"
      end
    end
  end
end
