# frozen_string_literal: true

require 'ostruct'

require 'osctld/erb_template'
require 'osctld/erb_template_cache'

RSpec.describe 'ct/config template' do
  MapEntry = Struct.new(:ns_id, :host_id, :id_count)

  class EmptyCGroupParams
    def each_usable; end
  end

  def render_config(apparmor_enabled:, lsm_namespace_supported:, tracing_namespace_supported:)
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?)
      .with('/proc/self/ns/tracing')
      .and_return(tracing_namespace_supported)

    stub_const(
      'OsCtld::AppArmor',
      Class.new do
        define_singleton_method(:enabled?) { apparmor_enabled }
        define_singleton_method(:lsm_namespace_supported?) { lsm_namespace_supported }
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
        def self.get
          OpenStruct.new(config: OpenStruct.new(enable_time_namespace?: false))
        end
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
    allow(OsCtld).to receive(:hook_run) { |name, pool| File.join(pool.hook_dir, name) }

    OsCtld::ErbTemplateCache.instance.load

    shared_dir = double(host_path_for: '/host/rootfs')
    mounts = double(shared_dir:)
    user = double(
      uid_map: [MapEntry.new(0, 100_000, 65_536)],
      gid_map: [MapEntry.new(0, 100_000, 65_536)]
    )
    apparmor = double(
      namespace: 'lxc-ct-tank-demo',
      lxc_profile_name: lsm_namespace_supported ? 'unchanged' : 'ct-tank-demo//&:lxc-ct-tank-demo:'
    )
    pool = double(hook_dir: '/run/osctl/pool.tank/hooks')
    ct = double(
      id: 'demo',
      pool:,
      nesting: false,
      map_mode: 'native',
      mounts:,
      get_run_conf: double(rootfs: '/ct/rootfs'),
      arch: 'x86_64',
      hostname: nil,
      user:,
      seccomp_profile: '/run/osctl/seccomp/default',
      apparmor:,
      format_exec_init_cmd: '/sbin/init'
    )

    OsCtld::ErbTemplate.render(
      'ct/config',
      distribution: 'alpine',
      version: '3.20',
      ct:,
      cgparams: EmptyCGroupParams.new,
      prlimits: {},
      netifs: [],
      mounts: [],
      raw: ''
    )
  end

  it 'requests tracing and AppArmor LSM namespaces when supported' do
    rendered = render_config(
      apparmor_enabled: true,
      lsm_namespace_supported: true,
      tracing_namespace_supported: true
    )

    expect(rendered).to include("lxc.namespace.clone.lsm = apparmor\n")
    expect(rendered).to include("lxc.namespace.clone.lsm.name = lxc-ct-tank-demo\n")
    expect(rendered).to include("lxc.apparmor.profile = unchanged\n")
    expect(rendered).to include("lxc.namespace.clone.tracing = 1\n")
  end

  it 'omits optional namespace requests when kernel support is missing' do
    rendered = render_config(
      apparmor_enabled: true,
      lsm_namespace_supported: false,
      tracing_namespace_supported: false
    )

    expect(rendered).not_to include('lxc.namespace.clone.lsm =')
    expect(rendered).not_to include('lxc.namespace.clone.lsm.name =')
    expect(rendered).not_to include('lxc.namespace.clone.tracing = 1')
    expect(rendered).to include("lxc.apparmor.profile = ct-tank-demo//&:lxc-ct-tank-demo:\n")
    expect(rendered).to include('# Disabled: tracing namespace support not present')
  end

  it 'disables LXC AppArmor defaults when osctld AppArmor support is disabled' do
    rendered = render_config(
      apparmor_enabled: false,
      lsm_namespace_supported: false,
      tracing_namespace_supported: true
    )

    expect(rendered).to include("lxc.apparmor.profile = unconfined\n")
    expect(rendered).not_to include('lxc.namespace.clone.lsm =')
    expect(rendered).not_to include('lxc.namespace.clone.lsm.name =')
  end
end
