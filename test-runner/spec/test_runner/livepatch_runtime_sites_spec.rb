# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'shellwords'

RSpec.describe TestRunner::TestEvaluator do
  let(:digest) { 'a' * 64 }
  let(:record) do
    contracts = {
      'svm_entry' => %w[svm_vcpu_run entry_hold preprologue],
      'nft_insert_entry' => %w[nft_pipapo_insert entry_hold preprologue],
      'sunrpc_worker_entry' => %w[xs_tcp_tls_setup_socket entry_hold preprologue],
      'fuse_finish' => %w[fuse_copy_page callee_entry_hold observe_only fuse_ref_page],
      'sunrpc_shadow_alloc' => %w[xs_connect call_observe observe_only],
      'sunrpc_callback_claim' => %w[vpsadminos_sunrpc_tls_drain call_observe observe_only],
      'sunrpc_callback_release' => %w[vpsadminos_sunrpc_cb_release call_observe observe_only],
      'inet_frag_timer' => %w[inet_frag_find call_observe observe_only inet_frag_create],
      'tcp_mtu_size' => %w[tcp_write_xmit tcp_size_observe observe_only tcp_mtu_probe]
    }
    sites = contracts.to_h do |name, (symbol, kind, frame, inline)|
      [name, {
        'object' => 'livepatch_7', 'symbol' => symbol, 'symbol_pos' => 0,
        'section' => '.text', 'symbol_size' => 1024, 'offset' => 32,
        'instruction_length' => 5, 'kind' => kind, 'frame' => frame,
        'inline' => inline, 'registers' => { 'arg0' => { 'register' => 'rdi', 'width' => 64 } }
      }]
    end
    {
      'sunrpc_shadow_alloc' => 'klp_shadow_alloc',
      'sunrpc_callback_claim' => 'cancel_delayed_work_sync',
      'sunrpc_callback_release' => 'klp_shadow_free',
      'inet_frag_timer' => 'mod_timer'
    }.each do |name, symbol|
      sites.fetch(name)['callee'] = { 'object' => 'vmlinux', 'symbol' => symbol, 'symbol_pos' => 0 }
    end
    sites.fetch('fuse_finish').merge!(
      'return_offset' => 37,
      'callee' => {
        'object' => 'fuse', 'symbol' => 'fuse_copy_finish', 'symbol_pos' => 1,
        'section' => '.text', 'symbol_size' => 100, 'offset' => 5,
        'instruction_length' => 1, 'frame' => 'preprologue'
      }
    )
    sites.fetch('tcp_mtu_size')['registers'] = {
      'needed' => { 'register' => 'rax', 'width' => 64 },
      'reordering' => { 'register' => 'rbx', 'width' => 32 },
      'mss' => { 'register' => 'r15', 'width' => 32 }
    }
    {
      'schema_version' => 1, 'module_sha256' => digest,
      'elf' => { 'elf_class' => 64, 'machine' => 'EM_X86_64', 'build_id' => '123abc' },
      'abi' => { 'inet_frag_node' => 0, 'inet_frag_timer' => 56, 'inet_frag_lock' => 96,
                 'sock_xprt_connect_worker' => 1600 },
      'sites' => sites
    }
  end

  let(:consumer) do
    source = File.join(REPO_ROOT, 'tests/suite/kernel/livepatch-6.12.95-common.nix')
    methods = File.read(source).scan(/^    def self\..*?^    end$/m).join("\n")
    raise 'missing livepatch runtime methods' if methods.empty?

    klass = Class.new
    klass.extend(RSpec::Matchers)
    klass.const_set(:SITE_RECORD, record)
    klass.const_set(:CORRECTED_SHA256, digest)
    klass.const_set(:CORRECTED_NAME, 'livepatch_7')
    klass.const_set(:PROBE_PARAMETERS, '/probe')
    klass.const_set(:BOOT_FUSE_REF_PAGE_FINISH_RETURN_OFFSET, 0x36e)
    klass.const_set(:TCP_MTU_TRACE, '/trace/tcp')
    klass.const_set(:TCP_MTU_EVENT, 'lp95_tcp/size_needed')
    klass.class_eval(methods, source)
    klass
  end

  let(:fragment_consumer) do
    source = File.join(REPO_ROOT, 'tests/suite/kernel/livepatch-inet-frag.nix')
    methods = File.read(source).scan(/^      def (?:validate_site_record|symbol_address)\b.*?^      end$/m)
    raise 'missing fragment runtime methods' unless methods.length == 2

    klass = Class.new
    klass.const_set(:SITE_RECORD, record)
    klass.const_set(:MODULE_SHA256, digest)
    klass.class_eval { attr_accessor :machine }
    klass.class_eval(methods.join("\n"), source)
    klass.new
  end

  let(:kallsyms) do
    <<~SYMBOLS
      ffffffff92f7fd20 T inet_frag_find
      ffffffff92f7fd20 u inet_frag_find [livepatch_7]
      ffffffffc0001000 t inet_frag_find [unrelated]
      ffffffffc0002000 t inet_frag_find [livepatch_70]
      ffffffffc1c91f50 t inet_frag_find [livepatch_7]
    SYMBOLS
  end

  def with_kallsyms_machine(contents)
    with_tmpdir do |directory|
      path = File.join(directory, 'kallsyms')
      File.write(path, contents)
      machine = instance_double(OsVm::Machine)
      allow(machine).to receive(:succeeds) do |command|
        output, error, status = Open3.capture3(
          'bash', '-c', command.sub('/proc/kallsyms', Shellwords.escape(path))
        )
        raise "symbol query failed: #{error}" unless status.success?

        [status.exitstatus, output]
      end
      yield machine
    end
  end

  def lookup_kallsyms(target, machine, symbol, module_name = nil, position: 0)
    if target == :consumer
      Integer(consumer.symbol_address(machine, symbol, module_name, position:), 0)
    else
      fragment_consumer.machine = machine
      fragment_consumer.symbol_address(symbol, module_name)
    end
  end

  %i[consumer fragment_consumer].each do |target|
    %w[u U].each do |import_type|
      it "selects the target definition beside a #{import_type} import and other scopes in #{target}" do
        symbols = kallsyms.sub(' u inet_frag_find ', " #{import_type} inet_frag_find ")
        with_kallsyms_machine(symbols) do |machine|
          expect(lookup_kallsyms(target, machine, 'inet_frag_find', 'livepatch_7')).to eq(0xffffffffc1c91f50)
        end
      end

      it "rejects a #{import_type} module import with no target definition in #{target}" do
        symbols = kallsyms.lines[0...-1].join.sub(' u inet_frag_find ', " #{import_type} inet_frag_find ")
        with_kallsyms_machine(symbols) do |machine|
          expect { lookup_kallsyms(target, machine, 'inet_frag_find', 'livepatch_7') }.to raise_error(RuntimeError)
        end
      end
    end

    it "keeps the native lookup outside module namespaces in #{target}" do
      with_kallsyms_machine(kallsyms) do |machine|
        expect(lookup_kallsyms(target, machine, 'inet_frag_find')).to eq(0xffffffff92f7fd20)
      end
    end

    it "rejects an absent module despite other same-name definitions in #{target}" do
      with_kallsyms_machine(kallsyms) do |machine|
        expect { lookup_kallsyms(target, machine, 'inet_frag_find', 'missing') }.to raise_error(RuntimeError)
      end
    end

    [0xffffffffc1c91f50, 0xffffffffc1c92f50].each do |address|
      it "rejects duplicate defined rows including address #{address.to_s(16)} in #{target}" do
        symbols = kallsyms + "#{address.to_s(16)} t inet_frag_find [livepatch_7]\n"
        with_kallsyms_machine(symbols) do |machine|
          expect { lookup_kallsyms(target, machine, 'inet_frag_find', 'livepatch_7') }.to raise_error(RuntimeError)
        end
      end
    end
  end

  it 'preserves a defined module data symbol used by the SVM witness' do
    with_kallsyms_machine("1000 b x2avic_enabled [kvm_amd]\n") do |machine|
      expect(lookup_kallsyms(:consumer, machine, 'x2avic_enabled', 'kvm_amd')).to eq(0x1000)
    end
  end

  [0, 1].each do |position|
    %w[u U].each do |import_type|
      it "resolves the unique original FUSE definition beside #{import_type} at position #{position}" do
        symbols = "1000 #{import_type} fuse_copy_finish [fuse]\n2000 t fuse_copy_finish [fuse]\n"
        with_kallsyms_machine(symbols) do |machine|
          expect(lookup_kallsyms(:consumer, machine, 'fuse_copy_finish', 'fuse', position:)).to eq(0x2000)
        end
      end
    end
  end

  it 'rejects ambiguous original FUSE definitions even at explicit position one' do
    with_kallsyms_machine("1000 t fuse_copy_finish [fuse]\n2000 t fuse_copy_finish [fuse]\n") do |machine|
      expect { lookup_kallsyms(:consumer, machine, 'fuse_copy_finish', 'fuse', position: 1) }
        .to raise_error(/ambiguous kernel symbol/)
    end
  end

  it 'rejects an unsupported symbol position' do
    machine = instance_double(OsVm::Machine)

    expect { consumer.symbol_address(machine, 'fuse_copy_finish', 'fuse', position: 2) }
      .to raise_error(/invalid symbol position/)
  end

  %i[consumer fragment_consumer].each do |target|
    %w[inet_frag_find inet_frag_create].each do |symbol|
      it "accepts the supported #{symbol} owner in #{target}" do
        record.fetch('sites').fetch('inet_frag_timer')['symbol'] = symbol

        expect { public_send(target).validate_site_record }.not_to raise_error
      end
    end

    %w[inet_frag_alloc inet_frag_create.isra.0].each do |symbol|
      it "rejects the unsupported #{symbol} owner in #{target}" do
        record.fetch('sites').fetch('inet_frag_timer')['symbol'] = symbol

        expect { public_send(target).validate_site_record }.to raise_error(RuntimeError)
      end
    end
  end

  it 'accepts a complete current-module record and supported register allocation' do
    record.fetch('sites').fetch('tcp_mtu_size').fetch('registers').fetch('needed')['register'] = 'r12'

    expect { consumer.validate_site_record }.not_to raise_error
  end

  {
    'wrong module digest' => ->(data) { data['module_sha256'] = 'b' * 64 },
    'unknown schema' => ->(data) { data['schema_version'] = 2 },
    'missing witness' => ->(data) { data.fetch('sites').delete('svm_entry') },
    'out-of-bounds site' => ->(data) { data.fetch('sites').fetch('svm_entry')['offset'] = 1024 },
    'unsafe hold frame' => ->(data) { data.fetch('sites').fetch('svm_entry')['frame'] = 'interior' },
    'wrong FUSE namespace' => ->(data) { data.fetch('sites').fetch('fuse_finish').fetch('callee')['object'] = 'livepatch_7' },
    'wrong FUSE ordinal' => ->(data) { data.fetch('sites').fetch('fuse_finish').fetch('callee')['symbol_pos'] = 0 },
    'wrong FUSE return PC' => ->(data) { data.fetch('sites').fetch('fuse_finish')['return_offset'] = 36 },
    'arbitrary register program' => ->(data) { data.fetch('sites').fetch('tcp_mtu_size').fetch('registers').fetch('needed')['register'] = 'rax;exit' },
    'narrow TCP result' => ->(data) { data.fetch('sites').fetch('tcp_mtu_size').fetch('registers').fetch('needed')['width'] = 32 },
    'contradictory structure layout' => ->(data) { data.fetch('abi')['inet_frag_lock'] = 32 }
  }.each do |description, mutate|
    it "rejects #{description} before installing any address" do
      mutate.call(record)

      expect { consumer.validate_site_record }.to raise_error(RuntimeError)
    end
  end

  it 'requires one runtime original-callee symbol even for its explicit first position' do
    machine = instance_double(OsVm::Machine, succeeds: [0, "0x1000\n0x2000\n"])

    expect { consumer.symbol_address(machine, 'fuse_copy_finish', 'fuse', position: 1) }
      .to raise_error(/ambiguous kernel symbol/)
  end

  it 'resolves the original FUSE hold and the selected current caller return PC' do
    values = { 'fuse_copy_page' => '0x1000', 'fuse_copy_finish' => '0x8000' }
    writes = {}
    machine = instance_double(OsVm::Machine)
    allow(machine).to receive(:succeeds) do |command|
      symbol = values.keys.find { |name| command.include?("$3 == \"#{name}\"") }
      raise "unexpected lookup: #{command}" unless symbol

      [0, "#{values.fetch(symbol)}\n"]
    end
    allow(machine).to receive(:all_succeed) do |*commands|
      commands.each do |command|
        value, parameter = command.match(%r{\Aecho (\S+) > /probe/(\w+)\z}).captures
        writes[parameter] = Integer(value, 0)
      end
    end
    allow(consumer).to receive(:assert_kprobe_site)

    consumer.validate_site_record
    consumer.set_fuse_finish_probe(machine, 'livepatch_7')

    expect(writes).to include('probe_caller_return' => 0x1025, 'probe_address' => 0x8005)
    expect(consumer).to have_received(:assert_kprobe_site).with(machine, 'fuse_copy_finish', 5, true)
  end

  def trace_machine(trace:, profile: '1 0', stats: "overrun: 0\ncommit overrun: 0\n")
    machine = instance_double(OsVm::Machine, all_succeed: nil)
    allow(machine).to receive(:succeeds) do |command|
      output = if command == 'cat /trace/tcp/trace'
                 trace
               elsif command.include?('/per_cpu/')
                 stats
               elsif command.include?('/kprobe_profile')
                 profile
               else
                 raise "unexpected trace command: #{command}"
               end
      [0, output]
    end
    machine
  end

  it 'accepts the independent TCP wide-value property' do
    machine = trace_machine(trace: 'sender size_needed: needed=2199023256064 reordering=4294967295 mss=512')

    expect { consumer.assert_tcp_mtu_trace(machine) }.not_to raise_error
  end

  [
    ['wrapped arithmetic', 'size_needed: needed=1400 reordering=4294967295 mss=512', '1 0'],
    ['wrong socket precondition', 'size_needed: needed=2199023256064 reordering=3 mss=512', '1 0'],
    ['zero MSS', 'size_needed: needed=2199023256064 reordering=4294967295 mss=0', '1 0'],
    ['missing comparison samples', '', '0 0'],
    ['missed comparisons', 'size_needed: needed=2199023256064 reordering=4294967295 mss=512', '1 1']
  ].each do |description, trace, profile|
    it "rejects #{description}" do
      machine = trace_machine(trace: trace, profile: profile)

      expect { consumer.assert_tcp_mtu_trace(machine) }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
    end
  end

  it 'rejects a wrapped TCP trace ring' do
    machine = trace_machine(
      trace: 'size_needed: needed=2199023256064 reordering=4294967295 mss=512',
      stats: "overrun: 1\n"
    )

    expect { consumer.assert_tcp_mtu_trace(machine) }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
  end

  def completed_transfer(directory, mode)
    File.write(File.join(directory, 'client.pid'), '2147483647')
    File.write(File.join(directory, 'server.pid'), '2147483647')
    File.write(File.join(directory, 'result'), '8388608')
    File.write(File.join(directory, 'server.status'), mode == :failed_receiver ? '1' : '0') unless mode == :sender_only
    payload = "\0" * 8_388_608
    File.binwrite(File.join(directory, 'expected'), payload)
    payload = payload[0...-1] if mode == :truncated
    payload.setbyte(1_048_576, 1) if mode == :corrupt
    File.binwrite(File.join(directory, 'received'), payload)
  end

  %i[intact truncated corrupt failed_receiver sender_only].each do |mode|
    it "#{mode == :intact ? 'accepts' : 'rejects'} #{mode} receiver evidence" do
      with_tmpdir do |directory|
        completed_transfer(directory, mode)
        consumer.const_set(:TCP_STATE, directory)
        machine = instance_double(OsVm::Machine)
        execute = lambda do |command|
          output, error, status = Open3.capture3('bash', '-c', command)
          raise "transfer assertion failed: #{output}#{error}" unless status.success?

          [0, output]
        end
        allow(machine).to receive(:succeeds, &execute)
        allow(machine).to receive(:wait_until_succeeds) { |command, **| execute.call(command) }
        allow(machine).to receive(:all_succeed) { |*commands| commands.each(&execute) }

        if mode == :intact
          expect { consumer.release_legacy_tcp_socket(machine) }.not_to raise_error
        else
          expect { consumer.release_legacy_tcp_socket(machine) }.to raise_error(/transfer assertion failed/)
        end
      end
    end
  end
end
