# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Repository::GetImagePath do
  let(:repo) { instance_double(OsCtl::Repo::Local::Repository, exist?: exists, find: found_image) }
  let(:exists) { true }
  let(:found_image) { image }
  let(:image) do
    instance_double(
      OsCtl::Repo::Base::Image,
      has_image?: true,
      version_image_path: 'v1/vendor/minimal/x86_64/alpine/3.20/image-stream.tar'
    )
  end
  let(:attrs) do
    {
      distribution: 'alpine',
      version: '3.20',
      arch: 'x86_64',
      vendor: 'vendor',
      variant: 'minimal'
    }
  end

  before do
    allow(OsCtl::Repo::Local::Repository).to receive(:new).with('/repo').and_return(repo)
  end

  it 'raises when the repository does not exist' do
    allow(repo).to receive(:exist?).and_return(false)

    expect { described_class.new('/repo', attrs, :zfs).execute }
      .to raise_error(OsCtl::Image::OperationError, 'repository does not exist')
  end

  it 'raises when the image is not found' do
    allow(repo).to receive(:find).and_return(nil)

    expect { described_class.new('/repo', attrs, :zfs).execute }
      .to raise_error(OsCtl::Image::OperationError, 'image not found')
  end

  it 'raises when the requested format is not present' do
    allow(image).to receive(:has_image?).with('zfs').and_return(false)

    expect { described_class.new('/repo', attrs, :zfs).execute }
      .to raise_error(OsCtl::Image::OperationError, 'image format not found')
  end

  it 'returns the full path to the requested image format' do
    expect(described_class.new('/repo', attrs, :zfs).execute)
      .to eq('/repo/v1/vendor/minimal/x86_64/alpine/3.20/image-stream.tar')
  end
end
