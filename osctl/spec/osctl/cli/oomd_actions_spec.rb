# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Container do
  def command(options)
    build_command(described_class, args: ['a'], gopts: { pool: 'tank' }, opts: options)
  end

  let(:guards) { { 'expected-init-pid' => 42, 'expected-init-start-time' => 123 } }

  %i[stop restart].each do |action|
    it "sends only guarded #{action} and flushes acceptance before completion" do
      cmd = command(guards)
      output = StringIO.new
      allow(cmd).to receive(:puts) { |message| output.puts(message) }
      allow($stdout).to receive(:flush).and_call_original
      allow(cmd).to receive(:osctld_fmt).with(
        :"ct_oomd_#{action}",
        cmd_opts: { id: 'a', pool: 'tank', expected_init_pid: 42, expected_init_start_time: 123, wait: 120 }
      ).and_yield('OOMd expected run accepted pid=42 start=123')
      cmd.oomd_action(action)
      expect(output.string).to include('accepted pid=42 start=123')
      expect($stdout).to have_received(:flush).once
      expect(cmd).to have_received(:osctld_fmt).once
    end

    it "rejects missing guarded #{action} fields in actual CLI parsing before connecting" do
      app = OsCtl::Cli::App.get
      allow(app).to receive(:stderr).and_return(StringIO.new)
      allow(described_class).to receive(:new).and_call_original
      result = app.run(['ct', "oomd-#{action}", 'tank:a'])
      expect(result).not_to eq(0)
      expect(described_class).not_to have_received(:new)
    end
  end

  [nil, 0, -1, '42'].each do |value|
    it "rejects invalid expected PID #{value.inspect} before any daemon command" do
      cmd = command(guards.merge('expected-init-pid' => value))
      allow(cmd).to receive(:osctld_fmt)
      expect { cmd.oomd_action(:restart) }.to raise_error(GLI::BadCommandLine)
      expect(cmd).not_to have_received(:osctld_fmt)
    end
  end

  it 'registers guarded commands and preserves the ordinary and lean top CLI' do
    commands = OsCtl::Cli::App.get.commands[:ct].commands.keys.map(&:to_s)
    expect(commands).to include('stop', 'restart', 'oomd-stop', 'oomd-restart', 'top')
  end
end
