require 'rbvmomi'
require 'netaddr'
require 'thread'
require 'celluloid'

module Catering
    
    module Hypervisors

        class HypervisorError < StandardError
        end

        module Vsphere

            def cloning_mutex
                @cloning_mutex ||= Mutex.new
            end

            def vim
                @connection ||= RbVmomi::VIM.connect(
                    :host => @options[:vsphere_host],
                    :path => @options[:vsphere_path],
                    :port => @options[:port],
                    :use_ssl => @options[:use_ssl],
                    :user => @options[:vsphere_user],
                    :password => @options[:vsphere_pass],
                    :insecure => @options[:insecure]
                )
            end

            def datacenter
                @datacenter ||= vim.serviceInstance.find_datacenter(@options[:vsphere_dc]) or
                    raise HypervisorError, "datacenter #{@options[:vsphere_dc]} not found"
            end

            def find_folder(folder)
                folder_obj = datacenter.vmFolder
                path = folder.split('/')
                path.each do |elem|
                    if elem != ''
                        folder_obj = folder_obj.childEntity.grep(RbVmomi::VIM::Folder).find { |f| f.name == elem } or
                            raise HypervisorError, "no such folder #{folder} while looking for #{elem}"
                    end
                end
                folder_obj
            end

            def traverse_path(obj, path, &block)
                path.each do |elem|
                    if elem != ''
                        if obj.is_a? RbVmomi::VIM::Folder
                            obj = obj.childEntity.find { |f| f.name == elem } || yield(obj, elem)

                        elsif obj.is_a? RbVmomi::VIM::ClusterComputeResource
                            obj = obj.resourcePool.resourcePool.find { |f| f.name == elem } || yield(obj, elem)

                        elsif obj.is_a? RbVmomi::VIM::ResourcePool
                            obj = obj.resourcePool.find { |f| f.name == elem } || yield(obj, elem)

                        else
                            raise HypervisorError, "Unexpected Object type encountered #{obj.class} while finding resourcePool"
                        end
                    end
                end

                obj
            end

            def find_pool(pool, create_if_missing = false)
                pool_obj = datacenter.hostFolder
                pool_path = pool.split('/')

                pool_obj = traverse_path(pool_obj, pool_path) do |obj, elem|
                    if create_if_missing
                        resource_pool_spec = {
                            :name => elem,
                            :spec => RbVmomi::VIM.ResourceConfigSpec(
                                        :cpuAllocation => RbVmomi::VIM.ResourceAllocationInfo(:expandableReservation => true,
                                                                                                :limit => -1,
                                                                                                :reservation => 0,
                                                                                                :shares => RbVmomi::VIM.SharesInfo(:level => 'normal',
                                                                                                                                    :shares => 0)),
                                        :memoryAllocation => RbVmomi::VIM.ResourceAllocationInfo(:expandableReservation => true,
                                                                                                    :limit => -1,
                                                                                                    :reservation => 0,
                                                                                                    :shares => RbVmomi::VIM.SharesInfo(:level => 'normal',
                                                                                                                                    :shares => 0)))
                        }

                        if obj.respond_to? :CreateResourcePool
                            new_pool = obj.CreateResourcePool(resource_pool_spec)

                        elsif obj.respond_to? :resourcePool
                            new_pool = obj.resourcePool.CreateResourcePool(resource_pool_spec)

                        else
                            raise HypervisorError, "Unexpected object type #{obj.class}encountered while trying to create resource pool #{elem}"
                        end

                    else
                        raise HypervisorError, "no such pool #{pool} while looking for #{elem}"
                    end

                    new_pool
                end

                pool_obj = pool_obj.resourcePool if not pool_obj.is_a?(RbVmomi::VIM::ResourcePool) and pool_obj.respond_to?(:resourcePool)
                pool_obj
            end

            def find_datastore(datastore)
                ds_list = datacenter.datastore
                ds_list.find { |f| f.info.name == datastore } or
                    raise HypervisorError, "no such datastore #{datastore}"
            end

            def find_in_folder(folder, type, name)
                folder.childEntity.grep(type).find { |o| o.name == name }
            end

            def find_all_in_folder(folder, type)
                folder = folder.resourcePool if folder.instance_of?(RbVmomi::VIM::ClusterComputeResource)

                if folder.instance_of?(RbVmomi::VIM::ResourcePool)
                    folder.resourcePool.grep(type)

                elsif folder.instance_of?(RbVmomi::VIM::Folder)
                    folder.childEntity.grep(type)

                else
                    puts "Unknown type #{folder.class}, not enumerating"
                    nil
                end
            end

            def vm_exists?(vm_name, folder = @options[:vm_folder])
                f = find_folder(folder)
                find_in_folder(f, RbVmomi::VIM::VirtualMachine, vm_name) != nil
            end

            def find_vm(vm_name, folder = @options[:vm_folder])
                f = find_folder(folder)

                vm = find_in_folder(f, RbVmomi::VIM::VirtualMachine, vm_name)
                Catering::VirtualMachine.new(vm_name, vm) if vm
            end

            def network_exists?(network)
                nil != vim.serviceInstance.find_datacenter(@options[:vsphere_dc]).network.find { |vlan| vlan.name == network }
            end

            def find_network(network)
                networks = datacenter.network
                networks.find { |f| f.name == network} or abort "no such network #{network}"
            end

            def generate_adapter_map (adapter)
                settings = RbVmomi::VIM.CustomizationIPSettings

                if adapter.nil? or adapter.ip.nil?
                    settings.ip = RbVmomi::VIM::CustomizationDhcpIpGenerator()

                else
                    cidr_ip = NetAddr::CIDR.create(adapter.ip)
                    settings.ip = RbVmomi::VIM::CustomizationFixedIp(:ipAddress => cidr_ip.ip)
                    settings.subnetMask = cidr_ip.netmask_ext

                    if adapter.gateway.nil?
                        settings.gateway = [cidr_ip.network(:Objectify => true).next_ip]

                    else
                        gw_cidr = NetAddr::CIDR.create(adapter.gateway)
                        settings.gateway = [gw_cidr.ip]
                    end
                end

                adapter_map = RbVmomi::VIM.CustomizationAdapterMapping
                adapter_map.adapter = settings
                adapter_map
            end

            def generate_clone_spec (src_config, clone_options)
                rspec = nil

                if @options[:resource_pool]
                    resource_pool = clone_options.has_key?(:resource_pool) ? "#{@options[:resource_pool]}/#{clone_options[:resource_pool]}" : @options[:resource_pool]
                    rspec = RbVmomi::VIM.VirtualMachineRelocateSpec(:pool => find_pool(resource_pool, true))

                else
                    hosts = find_all_in_folder(datacenter.hostFolder, RbVmomi::VIM::ComputeResource)
                    rp = hosts.first.resourcePool
                    rspec = RbVmomi::VIM.VirtualMachineRelocateSpec(:pool => rp)
                end

                rspec.datastore = find_datastore(@options[:datastore]) if @options[:datastore]

                clone_spec = RbVmomi::VIM.VirtualMachineCloneSpec(
                    :location => rspec,
                    :powerOn => false,
                    :template => false
                )
                clone_spec.config = RbVmomi::VIM.VirtualMachineConfigSpec(:deviceChange => Array.new)

                clone_spec.config.numCPUs = clone_options[:customization_cpucount] if clone_options[:customization_cpucount]
                clone_spec.config.memoryMB = Integer(clone_options[:customization_memory]) * 1024 if clone_options[:customization_memory]

                if clone_options[:customization_vlan]
                    network = find_network(clone_options[:customization_vlan])
                    card = src_config.hardware.device.find { |d| d.deviceInfo.label == 'Network adapter 1' } or
                        raise HypervisorError, "Can't find source network card to customize"

                    begin
                        switch_port = RbVmomi::VIM.DistributedVirtualSwitchPortConnection(
                            :switchUuid => network.config.distributedVirtualSwitch.uuid,
                            :portgroupKey => network.key
                        )
                        card.backing.port = switch_port

                    rescue
                        # not connected to a distibuted switch?
                        card.backing.deviceName = network.name
                    end

                    dev_spec = RbVmomi::VIM.VirtualDeviceConfigSpec(:device => card, :operation => 'edit')
                    clone_spec.config.deviceChange.push dev_spec
                end

                if clone_options[:customization_spec]
                    csi = find_customization(clone_options[:customization_spec]) or
                        raise HypervisorError, "failed to find customization specification named #{clone_options[:customization_spec]}"

                    fatal_exit('Only Linux customization specifications are currently supported') if csi.info.type != 'Linux'

                    cust_spec = csi.spec

                else
                    cust_spec = RbVmomi::VIM.CustomizationSpec(
                        :globalIPSettings => RbVmomi::VIM.CustomizationGlobalIPSettings
                    )
                end

                cust_spec.globalIPSettings.dnsServerList = clone_options[:customization_dns_ips].split(',') if clone_options[:customization_dns_ips]
                cust_spec.globalIPSettings.dnsSuffixList = clone_options[:customization_dns_suffixes] if clone_options[:customization_dns_suffixes]

                cust_spec.nicSettingMap = clone_options[:customization_nics].map { |nic| generate_adapter_map(nic) } if clone_options[:customization_nics]

                use_ident = !clone_options[:customization_hostname].nil? || !clone_options[:customization_domain].nil? || cust_spec.identity.nil?

                if use_ident
                    # TODO - verify that we're deploying a linux spec, at least warn
                    ident = RbVmomi::VIM.CustomizationLinuxPrep

                    ident.hostName = RbVmomi::VIM.CustomizationFixedName
                    if clone_options[:customization_hostname]
                        ident.hostName.name = clone_options[:customization_hostname]
                    else
                        ident.hostName.name = clone_options[:vmname]
                    end

                    if clone_options[:customization_domain]
                        ident.domain = clone_options[:customization_domain]
                    else
                        ident.domain = ''
                    end

                    cust_spec.identity = ident
                end

                clone_spec.customization = cust_spec
                clone_spec
            end

            def clone(src_vm, name, clone_options, &block)
                clone_spec = generate_clone_spec(src_vm.config, clone_options)

                folder = find_folder(@options[:vm_folder])

                # do the cloning and wait for customization to end through a
                # Celluloid::Future so that this does not block this hypervisor
                # and the calling host for everyone else.
                future = Celluloid::Future.new do
                    cloning_mutex.synchronize do
                        yield 'starting cloning process'

                        if not clone_options[:simulate]
                            task = src_vm.CloneVM_Task(
                                :folder => folder,
                                :name => name,
                                :spec => clone_spec
                            )

                            progress = 0

                            task.wait_for_progress do |p|
                                if !p.nil? && p.to_i >= progress
                                    yield "#{p}% complete"
                                    progress = p + 10
                                end
                            end
                        end
                    end

                    vm = find_in_folder(folder, RbVmomi::VIM::VirtualMachine, name)
                    if !vm && block_given?
                        yield "VM #{name} not found"
                        false

                    elsif not clone_options[:simulate]
                        yield 'cloning complete, waiting for machine to power on'
                        vm.PowerOnVM_Task.wait_for_completion

                    else
                        true
                    end
                end

                future.value
            end
        end
    end
end
