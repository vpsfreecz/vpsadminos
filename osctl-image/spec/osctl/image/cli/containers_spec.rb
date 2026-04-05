# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Cli::Containers do
  subject(:command) { build_command(described_class, opts:, args:) }

  let(:opts) { {} }
  let(:args) { [] }
  let(:client) { instance_double(OsCtl::Image::OsCtldClient) }

  before do
    allow(OsCtl::Image::OsCtldClient).to receive(:new).and_return(client)
  end

  it 'prints the list of supported output fields' do
    output = capture_stdout { build_command(described_class, opts: { list: true }).list }

    expect(output).to eq("#{described_class::FIELDS.join("\n")}\n")
  end

  it 'prints only image-managed containers with the default columns' do
    allow(client).to receive(:list_containers).and_return(
      [
        { pool: 'tank', id: 'builder-1', distribution: 'alpine', version: '3.20',
          'org.vpsadminos.osctl-image:type': 'builder' },
        { pool: 'tank', id: 'ignored', distribution: 'alpine', version: '3.20' }
      ]
    )
    allow(OsCtl::Lib::Cli::OutputFormatter).to receive(:print)

    command.list

    expect(OsCtl::Lib::Cli::OutputFormatter).to have_received(:print).with(
      [
        {
          pool: 'tank',
          id: 'builder-1',
          distribution: 'alpine',
          version: '3.20',
          'org.vpsadminos.osctl-image:type': 'builder',
          type: 'builder'
        }
      ],
      layout: :columns,
      cols: described_class::FIELDS,
      sort: nil,
      header: true
    )
  end

  it 'appends sort columns to the selected output list when needed' do
    allow(client).to receive(:list_containers).and_return(
      [{ pool: 'tank', id: 'builder-1', distribution: 'alpine', version: '3.20',
         'org.vpsadminos.osctl-image:type': 'builder' }]
    )
    allow(OsCtl::Lib::Cli::OutputFormatter).to receive(:print)

    build_command(described_class, opts: { output: 'id', sort: 'version' }).list

    expect(OsCtl::Lib::Cli::OutputFormatter).to have_received(:print).with(
      anything,
      layout: :columns,
      cols: %i[id version],
      sort: [:version],
      header: true
    )
  end

  it 'filters by type and explicit ids when deleting with force' do
    allow(client).to receive(:list_containers).and_return(
      [
        { id: 'builder-1', pool: 'tank', 'org.vpsadminos.osctl-image:type': 'builder' },
        { id: 'test-1', pool: 'tank', 'org.vpsadminos.osctl-image:type': 'test' }
      ]
    )
    allow(client).to receive(:delete_container)

    build_command(described_class, opts: { type: 'test', force: true }, args: ['test-1']).delete

    expect(client).to have_received(:delete_container).with('test-1')
    expect(client).not_to have_received(:delete_container).with('builder-1')
  end

  it 'prompts before deleting and respects a negative response' do
    allow(client).to receive(:list_containers).and_return(
      [{ id: 'builder-1', pool: 'tank', 'org.vpsadminos.osctl-image:type': 'builder' }]
    )
    allow(client).to receive(:delete_container)

    output = with_stdin("n\n") { capture_stdout { command.delete } }

    expect(output).to include('The following containers will be deleted:')
    expect(output).to include('Continue? [y/N]: ')
    expect(client).not_to have_received(:delete_container)
  end

  it 'deletes matching containers after confirmation' do
    allow(client).to receive(:list_containers).and_return(
      [{ id: 'builder-1', pool: 'tank', 'org.vpsadminos.osctl-image:type': 'builder' }]
    )
    allow(client).to receive(:delete_container)

    with_stdin("y\n") { command.delete }

    expect(client).to have_received(:delete_container).with('builder-1')
  end
end
