# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Builder::RunscriptFromString do
  let(:builder) { instance_double(OsCtl::Image::Builder, ctid: 'builder-1') }
  let(:client) { instance_double(OsCtl::Image::OsCtldClient) }

  it 'writes the script to a temporary file and removes it afterwards' do
    content = nil
    path = nil
    allow(client).to receive(:runscript) do |_ctid, script_path|
      path = script_path
      content = File.read(script_path)
      0
    end

    rc = described_class.new(builder, "#!/bin/sh\necho hi\n", client:).execute

    expect(rc).to eq(0)
    expect(content).to eq("#!/bin/sh\necho hi\n")
    expect(File.exist?(path)).to be(false)
  end

  it 'uses the injected client instead of creating a new one' do
    allow(client).to receive(:runscript).and_return(0)
    allow(OsCtl::Image::OsCtldClient).to receive(:new)

    described_class.new(builder, "echo hi\n", client:).execute

    expect(client).to have_received(:runscript).with('builder-1', kind_of(String))
    expect(OsCtl::Image::OsCtldClient).not_to have_received(:new)
  end
end
