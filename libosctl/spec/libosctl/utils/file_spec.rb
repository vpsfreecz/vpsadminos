# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/utils/file'

RSpec.describe OsCtl::Lib::Utils::File do
  let(:helper_class) do
    Class.new do
      include OsCtl::Lib::Utils::File
    end
  end

  let(:helper) { helper_class.new }

  it 'regenerates files whether or not they already exist' do
    with_tmpdir do |dir|
      path = File.join(dir, 'config.txt')
      File.write(path, "old\n")

      helper.regenerate_file(path, 0o644) do |new_file, old_file|
        new_file.write(old_file.read.upcase)
      end

      expect(File.read(path)).to eq("OLD\n")

      helper.regenerate_file(File.join(dir, 'new.txt'), 0o644) do |new_file, old_file|
        expect(old_file).to be_nil
        new_file.write("fresh\n")
      end

      expect(File.read(File.join(dir, 'new.txt'))).to eq("fresh\n")
    end
  end

  it 'replaces symlinks atomically' do
    with_tmpdir do |dir|
      path = File.join(dir, 'link')

      helper.replace_symlink(path, 'first')
      expect(File.readlink(path)).to eq('first')

      helper.replace_symlink(path, 'second')
      expect(File.readlink(path)).to eq('second')
    end
  end

  it 'removes existing files and empty directories when present' do
    with_tmpdir do |dir|
      file = File.join(dir, 'file')
      empty_dir = File.join(dir, 'empty')
      nonempty_dir = File.join(dir, 'nonempty')

      File.write(file, 'x')
      Dir.mkdir(empty_dir)
      Dir.mkdir(nonempty_dir)
      File.write(File.join(nonempty_dir, 'child'), 'x')

      expect(helper.unlink_if_exists(file)).to be(true)
      expect(helper.unlink_if_exists(file)).to be(false)
      expect(helper.rmdir_if_empty(empty_dir)).to be(true)
      expect(helper.rmdir_if_empty(nonempty_dir)).to be(false)
    end
  end
end
