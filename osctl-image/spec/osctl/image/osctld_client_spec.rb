# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::OsCtldClient do
  subject(:wrapper) { described_class.new }

  let(:client) { FakeClientHelpers::ClientDouble.new(cmd_data:, responses:) }
  let(:cmd_data) { {} }
  let(:responses) { [] }

  before do
    stub_osctld_client(client)
  end

  it 'opens and closes the underlying client for non-batched calls' do
    allow(client).to receive(:cmd_data!).with(:ct_list).and_return([])

    wrapper.list_containers

    expect(client.calls).to include([:open], [:close])
  end

  it 'reuses one connection inside batch and closes it on exit' do
    allow(client).to receive(:cmd_data!).with(:ct_list).and_return([], [])

    wrapper.batch do |batch|
      batch.list_containers
      batch.list_containers
    end

    expect(client.calls.count([:open])).to eq(1)
    expect(client.calls.count([:close])).to eq(1)
  end

  it 'ignores OsCtl::Client::Error inside ignore_error' do
    expect do
      wrapper.ignore_error { raise OsCtl::Client::Error, 'boom' }
    end.not_to raise_error
  end

  it 'does not ignore unrelated errors' do
    expect do
      wrapper.ignore_error { raise ArgumentError, 'boom' }
    end.to raise_error(ArgumentError, 'boom')
  end

  {
    list_containers: { args: [], kwargs: {}, cmd: :ct_list, opts: {} },
    create_container_from_repo: {
      args: %w[ct1 alpine 3.20 x86_64 vendor minimal],
      kwargs: {},
      cmd: :ct_create,
      opts: {
        id: 'ct1',
        image: {
          distribution: 'alpine',
          version: '3.20',
          arch: 'x86_64',
          vendor: 'vendor',
          variant: 'minimal'
        },
        map_mode: 'native'
      }
    },
    create_container_from_file: {
      args: %w[ct1 /tmp/image.tar],
      kwargs: {},
      cmd: :ct_import,
      opts: {
        as_id: 'ct1',
        file: File.absolute_path('/tmp/image.tar'),
        map_mode: 'native'
      }
    },
    reinstall_container_from_image: {
      args: %w[ct1 /tmp/image.tar],
      kwargs: { remove_snapshots: true },
      cmd: :ct_reinstall,
      opts: {
        id: 'ct1',
        remove_snapshots: true,
        type: :image,
        path: File.absolute_path('/tmp/image.tar')
      }
    },
    set_container_attr: {
      args: %w[ct1 a b],
      kwargs: {},
      cmd: :ct_set,
      opts: { id: 'ct1', attrs: { 'a' => 'b' } }
    },
    set_container_dns_resolvers: {
      args: ['ct1', %w[1.1.1.1 8.8.8.8]],
      kwargs: {},
      cmd: :ct_set,
      opts: { id: 'ct1', dns_resolvers: %w[1.1.1.1 8.8.8.8] }
    },
    unset_container_start_menu: {
      args: ['ct1'],
      kwargs: {},
      cmd: :ct_unset,
      opts: { id: 'ct1', start_menu: true }
    },
    set_container_nesting: {
      args: ['ct1'],
      kwargs: {},
      cmd: :ct_set,
      opts: { id: 'ct1', nesting: true }
    },
    start_container: { args: ['ct1'], kwargs: {}, cmd: :ct_start, opts: { id: 'ct1' } },
    stop_container: { args: ['ct1'], kwargs: {}, cmd: :ct_stop, opts: { id: 'ct1' } },
    kill_container: {
      args: ['ct1'],
      kwargs: {},
      cmd: :ct_stop,
      opts: { id: 'ct1', method: 'kill' }
    },
    delete_container: {
      args: ['ct1'],
      kwargs: { prune: true },
      cmd: :ct_delete,
      opts: { id: 'ct1', force: true, prune: true }
    },
    add_netif_bridge: {
      args: %w[ct1 eth0 lxcbr0],
      kwargs: {},
      cmd: :netif_create,
      opts: {
        id: 'ct1',
        name: 'eth0',
        type: 'bridge',
        link: 'lxcbr0',
        dhcp: true
      }
    },
    bind_mount: {
      args: ['ct1', '/src', '/dst'],
      kwargs: { map_ids: false },
      cmd: :ct_mount_create,
      opts: {
        id: 'ct1',
        fs: '/src',
        mountpoint: '/dst',
        type: 'bind',
        opts: 'bind,create=dir',
        automount: false,
        map_ids: false
      }
    },
    activate_mount: {
      args: ['ct1', '/dst'],
      kwargs: {},
      cmd: :ct_mount_activate,
      opts: { id: 'ct1', mountpoint: '/dst' }
    },
    unmount: {
      args: ['ct1', '/dst'],
      kwargs: {},
      cmd: :ct_mount_delete,
      opts: { id: 'ct1', mountpoint: '/dst' }
    },
    user_idmap: {
      args: ['user'],
      kwargs: {},
      cmd: :user_idmap_list,
      opts: { name: 'user', uid: true, gid: true }
    },
    delete_user: {
      args: ['user'],
      kwargs: {},
      cmd: :user_delete,
      opts: { name: 'user' }
    }
  }.each do |method_name, definition|
    it "maps ##{method_name} to the expected osctld command" do
      allow(client).to receive(:cmd_data!).with(definition[:cmd], **definition[:opts]).and_return(:ok)

      expect(wrapper.public_send(method_name, *definition[:args], **definition[:kwargs])).to eq(:ok)
    end
  end

  it 'returns nil from find_container when osctld reports an error' do
    allow(client)
      .to receive(:cmd_data!).with(:ct_show, id: 'missing')
      .and_raise(OsCtl::Client::Error, 'not found')

    expect(wrapper.find_container('missing')).to be_nil
  end

  it 'executes commands through the continuation protocol' do
    allow(client)
      .to receive(:cmd_data!).with(:ct_exec, id: 'ct1', cmd: ['/bin/true'], run: false)
      .and_return('continue')
    allow(client).to receive(:receive_resp)
      .and_return(client_response(status: true, response: { exitstatus: 7 }))

    expect(wrapper.exec('ct1', ['/bin/true'])).to eq(7)
    expect(client.sent_ios.length).to eq(3)
  end

  it 'raises a readable error when exec continuation fails' do
    allow(client)
      .to receive(:cmd_data!).with(:ct_exec, id: 'ct1', cmd: ['/bin/true'], run: false)
      .and_return('stop')

    expect { wrapper.exec('ct1', ['/bin/true']) }
      .to raise_error(RuntimeError, "exec not available: invalid response 'stop'")
  end

  it 'raises a readable error when exec returns an error response' do
    allow(client)
      .to receive(:cmd_data!).with(:ct_exec, id: 'ct1', cmd: ['/bin/true'], run: false)
      .and_return('continue')
    allow(client).to receive(:receive_resp)
      .and_return(client_response(status: false, message: 'exec failed'))

    expect { wrapper.exec('ct1', ['/bin/true']) }.to raise_error(RuntimeError, 'exec failed')
  end

  it 'runs scripts through the continuation protocol' do
    allow(client)
      .to receive(:cmd_data!).with(:ct_runscript, id: 'ct1', script: '/tmp/script', run: false)
      .and_return('continue')
    allow(client).to receive(:receive_resp)
      .and_return(client_response(status: true, response: { exitstatus: 0 }))

    expect(wrapper.runscript('ct1', '/tmp/script')).to eq(0)
    expect(client.sent_ios.length).to eq(3)
  end

  it 'raises a readable error when the runscript continuation marker is missing' do
    allow(client)
      .to receive(:cmd_data!).with(:ct_runscript, id: 'ct1', script: '/tmp/script', run: false)
      .and_return('stop')

    expect { wrapper.runscript('ct1', '/tmp/script') }
      .to raise_error(RuntimeError, "runscript not available: invalid response 'stop'")
  end

  it 'raises a readable error when runscript returns an error response' do
    allow(client)
      .to receive(:cmd_data!).with(:ct_runscript, id: 'ct1', script: '/tmp/script', run: false)
      .and_return('continue')
    allow(client).to receive(:receive_resp)
      .and_return(client_response(status: false, message: 'runscript failed'))

    expect { wrapper.runscript('ct1', '/tmp/script') }.to raise_error(RuntimeError, 'runscript failed')
  end
end
