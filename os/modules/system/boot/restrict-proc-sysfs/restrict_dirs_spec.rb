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
end
