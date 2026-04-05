# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Builder::ControlledRunscript do
  let(:builder) do
    instance_double(
      OsCtl::Image::Builder,
      attrs: { rootfs: rootfs }
    )
  end

  let(:rootfs) { Dir.mktmpdir }

  after do
    FileUtils.remove_entry(rootfs)
  end

  it 'requires exactly one of file or script' do
    expect { described_class.new(builder) }.to raise_error(ArgumentError, 'provide file or script')
    expect do
      described_class.new(builder, file: '/tmp/script', script: 'echo hi')
    end.to raise_error(ArgumentError, 'provide file or script')
  end

  it 'writes script content to a generated executable and runs it relative to the rootfs' do
    written = nil
    path = nil
    allow(OsCtl::Image::Operations::Builder::ControlledExec).to receive(:run) do |_builder, command, **|
      path = command.first
      written = File.read(File.join(rootfs, path))
      0
    end

    described_class.new(builder, script: "echo hello\n", name: '.tmp-script').execute

    expect(path).to start_with('/.tmp-script')
    expect(written).to eq("echo hello\n")
    expect(File.exist?(File.join(rootfs, path))).to be(false)
  end

  it 'copies file content when a source file is provided' do
    source = Tempfile.new('controlled-runscript')
    source.write("echo from file\n")
    source.close
    written = nil

    allow(OsCtl::Image::Operations::Builder::ControlledExec).to receive(:run) do |_builder, command, **|
      written = File.read(File.join(rootfs, command.first))
      0
    end

    described_class.new(builder, file: source.path, name: '.tmp-file').execute

    expect(written).to eq("echo from file\n")
  ensure
    source&.unlink
  end

  it 'retries name generation when the candidate already exists' do
    File.write(File.join(rootfs, '.tmp-runaaaaa'), '')
    allow(SecureRandom).to receive(:hex).with(5).and_return('aaaaa', 'bbbbb')
    captured = nil
    allow(OsCtl::Image::Operations::Builder::ControlledExec).to receive(:run) do |_builder, command, **|
      captured = command.first
      0
    end

    described_class.new(builder, script: "echo hi\n", name: '.tmp-run').execute

    expect(captured).to eq('/.tmp-runbbbbb')
  end

  it 'raises when it cannot create a unique temporary file' do
    5.times do
      File.write(File.join(rootfs, '.tmp-runaaaaa'), '')
    end
    allow(SecureRandom).to receive(:hex).with(5).and_return('aaaaa')

    expect do
      described_class.new(builder, script: "echo hi\n", name: '.tmp-run').execute
    end.to raise_error(RuntimeError, 'unable to create temporary file')
  end
end
