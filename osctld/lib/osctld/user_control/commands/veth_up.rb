require 'libosctl'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::VethUp < UserControl::Commands::Base
    handle :veth_up
    allow_adopted_legacy_callbacks

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      run = lifecycle_run(ct, allow_active: true)
      return error('managed lifecycle run not found') unless run
      if opts[:run_id].nil? && run.dig('resources', 'cgroup_root') != ct.base_cgroup_path
        return error('lifecycle run id is required')
      end

      run_id = Container::RunId.load(run.fetch('id'))
      return error('managed lifecycle run changed') unless ct.lifecycle.active_run_id == run_id

      log(
        :info,
        ct,
        "veth interface coming up: ct=#{opts[:interface]}, host=#{opts[:veth]}"
      )

      netif = ct.netifs[opts[:interface]]
      return error('network interface not found') unless netif

      netif.up(opts[:veth])
      recorded = ct.lifecycle.record_network_interface(
        run_id,
        name: netif.name,
        type: netif.type,
        veth: opts[:veth],
        routes: route_strings(netif),
        callback_id: lifecycle_callback_id
      )
      unless recorded
        netif.down(opts[:veth])
        return error('managed lifecycle run changed')
      end

      Hook.run(
        ct,
        :veth_up,
        ct_veth: opts[:interface],
        host_veth: opts[:veth],
        enable: netif.enable
      )
      ok
    rescue HookFailed => e
      error(e.message)
    end

    protected

    def route_strings(netif)
      return {} unless netif.respond_to?(:routes)

      [4, 6].to_h do |version|
        routes = []
        netif.routes.each_version(version) do |route|
          routes << route.addr.to_string
        end
        [version.to_s, routes]
      end
    end
  end
end
