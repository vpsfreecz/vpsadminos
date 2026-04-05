# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Test::Image do
  def build_opts(rebuild: false)
    {
      build_dataset: 'tank/builds',
      output_dir: '/output',
      rebuild: rebuild,
      keep_failed: false,
      ip_allocator: :allocator
    }
  end

  def new_operation(image:, tests:, build:, opts:)
    allow(OsCtl::Image::Operations::Image::Build).to receive(:new).and_return(build)
    described_class.new('/scripts', image, tests, opts)
  end

  it 'builds the image when rebuild is requested' do
    image = instance_double(OsCtl::Image::Image)
    tests = [
      instance_double(OsCtl::Image::Test, name: 'smoke'),
      instance_double(OsCtl::Image::Test, name: 'upgrade')
    ]
    build = instance_double(OsCtl::Image::Operations::Image::Build, cached?: false, execute: nil, image: image)
    status = instance_double(OsCtl::Image::Operations::Test::Run::Status)

    allow(OsCtl::Image::Operations::Test::Run).to receive(:run).and_return(status)
    new_operation(image:, tests:, build:, opts: build_opts(rebuild: true)).execute

    expect(build).to have_received(:execute)
  end

  it 'reuses cached builds when rebuild is disabled' do
    image = instance_double(OsCtl::Image::Image)
    tests = [
      instance_double(OsCtl::Image::Test, name: 'smoke'),
      instance_double(OsCtl::Image::Test, name: 'upgrade')
    ]
    build = instance_double(OsCtl::Image::Operations::Image::Build, cached?: true, execute: nil, image: image)
    status = instance_double(OsCtl::Image::Operations::Test::Run::Status)

    allow(OsCtl::Image::Operations::Test::Run).to receive(:run).and_return(status)
    new_operation(image:, tests:, build:, opts: build_opts).execute

    expect(build).not_to have_received(:execute)
  end

  it 'runs each selected test and returns their statuses' do
    image = instance_double(OsCtl::Image::Image)
    tests = [
      instance_double(OsCtl::Image::Test, name: 'smoke'),
      instance_double(OsCtl::Image::Test, name: 'upgrade')
    ]
    build = instance_double(OsCtl::Image::Operations::Image::Build, cached?: false, execute: nil, image: image)
    status = instance_double(OsCtl::Image::Operations::Test::Run::Status)

    allow(OsCtl::Image::Operations::Test::Run).to receive(:run).and_return(status)
    result = new_operation(image:, tests:, build:, opts: build_opts).execute

    expect(result).to eq([status, status])
    expect(OsCtl::Image::Operations::Test::Run).to have_received(:run).with(
      '/scripts',
      build,
      tests.first,
      keep_failed: false,
      ip_allocator: :allocator
    )
    expect(OsCtl::Image::Operations::Test::Run).to have_received(:run).with(
      '/scripts',
      build,
      tests.last,
      keep_failed: false,
      ip_allocator: :allocator
    )
  end
end
