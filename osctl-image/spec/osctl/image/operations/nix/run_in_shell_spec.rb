# frozen_string_literal: true

require 'spec_helper'
require 'shellwords'

RSpec.describe OsCtl::Image::Operations::Nix::RunInShell do
  subject(:op) do
    described_class.new(
      '/tmp/flake.nix',
      ['/path/with space/tool', 'arg with space', 'semi;colon']
    )
  end

  it 'creates wrappers without a Tempfile NameError and shell-escapes the command' do
    exe = op.send(:create_executable)

    expect(File.read(exe.path)).to include(
      "exec #{Shellwords.join(['/path/with space/tool', 'arg with space', 'semi;colon'])}"
    )
  ensure
    exe&.unlink
  end

  it 'shell-escapes the wrapper path when calling nix develop' do
    op_class = Class.new(described_class) do
      class << self
        attr_accessor :fake_exe, :captured
      end

      def create_executable
        self.class.fake_exe
      end

      def syscmd(cmd, opts)
        self.class.captured = [cmd, opts]
        OsCtl::Lib::SystemCommandResult.new(0, '')
      end
    end
    exe = Tempfile.new(['run in shell', '.sh'], '/tmp')
    exe_path = exe.path
    op_class.fake_exe = exe

    op_class.new('/tmp/flake.nix', ['/path/with space/tool', 'arg with space', 'semi;colon']).execute

    expect(op_class.captured[0]).to include("--command #{Shellwords.escape(exe_path)}")
  end

  it 'removes the temporary wrapper in ensure' do
    op_class = Class.new(described_class) do
      class << self
        attr_accessor :fake_exe
      end

      def create_executable
        self.class.fake_exe
      end

      def syscmd(*)
        raise 'boom'
      end
    end
    exe = Tempfile.new(['run in shell', '.sh'], '/tmp')
    exe_path = exe.path
    op_class.fake_exe = exe

    expect do
      op_class.new('/tmp/flake.nix', ['/path/with space/tool', 'arg with space', 'semi;colon']).execute
    end.to raise_error(RuntimeError, 'boom')
    expect(File.exist?(exe_path)).to be(false)
  end
end
