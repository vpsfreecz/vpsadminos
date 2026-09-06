# frozen_string_literal: true

require 'osctld/erb_template'
require 'osctld/erb_template_cache'

RSpec.describe OsCtld::ErbTemplate do
  def render_config(apparmor_enabled:, tracing_namespace_supported:)
    map_entry = Struct.new(:ns_id, :host_id, :id_count)
    cgroup_params = Class.new do
      def each_usable; end
    end
    config = Struct.new(:time_namespace_enabled, keyword_init: true) do
      def enable_time_namespace?
        time_namespace_enabled
      end
    end
    daemon = Struct.new(:config, keyword_init: true).new(
      config: config.new(time_namespace_enabled: false)
    )
    shared_dir = Struct.new(:host_path, keyword_init: true) do
      def host_path_for(_path)
        host_path
      end
    end
    mounts = Struct.new(:shared_dir, keyword_init: true)
    user = Struct.new(:uid_map, :gid_map, keyword_init: true)
    apparmor = Struct.new(:namespace_profile_name, keyword_init: true)
    pool = Struct.new(:hook_dir, keyword_init: true)
    run_conf = Struct.new(:rootfs, keyword_init: true)
    container = Struct.new(
      :id,
      :pool,
      :nesting,
      :map_mode,
      :mounts,
      :get_run_conf,
      :arch,
      :hostname,
      :user,
      :seccomp_profile,
      :apparmor,
      :format_exec_init_cmd,
      keyword_init: true
    )

    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?)
      .with('/proc/self/ns/tracing')
      .and_return(tracing_namespace_supported)

    stub_const(
      'OsCtld::AppArmor',
      Class.new do
        define_singleton_method(:enabled?) { apparmor_enabled }
      end
    )

    stub_const(
      'OsCtld::CGroup',
      Class.new do
        def self.v2?
          true
        end
      end
    )

    stub_const(
      'OsCtld::Daemon',
      Class.new do
        define_singleton_method(:get) { daemon }
      end
    )

    stub_const(
      'OsCtld::Lxc',
      Class.new do
        const_set(:CONFIGS, '/run/osctl/configs/lxc')

        def self.dist_lxc_configs(_distribution, _version)
          []
        end
      end
    )

    unless OsCtld.respond_to?(:template_dir)
      OsCtld.define_singleton_method(:template_dir) { nil }
    end

    unless OsCtld.respond_to?(:hook_run)
      OsCtld.define_singleton_method(:hook_run) { |_name, _pool| nil }
    end

    allow(OsCtld).to receive(:template_dir).and_return(
      File.expand_path('../../../templates', __dir__)
    )
    allow(OsCtld).to receive(:hook_run) { |name, hook_pool| File.join(hook_pool.hook_dir, name) }

    OsCtld::ErbTemplateCache.instance.load

    shared_dir_obj = shared_dir.new(host_path: '/host/rootfs')
    mounts_obj = mounts.new(shared_dir: shared_dir_obj)
    user_obj = user.new(
      uid_map: [map_entry.new(0, 100_000, 65_536)],
      gid_map: [map_entry.new(0, 100_000, 65_536)]
    )
    apparmor_obj = apparmor.new(
      namespace_profile_name: 'ct-tank-demo//&:lxc-ct-tank-demo:'
    )
    pool_obj = pool.new(hook_dir: '/run/osctl/pool.tank/hooks')
    ct = container.new(
      id: 'demo',
      pool: pool_obj,
      nesting: false,
      map_mode: 'native',
      mounts: mounts_obj,
      get_run_conf: run_conf.new(rootfs: '/ct/rootfs'),
      arch: 'x86_64',
      hostname: nil,
      user: user_obj,
      seccomp_profile: '/run/osctl/seccomp/default',
      apparmor: apparmor_obj,
      format_exec_init_cmd: '/sbin/init'
    )

    OsCtld::ErbTemplate.render(
      'ct/config',
      distribution: 'alpine',
      version: '3.20',
      ct:,
      rootfs: '/ct/rootfs',
      cgparams: cgroup_params.new,
      prlimits: {},
      netifs: [],
      mounts: [],
      raw: ''
    )
  end

  it 'requests tracing namespace when supported' do
    rendered = render_config(
      apparmor_enabled: true,
      tracing_namespace_supported: true
    )

    expect(rendered).to include("lxc.apparmor.profile = ct-tank-demo//&:lxc-ct-tank-demo:\n")
    expect(rendered).to include("lxc.namespace.clone.tracing = 1\n")
  end

  it 'omits tracing namespace request when kernel support is missing' do
    rendered = render_config(
      apparmor_enabled: true,
      tracing_namespace_supported: false
    )

    expect(rendered).not_to include('lxc.namespace.clone.tracing = 1')
    expect(rendered).to include("lxc.apparmor.profile = ct-tank-demo//&:lxc-ct-tank-demo:\n")
    expect(rendered).to include('# Disabled: tracing namespace support not present')
  end

  it 'omits the AppArmor profile when osctld AppArmor support is disabled' do
    rendered = render_config(
      apparmor_enabled: false,
      tracing_namespace_supported: true
    )

    expect(rendered).not_to include('lxc.apparmor.profile =')
    expect(rendered).to include("lxc.namespace.clone.tracing = 1\n")
  end
end
