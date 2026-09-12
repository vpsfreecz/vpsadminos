# frozen_string_literal: true

require 'osctld/container_control/commands/cat'
require 'osctld/container_control/result'
require 'tempfile'

RSpec.describe OsCtld::ContainerControl::Commands::Cat do
  describe described_class::Frontend do
    subject(:frontend) do
      Class.new(described_class) do
        attr_accessor :exec_result, :exec_options

        def exec_runner(**opts)
          self.exec_options = opts
          exec_result
        end
      end.new(OsCtld::ContainerControl::Commands::Cat, ct)
    end

    let(:ct) { Struct.new(:running?).new(true) }

    it 'places the reader in the attach cgroup without a root numeric-PID setns' do
      frontend.exec_result = OsCtld::ContainerControl::Result.new(true, data: {})

      expect(frontend.execute(files: ['/etc/hosts'], stdout: :output)).to eq({})
      expect(frontend.exec_options).to eq(
        args: [['/etc/hosts']], stdout: :output, switch_extra_namespaces: false
      )
    end

    it 'rejects stopped containers before launching a reader' do
      ct[:running?] = false
      expect do
        frontend.execute(files: ['/etc/hosts'], stdout: :output)
      end.to raise_error(OsCtld::ContainerControl::Error, 'container not running')
      expect(frontend.exec_options).to be_nil
    end
  end

  describe described_class::Runner do
    subject(:runner) do
      Class.new(described_class) do
        attr_accessor :attached_ct

        def lxc_ct
          attached_ct
        end
      end.new(
        pool: 'tank', id: 'ct1', lxc_home: '/var/lib/lxc',
        user_home: '/home/ct1', log_file: '/ct.log', stdout: output
      )
    end

    let(:lxc_ct) { instance_double(LXC::Container) }
    let(:output) { Tempfile.new('cat-output') }

    after { output.close! }

    before do
      runner.attached_ct = lxc_ct
      allow(lxc_ct).to receive(:attach) do |_opts, &block|
        Process.fork do
          block.call
          exit!(0)
        end
      end
    end

    it 'streams binary files in order and retains each missing-file error' do
      with_tmpdir do |dir|
        path = File.join(dir, 'data')
        missing = File.join(dir, 'missing')
        File.binwrite(path, "a\x00b\xff")

        ret = runner.execute([path, missing, path])

        expect(ret[:status]).to be(true)
        expect(lxc_ct).to have_received(:attach).with(
          wait: false, flags: OsCtld::ContainerControl::Runner::LXC_ATTACH_FLAGS, initial_cwd: '/'
        )
        expect(ret[:output].keys).to eq([missing])
        expect(ret[:output][missing]).to include('No such file or directory')
        output.rewind
        expect(output.binmode.read).to eq("a\x00b\xffa\x00b\xff".b)
      end
    end

    it 'drains per-file errors larger than the pipe buffer before reaping' do
      with_tmpdir do |dir|
        files = Array.new(2000) { |i| File.join(dir, "missing-#{i}") }
        ret = runner.execute(files)

        expect(ret[:status]).to be(true)
        expect(ret[:output].keys).to eq(files)
        expect(ret[:output].to_json.bytesize).to be > 65_536
      end
    end

    it 'reports attachment rejection instead of waiting on an unrelated child' do
      allow(lxc_ct).to receive(:attach).and_return(-1)
      allow(Process).to receive(:wait).and_call_original
      allow(Process).to receive(:wait2).and_call_original

      expect(runner.execute(['/etc/hosts'])).to eq(status: false, message: 'unable to attach file reader')
      expect(Process).not_to have_received(:wait)
      expect(Process).not_to have_received(:wait2)
    end

    it 'reports an attached reader failure without parsing an empty result' do
      allow(lxc_ct).to receive(:attach) { Process.fork { exit!(3) } }

      expect(runner.execute(['/etc/hosts'])).to eq(status: false, message: 'file reader exited with 3')
    end

    it 'rejects a successful child that did not send its result' do
      allow(lxc_ct).to receive(:attach) { Process.fork { exit!(0) } }

      expect(runner.execute(['/etc/hosts'])).to eq(status: false, message: 'file reader returned an invalid result')
    end
  end
end
