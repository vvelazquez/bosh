require_relative '../spec_helper'

describe 'external CPIs', type: :integration do
  with_reset_sandbox_before_each(external_cpi_enabled: true)

  before do
    pending('cli2: #130127863: `bosh task` should show the last task to run, not just the latest running task')
  end

  describe 'director configured to use external dummy CPI' do
    before { deploy_from_scratch }

    it 'deploys using the external CPI' do
      deploy_results = bosh_runner.run('task last --debug')
      expect(deploy_results).to include('External CPI sending request')
    end

    it 'saves external CPI logs' do
      deploy_results = bosh_runner.run('task last --cpi')
      expect(deploy_results).to include('Dummy: create_vm')
    end
  end
end
