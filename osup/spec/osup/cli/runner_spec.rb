# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsUp::Cli::Runner do
  subject(:command) { build_command(described_class, args:) }

  let(:args) { [] }

  after do
    $MIGRATION_ID = nil
    $POOL = nil
    $DATASET = nil
    $runner_loaded = nil
  end

  it 'validates required arguments' do
    expect { command.run }
      .to raise_error(GLI::BadCommandLine, 'missing argument <pool>')
  end

  it 'loads the migration and executes the selected action script for up' do
    with_tmpdir do |dir|
      script_path = File.join(dir, 'up.rb')
      migration = instance_double(OsUp::Migration, id: 123, action_script: script_path)

      File.write(script_path, "$runner_loaded = [$MIGRATION_ID, $POOL, $DATASET]\n")
      command.args.push('tank', 'tank/osctl', '20180711154030-test', 'up')

      allow(OsUp).to receive(:migration_dir).and_return('/migrations')
      allow(OsUp::Migration).to receive(:load)
        .with('/migrations', '20180711154030-test')
        .and_return(migration)
      allow(Process).to receive(:setproctitle)

      command.run

      expect(OsUp::Migration).to have_received(:load).with('/migrations', '20180711154030-test')
      expect(Process).to have_received(:setproctitle).with('osup: tank 123 up')
      expect($runner_loaded).to eq([123, 'tank', 'tank/osctl'])
    end
  end

  it 'sets the process title using the selected action for down' do
    with_tmpdir do |dir|
      script_path = File.join(dir, 'down.rb')
      migration = instance_double(OsUp::Migration, id: 123, action_script: script_path)

      File.write(script_path, "$runner_loaded = [$MIGRATION_ID, $POOL, $DATASET]\n")
      command.args.push('tank', 'tank/osctl', '20180711154030-test', 'down')

      allow(OsUp).to receive(:migration_dir).and_return('/migrations')
      allow(OsUp::Migration).to receive(:load)
        .with('/migrations', '20180711154030-test')
        .and_return(migration)
      allow(Process).to receive(:setproctitle)

      command.run

      expect(Process).to have_received(:setproctitle).with('osup: tank 123 down')
      expect($runner_loaded).to eq([123, 'tank', 'tank/osctl'])
    end
  end
end
