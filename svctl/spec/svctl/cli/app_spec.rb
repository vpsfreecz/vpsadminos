# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SvCtl::Cli::App do
  it 'builds the command tree' do
    app = described_class.get

    expect(app.commands.keys.map(&:to_s)).to include(
      'list-all',
      'list-services',
      'enable',
      'disable',
      'protect',
      'list-protected',
      'unprotect',
      'list-runlevels',
      'runlevel',
      'switch',
      'gen-completion'
    )
  end

  it 'uses list-all as the default command' do
    handler = instance_double(SvCtl::Cli::Command, list_all: true)
    allow(SvCtl::Cli::Command).to receive(:new).and_return(handler)

    described_class.get.run([])

    expect(handler).to have_received(:list_all)
  end
end
