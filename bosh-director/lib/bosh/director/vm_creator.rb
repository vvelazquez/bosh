require 'common/deep_copy'

module Bosh::Director
  # Creates VM model and call out to CPI to create VM in IaaS
  class VmCreator
    include EncryptionHelper

    def initialize(cloud, logger, vm_deleter, disk_manager)
      @cloud = cloud
      @logger = logger
      @vm_deleter = vm_deleter
      @disk_manager = disk_manager
    end

    def create_for_instance_plans(instance_plans, ip_provider, event_log)
      return @logger.info('No missing vms to create') if instance_plans.empty?

      total = instance_plans.size
      event_log.begin_stage('Creating missing vms', total)
      ThreadPool.new(max_threads: Config.max_threads, logger: @logger).wrap do |pool|
        instance_plans.each do |instance_plan|
          instance = instance_plan.instance

          pool.process do
            with_thread_name("create_missing_vm(#{instance.job.name}, #{instance.index}/#{total})") do
              event_log.track("#{instance.job.name}/#{instance.index}") do
                @logger.info('Creating missing VM')
                disks = [instance.model.persistent_disk_cid].compact
                create_for_instance_plan(instance_plan, disks)

                instance_plan.network_plans
                  .select(&:obsolete?)
                  .each do |network_plan|
                  reservation = network_plan.reservation
                  ip_provider.release(reservation)
                end
                instance_plan.release_obsolete_network_plans
              end
            end
          end
        end
      end
    end

    def create_for_instance_plan(instance_plan, disks)
      instance = instance_plan.instance
      existing_apply_spec = instance_plan.existing_instance.nil? ? {} : instance_plan.existing_instance.apply_spec

      @logger.info('Creating VM')

      vm_model = create(
        instance.deployment_model,
        instance.stemcell,
        instance.cloud_properties,
        instance_plan.network_settings_hash,
        disks,
        instance.env,
      )

      begin
        instance.bind_to_vm_model(vm_model)
        VmMetadataUpdater.build.update(vm_model, {})

        agent_client = AgentClient.with_vm(vm_model)
        agent_client.wait_until_ready
        instance.update_trusted_certs
        instance.update_cloud_properties!
      rescue Exception => e
        @logger.error("Failed to create/contact VM #{vm_model.cid}: #{e.inspect}")
        @vm_deleter.delete_for_instance_plan(instance_plan)
        raise e
      end

      @disk_manager.attach_disks_for(instance)

      if instance_plan.existing_instance && instance_plan.needs_recreate?
        instance_plan.existing_instance.vm.update(apply_spec: existing_apply_spec)
        agent_client.apply(existing_apply_spec)
      else
        instance.apply_vm_state
      end

      instance_plan.mark_desired_network_plans_as_existing
    end

    private

    def create(deployment, stemcell, cloud_properties, network_settings, disks, env)
      vm = nil
      vm_cid = nil

      env = Bosh::Common::DeepCopy.copy(env)

      agent_id = self.class.generate_agent_id

      options = {
        :deployment => deployment,
        :agent_id => agent_id,
        :env => env
      }

      if Config.encryption?
        credentials = generate_agent_credentials
        env['bosh'] ||= {}
        env['bosh']['credentials'] = credentials
        options[:credentials] = credentials
      end

      count = 0
      begin
        vm_cid = @cloud.create_vm(agent_id, stemcell.cid, cloud_properties, network_settings, disks, env)
      rescue Bosh::Clouds::VMCreationFailed => e
        count += 1
        @logger.error("failed to create VM, retrying (#{count})")
        retry if e.ok_to_retry && count < Config.max_vm_create_tries
        raise e
      end

      options[:cid] = vm_cid
      vm = Models::Vm.new(options)

      vm.save
      vm
    rescue => e
      @logger.error("error creating vm: #{e.message}")
      delete_vm(vm_cid) if vm_cid
      vm.destroy if vm
      raise e
    end

    def delete_vm(vm_cid)
      @cloud.delete_vm(vm_cid)
    rescue => e
      @logger.error("error cleaning up #{vm_cid}: #{e.message}\n#{e.backtrace.join("\n")}")
    end

    def self.generate_agent_id
      SecureRandom.uuid
    end
  end
end
