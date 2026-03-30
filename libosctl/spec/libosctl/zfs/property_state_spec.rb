# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/system_command_result'
require 'libosctl/utils/log'
require 'libosctl/utils/system'
require 'libosctl/zfs/property_state'

RSpec.describe OsCtl::Lib::Zfs::PropertyState do
  it 'reads properties, normalizes options, and clears state' do
    state = described_class.new

    allow(state).to receive(:zfs).with(
      :get,
      '-Hp -o property,value -s local,received all',
      'tank/ct/test'
    ).and_return(command_result(output: <<~OUT))
      compression	lz4
      quota	0
      refquota	0
    OUT

    state.read_from('tank/ct/test')
    expect(state).to have_received(:zfs).with(
      :get,
      '-Hp -o property,value -s local,received all',
      'tank/ct/test'
    )

    expect(state.properties).to eq(
      'compression' => 'lz4',
      'quota' => '0',
      'refquota' => '0'
    )
    expect(state.options).to eq(
      'compression' => 'lz4',
      'quota' => 'none',
      'refquota' => 'none'
    )
    expect(state.option_strings).to eq(
      ['"compression=lz4"', '"quota=none"', '"refquota=none"']
    )

    state.clean

    expect(state.properties).to eq({})
    expect(state.options).to eq({})
  end

  it 'applies properties with zfs set syntax' do
    state = described_class.new
    state.options['compression'] = 'lz4'
    state.options['quota'] = '10G'

    allow(state).to receive(:zfs)

    state.apply_to('tank/ct/test')

    expect(state).to have_received(:zfs).with(
      :set,
      '"compression=lz4" "quota=10G"',
      'tank/ct/test'
    )
  end
end
