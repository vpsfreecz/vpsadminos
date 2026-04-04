# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::PidFinder do
  let(:finder) { instance_double(OsCtl::Lib::PidFinder) }

  before do
    allow(OsCtl::Lib::PidFinder).to receive(:new).and_return(finder)
  end

  it 'prints the header by default' do
    out, = capture_output { described_class.new }

    expect(out.lines.first).to include('PID', 'CONTAINER', 'CTPID', 'NAME')
  end

  it 'prints missing, host, and container lookups' do
    allow(finder).to receive(:find).with(10).and_return(nil)
    allow(finder).to receive(:find).with(20).and_return(
      double(ctid: :host, os_process: double(name: 'sshd'))
    )
    allow(finder).to receive(:find).with(30).and_return(
      double(pool: 'tank', ctid: 'ct1', os_process: double(ct_pid: 5, name: 'bash'))
    )

    out, = capture_output do
      pf = described_class.new(header: false)
      pf.find(10)
      pf.find(20)
      pf.find(30)
    end

    expect(out).to include('10         -', '20         [host]', '30         tank:ct1')
  end
end
