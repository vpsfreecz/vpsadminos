# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'shellwords'

# Exercise the fixture's actual shell probe without requiring a container.
RSpec.describe 'NFS cancellation tenant permission probe' do # rubocop:disable RSpec/DescribeClass
  let(:probe) do
    source = File.read(File.join(REPO_ROOT, 'tests/suite/osctl/nfs-cancellation-common.nix'))
    quoted = source.match(%r{"('.*cat /sys/fs/nfs/net/nfs_client/shutdown.*echo rc=\$\?.*')"})[1]
    Shellwords.split(quoted).fetch(0)
  end

  def run_probe(exit_status)
    command = <<~SH
      cat() {
        if test #{exit_status} -eq 0; then
          printf 'control contents\n'
        else
          printf 'cat: Permission denied\n' >&2
        fi
        return #{exit_status}
      }
      #{probe}
    SH

    Open3.capture3('sh', '-c', command)
  end

  it 'keeps the denial before the exit marker regardless of transport channel order' do
    output, error, status = run_probe(1)

    expect(status).to be_success
    expect(output).to include('cat: Permission denied')
    expect(error).to eq('')
    expect([output + error, error + output]).to all(end_with("rc=1\n"))
  end

  it 'does not accept successful tenant access or print control contents' do
    output, error, status = run_probe(0)

    expect(status).to be_success
    expect(output).to eq("rc=0\n")
    expect(error).to eq('')
    expect(output.strip).not_to end_with('rc=1')
  end

  [2, 127].each do |exit_status|
    it "preserves unexpected exit status #{exit_status} rather than accepting it" do
      output, error, status = run_probe(exit_status)

      expect(status).to be_success
      expect(output + error).to include("rc=#{exit_status}\n")
      expect((output + error).strip).not_to end_with('rc=1')
    end
  end
end
