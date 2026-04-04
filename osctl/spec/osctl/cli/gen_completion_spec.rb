# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::GenCompletion do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  it 'uses id-range completion for id-range arguments' do
    completion = instance_double(
      OsCtl::Lib::Cli::Completion::Bash,
      opt: nil,
      arg: nil,
      generate: 'generated'
    )
    allow(completion).to receive(:shortcuts=)
    allow(OsCtl::Lib::Cli::Completion::Bash).to receive(:new).and_return(completion)

    out, = capture_output { cmd.bash }

    expect(completion).to have_received(:arg).with(
      a_hash_including(
        cmd: :all,
        name: :'id-range',
        expand: a_string_including('id-range ls -H -o pool,name')
      )
    )
    expect(out).to eq("generated\n")
  end
end
