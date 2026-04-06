# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::Cli::Command do
  it 'requires a script file argument' do
    expect do
      described_class.new({}, {}, []).script
    end.to raise_error(GLI::BadCommandLine, 'missing argument <file>')
  end

  it 'shifts argv and loads the selected file' do
    with_tmpdir do |dir|
      script = File.join(dir, 'script.rb')
      capture = File.join(dir, 'argv.json')
      File.write(script, "File.write(#{capture.inspect}, JSON.dump(ARGV))")
      stub_const('ARGV', %w[script sample.rb first second])

      described_class.new({}, {}, [script]).script

      expect(ARGV).to eq(%w[first second])
      expect(JSON.parse(File.read(capture))).to eq(%w[first second])
    end
  end
end
