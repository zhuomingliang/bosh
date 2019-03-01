require 'spec_helper'
require 'fileutils'

describe 'exported_from releases', type: :integration do
  with_reset_sandbox_before_each

  context 'when new compiled releases have been uploaded after a deployment' do
    let(:jobs) do
      [{ name: 'job_using_pkg_1', release: 'test_release' }]
    end
    let(:manifest) do
      Bosh::Spec::NewDeployments.simple_manifest_with_instance_groups(name: 'ig-name', jobs: jobs).tap do |manifest|
        manifest.merge!(
          release: [{
            name: 'test_release',
            version: '1',
            exported_from: [{ os: 'centos-7', version: '1.0' }],
          }],
        )
      end
    end

    before do
      bosh_runner.run("upload-stemcell #{spec_asset('light-bosh-stemcell-3001-aws-xen-centos-7-go_agent.tgz')}")

      # something named test_release compiled against an older stemcell, but with the same major version
      old_compiled_release = 'compiled_releases/release-test_release-1-on-centos-7-stemcell-3001.1.tgz'

      bosh_runner.run("upload-release #{spec_asset(old_compiled_release)}")
      deploy(manifest_hash: manifest)

      # something named test_release compiled against a newer stemcell, but with the same major version
      new_compiled_release = 'compiled_releases/release-test_release-1-on-centos-7-stemcell-3001.2.tgz'

      bosh_runner.run("upload-release #{spec_asset(new_compiled_release)}")
    end

    it 'a no-op deploy does not update any VMs' do
      output = deploy(manifest_hash: manifest)
      expect(output).to_not include 'updating ig-name'
    end
  end
end
