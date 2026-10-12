# frozen_string_literal: true

require_relative 'restrict-dirs'

RSpec.describe RestrictDirs do
  subject(:restrict_dirs) { described_class.allocate }

  let(:grant) { Command.new('grant', ['/sys/example/*']) }
  let(:restrict) { Command.new('restrict', ['/sys/example/*']) }
  let(:skip) { Command.new('skip', ['/sys/example/*']) }

  it 'uses the last matching restrict rule for policy and chmod effects' do
    restrict_dirs.instance_variable_set('@cmds', [grant, restrict])
    allow(Dir).to receive(:glob).and_return(['/sys/example/item'])
    allow(grant).to receive(:execute)

    operations = restrict_dirs.send(:resolve_operations)
    policy = restrict_dirs.send(:build_kernfs_filter_policy, operations)
    restrict_dirs.send(:apply_grants, operations)

    expect(policy).to end_with("sysfs hide any /example/item/**\n")
    expect(grant).not_to have_received(:execute)
  end

  it 'uses the last matching grant rule for policy and chmod effects' do
    restrict_dirs.instance_variable_set('@cmds', [restrict, grant])
    allow(Dir).to receive(:glob).and_return(['/sys/example/item'])
    allow(grant).to receive(:execute)

    operations = restrict_dirs.send(:resolve_operations)
    policy = restrict_dirs.send(:build_kernfs_filter_policy, operations)
    restrict_dirs.send(:apply_grants, operations)

    expect(policy).to end_with("sysfs allow any /example/item/**\n")
    expect(grant).to have_received(:execute).with('/sys/example/item').once
  end

  it 'does not retain an earlier grant when the last matching rule is skip' do
    restrict_dirs.instance_variable_set('@cmds', [grant, skip])
    allow(Dir).to receive(:glob).and_return(['/sys/example/item'])
    allow(grant).to receive(:execute)

    operations = restrict_dirs.send(:resolve_operations)
    policy = restrict_dirs.send(:build_kernfs_filter_policy, operations)
    restrict_dirs.send(:apply_grants, operations)

    expect(policy).to end_with("sysfs allow any /example/item/**\n")
    expect(grant).not_to have_received(:execute)
  end

  describe 'policy installation' do
    let(:active) { '/proc/vpsadminos/kernfs_filter/active' }
    let(:policy) { "version 1\nscope noninit-userns\nsysfs hide any /example/**\n" }

    before do
      allow(File).to receive(:write)
    end

    it 'does not replace an exactly matching active policy' do
      allow(File).to receive(:read).with(active).and_return(policy)

      expect(restrict_dirs.send(:install_kernfs_filter_policy, policy)).to be(true)
      expect(File).not_to have_received(:write)
    end

    it 'replaces a different active policy' do
      allow(File).to receive(:read).with(active).and_return("version 1\nscope noninit-userns\n")

      expect(restrict_dirs.send(:install_kernfs_filter_policy, policy)).to be(true)
      expect(File).to have_received(:write).with(described_class::KERNFS_FILTER_REPLACE, policy)
    end

    [Errno::ENOENT, Errno::EACCES, IOError].each do |error|
      it "still installs the policy when reading active rules raises #{error}" do
        allow(File).to receive(:read).with(active).and_raise(error)

        expect(restrict_dirs.send(:install_kernfs_filter_policy, policy)).to be(true)
        expect(File).to have_received(:write).with(described_class::KERNFS_FILTER_REPLACE, policy)
      end
    end

    it 'reports installation failure rather than treating a read error as success' do
      allow(File).to receive(:read).with(active).and_raise(Errno::ENOENT)
      allow(File).to receive(:write).with(described_class::KERNFS_FILTER_REPLACE, policy).and_raise(Errno::EACCES)

      expect(restrict_dirs.send(:install_kernfs_filter_policy, policy)).to be(false)
    end

    it 'still applies grants when the active policy already matches' do
      restrict_dirs.instance_variable_set('@cmds', [grant])
      allow(Dir).to receive(:glob).and_return(['/sys/example/item'])
      allow(File).to receive(:writable?).with(described_class::KERNFS_FILTER_REPLACE).and_return(true)
      allow(File).to receive(:read).with(active).and_return(
        "version 1\nscope noninit-userns\nsysfs allow any /example/item/**\n"
      )
      allow(grant).to receive(:execute)

      restrict_dirs.run
      expect(File).not_to have_received(:write)
      expect(grant).to have_received(:execute).with('/sys/example/item')
    end
  end
end
