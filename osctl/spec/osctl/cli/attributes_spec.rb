# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Attributes do
  let(:klass) do
    Class.new(OsCtl::Cli::Command) do
      include OsCtl::Cli::Attributes
    end
  end

  let(:command) { build_command(klass) }

  it 'sets vendor attributes through osctld_fmt' do
    expect(command).to receive(:osctld_fmt).with(
      :ct_set,
      cmd_opts: { id: 'ct1', attrs: { 'org.vpsadminos:key' => 'value' } }
    )

    command.do_set_attr(:ct_set, { id: 'ct1' }, 'org.vpsadminos:key', 'value')
  end

  it 'rejects invalid attribute names' do
    expect do
      command.do_set_attr(:ct_set, { id: 'ct1' }, 'broken', 'value')
    end.to raise_error(
      GLI::BadCommandLine,
      "attribute name is not in the required format '<vendor>:<key>'"
    )
  end

  it 'unsets attributes through osctld_fmt' do
    expect(command).to receive(:osctld_fmt).with(
      :ct_unset,
      cmd_opts: { id: 'ct1', attrs: ['org.vpsadminos:key'] }
    )

    command.do_unset_attr(:ct_unset, { id: 'ct1' }, 'org.vpsadminos:key')
  end
end
