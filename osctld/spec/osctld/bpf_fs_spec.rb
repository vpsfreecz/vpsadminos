# frozen_string_literal: true

require 'osctld/bpf_fs'

RSpec.describe OsCtld::BpfFs do
  it 'manages pinned program and link paths inside the configured filesystem root' do
    with_tmpdir do |dir|
      stub_const('OsCtld::BpfFs::PROG_DIR', File.join(dir, 'progs'))
      stub_const('OsCtld::BpfFs::POOL_DIR', File.join(dir, 'pools'))

      described_class.setup
      described_class.add_pool('tank')

      File.write(described_class.prog_pin_path('prog1'), 'prog')
      File.write(described_class.link_pin_path('tank', 'link1'), 'link')

      expect(described_class.prog_pinned?('prog1')).to be(true)
      expect(described_class.link_pinned?('tank', 'link1')).to be(true)
      expect(described_class.list_progs).to eq(%w[prog1])
      expect(described_class.list_links('tank')).to eq(%w[link1])

      described_class.remove_pool('tank')

      expect(described_class.list_links('tank')).to eq([])
    end
  end
end
