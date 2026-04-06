# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SvCtl::Cli::Command do
  subject(:command) { described_class.new({}, opts, args) }

  let(:args) { [] }
  let(:opts) { {} }

  describe '#list_all' do
    it 'prints all services with runlevel alignment' do
      service = Struct.new(:name, :runlevels) do
        def <=>(other)
          name <=> other.name
        end
      end.new('sshd', ['default'])

      allow(SvCtl).to receive_messages(
        runlevels: %w[default rescue],
        all_services: [service]
      )

      output = capture_stdout { command.list_all }

      expect(output).to include('sshd')
      expect(output).to include('default')
    end
  end

  describe '#list_services' do
    context 'with --all' do
      let(:opts) { { all: true } }

      it 'prints all services when requested' do
        service = Struct.new(:name, :runlevels) do
          def <=>(other)
            name <=> other.name
          end
        end.new('sshd', ['default'])
        allow(SvCtl).to receive_messages(
          runlevels: %w[default rescue],
          all_services: [service]
        )

        expect(capture_stdout { command.list_services }).to include('sshd')
      end
    end

    context 'without --all' do
      it 'prints the selected runlevel services' do
        service = instance_double(SvCtl::Service)
        allow(service).to receive_messages(name: 'sshd')
        allow(SvCtl).to receive(:runlevel_services).with('current').and_return([service])

        output = capture_stdout { command.list_services }

        expect(output).to eq("sshd\n")
      end
    end
  end

  it 'delegates enable to SvCtl' do
    cmd = described_class.new({}, {}, %w[sshd default])
    allow(SvCtl).to receive(:enable)

    cmd.enable

    expect(SvCtl).to have_received(:enable).with('sshd', 'default')
  end

  it 'delegates disable to SvCtl' do
    cmd = described_class.new({}, {}, %w[sshd default])
    allow(SvCtl).to receive(:disable)

    cmd.disable

    expect(SvCtl).to have_received(:disable).with('sshd', 'default')
  end

  it 'delegates protect to SvCtl' do
    cmd = described_class.new({}, {}, ['sshd'])
    allow(SvCtl).to receive(:protect)

    cmd.protect

    expect(SvCtl).to have_received(:protect).with('sshd')
  end

  it 'delegates unprotect to SvCtl' do
    cmd = described_class.new({}, {}, ['sshd'])
    allow(SvCtl).to receive(:unprotect)

    cmd.unprotect

    expect(SvCtl).to have_received(:unprotect).with('sshd')
  end

  it 'prints protected services' do
    allow(SvCtl).to receive(:protected_services).and_return(%w[sshd nginx])

    output = capture_stdout { command.list_protected }

    expect(output).to eq("sshd\nnginx\n")
  end

  it 'prints runlevels' do
    allow(SvCtl).to receive(:runlevels).and_return(%w[default rescue])

    output = capture_stdout { command.list_runlevels }

    expect(output).to eq("default\nrescue\n")
  end

  it 'prints the current runlevel' do
    allow(SvCtl).to receive(:runlevel).and_return('default')

    output = capture_stdout { command.runlevel }

    expect(output).to eq("default\n")
  end

  it 'delegates switch to SvCtl' do
    cmd = described_class.new({}, {}, ['rescue'])
    allow(SvCtl).to receive(:switch)

    cmd.switch

    expect(SvCtl).to have_received(:switch).with('rescue')
  end

  it 'includes service and runlevel expansions in bash completion' do
    output = capture_stdout { command.gen_bash_completion }

    expect(output).to include('ls -1 /etc/runit/services')
    expect(output).to include('ls -1 /etc/runit/runsvdir | grep -v previous')
  end
end
