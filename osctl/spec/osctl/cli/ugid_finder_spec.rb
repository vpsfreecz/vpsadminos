# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::UgidFinder do
  let(:result) do
    {
      by_uid: [[1000, [{ ct: { pool: 'tank', id: 'ct1' }, ns_id: 0 }]]],
      by_gid: [[2000, [{ ct: { pool: 'tank', id: 'ct2' }, ns_id: 10 }]]]
    }
  end

  let(:client) { FakeClientHelpers::ClientDouble.new(cmd_data: { ct_find_by_ugid: [result, result] }) }

  before do
    stub_osctld_client(client)
  end

  it 'prints uid results with a header and missing entries' do
    out, = capture_output do
      described_class.new.list_by_uid([1000, 1001])
    end

    expect(out.lines.first).to include('UID', 'CONTAINER', 'CT_UID')
    expect(out).to include('1000       tank:ct1', '1001       -')
  end

  it 'prints gid results without a header when requested' do
    out, = capture_output do
      described_class.new(header: false).list_by_gid([2000])
    end

    expect(out.lines.first).to include('2000')
    expect(out.lines.first).not_to include('GID')
  end
end
