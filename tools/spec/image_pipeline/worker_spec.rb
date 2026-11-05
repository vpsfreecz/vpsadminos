require_relative '../spec_helper'
require_relative '../../image_pipeline/worker'

RSpec.describe ImagePipeline::Worker do
  it 'keeps generic OsVm loading independent of image-specific policy' do
    script = "require 'osvm'; abort 'image policy loaded' if defined?(ImagePipeline) || OsVm.const_defined?(:ImageBuildWorker) || OsVm.const_defined?(:ImageBuildPool)"
    output, status = Open3.capture2e(RbConfig.ruby, '-I', File.join(REPO_ROOT, 'osvm/lib'),
                                     '-I', File.join(REPO_ROOT, 'libosctl/lib'), '-e', script)
    expect(status.success?).to be(true), output
  end

  it 'renders admitted CPU counts consistently from the evaluated worker closure for two and three CPUs', :nix do
    expression = <<~NIX
      map (cpus: (import #{REPO_ROOT}/tools/image-pipeline.nix {
        memoryMiB = 8192; inherit cpus; diskSize = "32G";
      }).text) [ 2 3 ]
    NIX
    json, error, status = Open3.capture3('timeout', '120s', 'nix', 'eval', '--impure', '--json', '--expr', expression)
    expect(status.success?).to be(true), error
    with_tmpdir do |dir|
      JSON.parse(json).zip([2, 3]).each do |text, cpus|
        raw = JSON.parse(text).fetch('machines').fetch('machine')
        config = OsVm::MachineConfig.from_config(raw)
        expect(config.cpus).to eq(cpus)
        expect(config.cpu.cores * config.cpu.threads * config.cpu.sockets).to eq(cpus)
        machine = build_vpsadminos_machine(dir: File.join(dir, cpus.to_s), config:)
        begin
          command = machine.send(:qemu_command)
          expect(command.fetch(command.index('-smp') + 1)).to eq("cpus=#{cpus},cores=#{cpus},threads=1,sockets=1")
        ensure
          machine.finalize
          machine.cleanup
        end
      end
    end
  end

  it 'constructs isolated workers through the real machine parser without forwarding ports or sharing inherited paths' do
    with_tmpdir do |dir|
      source = File.join(dir, 'source')
      FileUtils.mkdir_p(source)
      raw = machine_config_hash(
        'memory' => 8192,
        'cpus' => 2,
        'disks' => [{ 'device' => 'images.img', 'type' => 'file', 'size' => '32G' }],
        'networks' => [{ 'type' => 'user', 'opts' => { 'network' => '192.0.2.0/24', 'host' => '192.0.2.2',
                                                       'dns' => '192.0.2.3', 'hostForward' => 'tcp::2222-:22' } }],
        'sharedFileSystems' => { 'inherited' => '/private/host-state' }
      )
      original = Marshal.load(Marshal.dump(raw))
      machines = []
      workers = []
      allow(OsVm::VpsadminosMachine).to receive(:new).and_wrap_original do |constructor, *args|
        machine = constructor.call(*args)
        # Exercise actual construction and QEMU rendering, but never start a
        # process, open a VM socket or execute a guest command in this spec.
        allow(machine).to receive_messages(start: machine, wait_for_boot: machine,
                                           wait_for_osctl_pool: machine, wait_until_online: machine)
        allow(machine).to receive(:succeeds).and_return([0, ''])
        machines << machine
        machine
      end
      begin
        2.times do |index|
          workers << described_class.new(index, config: raw, root: dir, source: 'a' * 40,
                                                source_dir: source, bind: ->(*) {})
        end
        expect(raw).to eq(original)
        expect(machines.map { |machine| machine.send(:config) }).to all(be_a(OsVm::VpsadminosMachineConfig))
        expect(machines.map { |machine| machine.send(:config).networks.first.mac }.uniq.length).to eq(2)
        machines.each_with_index do |machine, index|
          config = machine.send(:config)
          expect(config.networks.length).to eq(1)
          expect(config.networks.first).to be_a(OsVm::MachineConfig::UserNetwork)
          command = machine.send(:qemu_command)
          expect(command).to include('user,id=net0,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3')
          expect(command.join(' ')).not_to include('hostfwd=', '192.0.2.', '/private/host-state')
          expect(config.shared_filesystems).to eq('pipelineSource' => source,
                                                  'pipelineFiles' => File.join(dir, "worker-#{index}/exports"))
          expect(machine).to have_received(:succeeds).with(
            'mkdir -p /mnt/pipelineSource && mount -t virtiofs -o ro pipelineSource /mnt/pipelineSource'
          )
          expect(machine).to have_received(:succeeds).with(
            'mkdir -p /mnt/pipelineFiles && mount -t virtiofs  pipelineFiles /mnt/pipelineFiles'
          )
        end
        expect(machines.map { |machine| machine.send(:disk_path, 'images.img') }.uniq.length).to eq(2)
        expect(machines.map { |machine| machine.send(:shell_socket_path) }.uniq.length).to eq(2)
        expect(machines.map { |machine| machine.send(:shared_filesystems).fetch('vmSharedDir') }.uniq.length).to eq(2)
      ensure
        workers.each(&:close)
      end
    end
  end
end
