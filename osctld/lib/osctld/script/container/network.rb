module OsCtld
  module Script::Container::Network
    def self.run(ct)
      env = ENV.to_hash
      env['CT_ROOT'] = ct.rootfs

      [4, 6].each do |ip_v|
        if ct.can_route?(ip_v)
          env["CT_HAS_IPV#{ip_v}"] = '1'
          env["CT_IPV#{ip_v}_VIA"] = ct.route_via(ip_v)
          env["CT_IPV#{ip_v}_ADDRS"] = ct.ips(ip_v).join(' ')

        else
          env["CT_HAS_IPV#{ip_v}"] = ''
          env["CT_IPV#{ip_v}_VIA"] = ''
          env["CT_IPV#{ip_v}_ADDRS"] = ''
        end
      end

      Script.run(
        ["network/#{ct.distribution}-#{ct.version}", "network/#{ct.distribution}"],
        env
      )
    end
  end
end
