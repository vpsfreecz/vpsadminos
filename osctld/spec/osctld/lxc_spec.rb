# frozen_string_literal: true

require 'fileutils'
require 'osctld/lxc'

RSpec.describe OsCtld::Lxc do
  it 'maps suse to opensuse' do
    expect(described_class.dist_name('suse')).to eq('opensuse')
    expect(described_class.dist_name('alpine')).to eq('alpine')
  end

  it 'returns only existing config files in order' do
    with_tmpdir do |dir|
      stub_const("#{described_class}::CONFIGS", dir)
      File.write(File.join(dir, 'common.conf'), '')
      FileUtils.mkdir_p(File.join(dir, 'opensuse'))
      File.write(File.join(dir, 'opensuse', '9.conf'), '')

      expect(described_class.dist_lxc_configs('suse', '9')).to eq(
        [
          File.join(dir, 'common.conf'),
          File.join(dir, 'opensuse', '9.conf')
        ]
      )
    end
  end

  it 'recreates config symlinks into the destination tree' do
    with_tmpdir do |dir|
      root = File.join(dir, 'root')
      dst = File.join(dir, 'dst')
      cfg_root = File.join(root, 'configs', 'lxc')

      FileUtils.mkdir_p(File.join(cfg_root, 'alpine'))
      FileUtils.mkdir_p(dst)
      File.write(File.join(cfg_root, 'common.conf'), '')
      File.write(File.join(cfg_root, 'alpine', '3.conf'), '')
      File.write(File.join(dst, 'common.conf'), 'stale')

      OsCtld.define_singleton_method(:root) { root }

      described_class.install_lxc_configs(dst)

      expect(File.symlink?(File.join(dst, 'common.conf'))).to be(true)
      expect(File.symlink?(File.join(dst, 'alpine', '3.conf'))).to be(true)
      expect(File.readlink(File.join(dst, 'common.conf'))).to eq(
        File.join(cfg_root, 'common.conf')
      )
    end
  end
end
