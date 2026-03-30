# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/system_command_result'
require 'libosctl/utils/log'
require 'libosctl/utils/system'
require 'libosctl/zfs/dataset_tree'
require 'libosctl/zfs/property_reader'

RSpec.describe OsCtl::Lib::Zfs::PropertyReader do
  it 'returns an empty tree for empty input' do
    reader = described_class.new

    allow(reader).to receive(:zfs)
    expect(reader.read([], %w[mountpoint]).datasets).to eq({})
    expect(reader).not_to have_received(:zfs)
  end

  it 'reads properties into a dataset tree with the requested zfs options' do
    reader = described_class.new

    allow(reader).to receive(:zfs).with(
      :get,
      '-Hp -o name,property,value -t volume -r mountpoint,quota',
      'tank/ct/test tank/ct/other',
      { stderr: false, valid_rcs: :all }
    ).and_return(command_result(output: <<~OUT))
      tank/ct/test	mountpoint	/tank/ct/test
      tank/ct/test	quota	10G
      tank/ct/other	mountpoint	/tank/ct/other
    OUT

    tree = reader.read(
      %w[tank/ct/test tank/ct/other],
      %w[mountpoint quota],
      type: 'volume',
      recursive: true,
      ignore_error: true
    )
    expect(reader).to have_received(:zfs).with(
      :get,
      '-Hp -o name,property,value -t volume -r mountpoint,quota',
      'tank/ct/test tank/ct/other',
      { stderr: false, valid_rcs: :all }
    )

    expect(tree['tank/ct/test'].properties).to eq(
      'mountpoint' => '/tank/ct/test',
      'quota' => '10G'
    )
    expect(tree['tank/ct/other'].properties).to eq('mountpoint' => '/tank/ct/other')
  end
end
