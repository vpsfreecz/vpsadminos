# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::Machine do
  %w[vpsadminos nixos].each do |spin|
    it "preserves data and recreates only disposable disks for #{spin}" do
      with_tmpdir do |dir|
        source = File.join(dir, 'source.img')
        File.write(source, 'initial contents')
        config = build_machine_config(
          {
            'bootMode' => 'firmware',
            'diskImage' => nil,
            'disks' => [
              { 'device' => 'data.img', 'type' => 'file', 'size' => '1K' },
              { 'device' => 'scratch.img', 'type' => 'file', 'size' => '1K', 'preserve' => false },
              { 'device' => 'image.img', 'type' => 'file', 'image' => source, 'preserve' => false },
              { 'device' => 'external.img', 'type' => 'file', 'create' => false },
              { 'device' => '/dev/not-an-owned-disk', 'type' => 'blockdev' }
            ]
          },
          spin:
        )
        machine = public_send("build_#{spin}_machine", dir:, config:)
        paths = %w[data scratch image external].to_h { |name| [name, File.join(dir, 'tmp', "#{name}.img")] }
        File.write(paths['external'], 'external data')
        machine.send(:prepare_disks)
        File.binwrite(paths['data'], 'retained data')
        File.binwrite(paths['scratch'], 'x' * 1024)
        File.write(paths['image'], 'changed guest data')
        File.write(source, 'updated source')

        restarted = public_send("build_#{spin}_machine", dir:, config:)
        restarted.send(:prepare_disks)

        expect(File.read(paths['data'])).to eq('retained data')
        expect(File.binread(paths['scratch'])).to eq("\0" * 1024)
        expect(File.read(paths['image'])).to eq('updated source')
        expect(File.read(paths['external'])).to eq('external data')
        restarted.destroy_disks
        expect(paths.values_at('data', 'scratch', 'image').none? { |path| File.exist?(path) }).to be(true)
        expect(File.read(paths['external'])).to eq('external data')
      end
    end
  end

  it 'keeps the previous disk when replacement copying fails' do
    with_tmpdir do |dir|
      config = build_machine_config('disks' => [
                                      { 'device' => 'data.img', 'type' => 'file', 'image' => '/source', 'preserve' => false }
                                    ])
      machine = build_machine(dir:, config:)
      path = File.join(dir, 'tmp', 'data.img')
      File.write(path, 'original data')
      allow(FileUtils).to receive(:cp) do |_source, destination|
        File.write(destination, 'partial copy')
        raise IOError, 'copy failed'
      end

      expect { machine.send(:prepare_disks) }.to raise_error(IOError, 'copy failed')
      expect(File.read(path)).to eq('original data')
      expect(Dir.glob(File.join(dir, 'tmp', 'osvm-disk-*'))).to be_empty
    end
  end

  it 'keeps the previous disk when blank disk creation fails' do
    with_tmpdir do |dir|
      config = build_machine_config('disks' => [
                                      { 'device' => 'data.img', 'type' => 'file', 'size' => 'invalid', 'preserve' => false }
                                    ])
      machine = build_machine(dir:, config:)
      path = File.join(dir, 'tmp', 'data.img')
      File.write(path, 'original data')

      expect { machine.send(:prepare_disks) }.to raise_error(RuntimeError, /truncate/)
      expect(File.read(path)).to eq('original data')
      expect(Dir.glob(File.join(dir, 'tmp', 'osvm-disk-*'))).to be_empty
    end
  end
end
