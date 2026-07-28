# frozen_string_literal: true

require 'osctld/utils/switch_user'
require 'osctld/dist_config'
require 'osctld/dist_config/distributions/nixos'
require 'osctld/container_control/commands/with_mountns'

RSpec.describe OsCtld::DistConfig::Distributions::NixOS do
  def resolvers
    ['192.0.2.53', '2001:db8::53']
  end

  def payload
    "nameserver 192.0.2.53\n" \
      "nameserver 2001:db8::53\n" \
      "options edns0\n"
  end

  before do
    OsCtl::Lib::Logger.setup(:none)
  end

  let(:ct) do
    Struct.new(
      :id,
      :ident,
      :running,
      :dns_resolvers,
      :impermanence,
      keyword_init: true
    ) do
      def running?
        running
      end
    end.new(
      id: 'ct1',
      ident: 'tank:ct1',
      running: ct_state[:running],
      dns_resolvers: resolvers,
      impermanence: ct_state[:impermanence]
    )
  end
  let(:ctrc) do
    Struct.new(:ct, :distribution, :version, keyword_init: true).new(
      ct:,
      distribution: 'nixos',
      version: '26.05'
    )
  end
  let(:ct_state) { { running: true, impermanence: nil } }
  let(:distribution) { described_class.new(ctrc) }

  it 'applies a live resolver set through the installed NixOS updater' do
    allow(distribution).to receive(:ct_syscmd)

    distribution.dns_resolvers

    expect(distribution).to have_received(:ct_syscmd).with(
      ct,
      [described_class::DNS_UPDATE],
      stdin: payload
    )
  end

  it 'applies a live resolver clear through the same updater' do
    allow(distribution).to receive(:ct_syscmd)

    distribution.unset_dns_resolvers

    expect(distribution).to have_received(:ct_syscmd).with(
      ct,
      [described_class::DNS_UPDATE, '--clear']
    )
  end

  context 'when the container is stopped' do
    let(:ct_state) { super().merge(running: false) }

    it 'persists set and clear state without entering a hidden rootfs /run' do
      allow(distribution).to receive(:ct_syscmd)

      distribution.dns_resolvers
      distribution.unset_dns_resolvers

      expect(distribution).not_to have_received(:ct_syscmd)
    end
  end

  it 'injects the runtime handoff after mounts are complete' do
    writer = instance_double(
      OsCtld::DistConfig::NixOSResolverFile,
      write: true
    )
    allow(distribution).to receive(:volatile_is_systemd?).and_return(false)
    allow(OsCtld::DistConfig::NixOSResolverFile).to receive(:new).and_return(writer)
    allow(OsCtld::ContainerControl::Commands::WithMountns).to receive(:run!) do |_ct, **opts|
      opts.fetch(:block).call
    end

    distribution.post_mount(
      ns_pid: 123,
      mnt_ns: :mount_namespace,
      rootfs_mount: '/trusted/root',
      root_dir: :root_directory
    )

    expect(writer).to have_received(:write).with(payload)
    expect(OsCtld::ContainerControl::Commands::WithMountns).to have_received(:run!).with(
      ct,
      ns_pid: 123,
      mnt_ns: :mount_namespace,
      root_dir: :root_directory,
      block: instance_of(Proc)
    )
  end

  it 'treats an empty resolver list as unconfigured' do
    allow(ct).to receive(:dns_resolvers).and_return([])
    allow(distribution).to receive(:volatile_is_systemd?).and_return(false)
    allow(OsCtld::ContainerControl::Commands::WithMountns).to receive(:run!)

    distribution.post_mount(
      ns_pid: 123,
      mnt_ns: :mount_namespace,
      rootfs_mount: '/trusted/root',
      root_dir: :root_directory
    )

    expect(OsCtld::ContainerControl::Commands::WithMountns).not_to have_received(:run!)
  end

  context 'with impermanence' do
    let(:ct_state) { super().merge(impermanence: Object.new) }

    it 'installs the init link and runtime handoff in the same mounted /run view' do
      writer = instance_double(
        OsCtld::DistConfig::NixOSResolverFile,
        write: true
      )
      allow(distribution).to receive(:volatile_is_systemd?).and_return(false)
      allow(distribution).to receive(:configure_impermanence_init)
      allow(OsCtld::DistConfig::NixOSResolverFile).to receive(:new).and_return(writer)
      allow(OsCtld::ContainerControl::Commands::WithMountns).to receive(:run!) do |_ct, **opts|
        opts.fetch(:block).call
      end

      distribution.post_mount(
        ns_pid: 123,
        mnt_ns: :mount_namespace,
        rootfs_mount: '/trusted/root',
        root_dir: :root_directory
      )

      expect(distribution).to have_received(:configure_impermanence_init)
      expect(writer).to have_received(:write).with(payload)
    end

    it 'configures init without a runtime handoff when resolvers are unset' do
      writer = instance_double(
        OsCtld::DistConfig::NixOSResolverFile,
        write: true
      )
      allow(ct).to receive(:dns_resolvers).and_return([])
      allow(distribution).to receive(:volatile_is_systemd?).and_return(false)
      allow(distribution).to receive(:configure_impermanence_init)
      allow(OsCtld::DistConfig::NixOSResolverFile).to receive(:new).and_return(writer)
      allow(OsCtld::ContainerControl::Commands::WithMountns).to receive(:run!) do |_ct, **opts|
        opts.fetch(:block).call
      end

      distribution.post_mount(
        ns_pid: 123,
        mnt_ns: :mount_namespace,
        rootfs_mount: '/trusted/root',
        root_dir: :root_directory
      )

      expect(distribution).to have_received(:configure_impermanence_init)
      expect(writer).not_to have_received(:write)
    end
  end
end
