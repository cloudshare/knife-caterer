require 'celluloid'
require 'net/ping/tcp'
require 'timeout'
require 'ostruct'


module Catering
        
    class AsyncArray < Array
        include Celluloid
    end


    class VirtualMachine < Celluloid::AbstractProxy

        attr_accessor :name

        def initialize(name, vm)
            @name = name
            @vm = vm
        end

        def powered_on?
            @vm.runtime.powerState
        end

        def ip
            @vm.guest.ipAddress if @vm.guest.ipAddress && @vm.guest.ipAddress.length > 0
        end

        def config
            @vm.config
        end

        def method_missing(name, *args, &block)
            @vm.__send__(name, *args, &block)
        end
    end


    class Network

        attr_accessor :name
        attr_accessor :dns
        attr_accessor :subnet
        attr_accessor :gateway
        attr_accessor :domain

        def initialize(options)
            @options = options
        end

        def exists?
            # search for the VM in the hypervisor
            @options[:hypervisor].network_exists?(@options[:vlan])
        rescue Exception => e
            puts e.to_s
            puts e.backtrace
        end

        def name
            @options[:vlan]
        end

        def dns
            @options[:dns]
        end

        def subnet
            @options[:subnet]
        end

        def gateway
            @options[:gateway]
        end

        def domain
            @options[:domain]
        end
    end


    class Template < Celluloid::AbstractProxy

        attr_accessor :name
        attr_accessor :user
        attr_accessor :key
        attr_accessor :os

        def initialize(name, options)
            @name = name
            @os = options[:os]
            @user = options[:user]
            @key = options[:key]
            @options = options

            @vm = @options[:hypervisor].find_vm(@name, @options[:folder])
        end


        def exists?
            @vm != nil

        rescue Exception => e
            puts e.to_s
            puts e.backtrace
        end


        def method_missing(name, *args, &block)
            @vm.__send__(name, *args, &block) if @vm
        end
    end


    class Host
        include Celluloid

        class Machine
            include Celluloid::FSM

            default_state :waiting

            state :locate_vm, :to => [:runtime_state, :provision] do
                # try to find the VM in the hypervisor
                if actor.vm_exists?
                    actor.messages.async.<< [Time.new, 'VM found']
                    transition :runtime_state
                else
                    actor.messages.async.<< [Time.new, 'VM not found']
                    transition :provision
                end
            end

            state :runtime_state, :to => [:powered_off, :networking_down, :check_connectivity] do
                # check the VM's runtime state (power and IP)
                if not actor.powered_on?
                    actor.messages.async.<< [Time.new, 'VM is powered off']
                    transition :powered_off

                elsif not actor.ip
                    actor.messages.async.<< [Time.new, 'VM has no IP address']
                    transition :networking_down

                else
                    transition :check_connectivity
                end
            end

            state :check_connectivity, :to => [:verify, :disconnected] do
                # check networking connectivity to the VM
                if actor.answers_ping?
                    actor.messages.async.<< [Time.new, 'VM responds to network ping']
                    transition :verify
                else
                    actor.messages.async.<< [Time.new, 'VM does not respond to network ping']
                    transition :disconnected
                end
            end

            state :verify, :to => [:verified, :running, :acceptance_failed] do
                # run acceptance tests to verify the host
                status = actor.is_ready?

                if status
                    actor.messages.async.<< [Time.new, 'acceptance test passed']
                    transition :verified

                elsif status.nil?
                    actor.messages.async.<< [Time.new, 'no acceptance test provided']
                    transition :running

                else
                    actor.messages.async.<< [Time.new, 'acceptance test failed']
                    transition :acceptance_failed
                end
            end

            state :provision, :to => [:customizing, :prerequisites, :provisioning_failure] do
                # verify the prerequisites are met, and provision a new VM
                missing_networks = actor.networks.reject { |net| net.exists? }
                if !actor.template.exists? || missing_networks.size > 0
                    actor.messages.async.<< [Time.new, 'missing required template or network']
                    transition :prerequisites

                elsif !actor.simulate && !actor.remove_client
                    actor.messages.async.<< [Time.new, 'failed to remove client from Chef server']
                    transition :prerequisites

                elsif actor.simulate == :calc
                    actor.messages.async.<< [Time.new, 'needs to be provisioned']

                elsif not actor.provision
                    actor.messages.async.<< [Time.new, 'VM provisioning failed']
                    transition :provisioning_failure

                else
                    transition :customizing
                end
            end

            state :customizing, :to => [:verify_connectivity, :customization_timeout] do
                # wait for the customization to complete (power on & IP)
                actor.messages.async.<< [Time.new, 'waiting for VM customization to complete']
                
                begin
                    status = Timeout::timeout(10 * 60) do
                        sleep 10 until actor.simulate || (actor.powered_on? && actor.ip)
                        true
                    end

                rescue Timeout::Error
                    status = nil
                end

                if status
                    actor.messages.async.<< [Time.new, 'VM customization complete']
                    transition :verify_connectivity

                else
                    actor.messages.async.<< [Time.new, 'VM customization failed']
                    transition :customization_timeout
                end
            end

            state :verify_connectivity, :to => [:bootstrap, :customization_failure] do
                # check networking connectivity to the VM
                begin
                    status = Timeout::timeout(5 * 60) do
                        sleep 10 until actor.simulate or actor.answers_ping?
                        true
                    end

                rescue Timeout::Error
                    status = nil
                end

                if status
                    actor.messages.async.<< [Time.new, 'VM responds to network ping']
                    transition :bootstrap

                else
                    actor.messages.async.<< [Time.new, 'VM does not respond to network ping']
                    transition :customization_failure
                end
            end

            state :bootstrap, :to => [:test, :bootstrapping_failure] do
                # Bootstrap the VM with chef-client
                if actor.simulate == :calc
                    actor.messages.async.<< [Time.new, 'requires bootstrapping']

                elsif not actor.bootstrap
                    actor.messages.async.<< [Time.new, 'bootstrapping failed']
                    transition :bootstrapping_failure

                else
                    actor.messages.async.<< [Time.new, 'updating node run list']
                    actor.update_node
                    transition :test
                end
            end

            state :test, :to => [:verified, :acceptance_failed] do
                # run acceptance tests to verify the host
                begin
                    status = Timeout::timeout(10 * 60) do
                        sleep 30 until [nil, true].include? actor.is_ready?
                        true
                    end

                rescue Timeout::Error
                    status = nil
                end

                if status
                    actor.messages.async.<< [Time.new, 'acceptance test passed']
                    transition :verified

                else
                    # verification failed
                    actor.messages.async.<< [Time.new, 'acceptance test failed']
                    transition :acceptance_failed
                end
            end

            attr_accessor :success

            handle_failure = Proc.new { @success = false }

            handle_success = Proc.new { @success = true }

            # failure end states
            state :prerequisites, &handle_failure
            state :provisioning_failure, &handle_failure
            state :customization_timeout, &handle_failure
            state :customization_failure, &handle_failure
            state :bootstrapping_failure, &handle_failure
            state :powered_off, &handle_failure
            state :networking_down, &handle_failure
            state :disconnected, &handle_failure
            state :acceptance_failed, &handle_failure

            # success end states
            state :running, &handle_success
            state :verified, &handle_success
        end


        attr_accessor :fqdn
        attr_accessor :networks
        attr_accessor :template
        attr_accessor :messages
        attr_accessor :simulate


        def initialize(actor, instance, env, domain, roles, networks, template,
                    cpu_count, memoryGB, address, accept_test, hypervisor, simulate)

            @actor, @env, @networks, @template, @cpu_count, @memoryGB, @address,
                @accept_test, @hypervisor, @simulate =
                actor, env, networks, template, cpu_count, memoryGB, address,
                accept_test, hypervisor, simulate

            @machine = Machine.new

            @vm_name = "#{actor}#{instance}"
            @fqdn = "#{@vm_name}.#{domain}"

            @messages = AsyncArray.new

            @rest_client ||= Chef::REST.new(Chef::Config['chef_server_url'])

            @node = Chef::Node.new
            @node.name = @fqdn
            @node.chef_environment = @env

            run_list = []
            roles.each do |role|

                @node.run_list << Chef::RunList::RunListItem.new(role)
                run_list << role
            end
            @roles = "'#{run_list * ','}'"

            @@cloning_mutex ||= Mutex.new
        end


        def state(&block)
            if block_given?
                yield @machine.state
            else
                @machine.state
            end
        end


        def process_messages(&block)
            @messages.delete_if(&block)
        end


        def success
            @machine.success
        end


        def vm_exists?
            @hypervisor.vm_exists?(@fqdn)

        rescue Exception => e
            @messages.async.<< [Time.new, e.to_s]
            @messages.async.<< [Time.new, e.backtrace]
            false
        end


        def powered_on?
            vm = @hypervisor.find_vm(@fqdn)
            vm and vm.powered_on?

        rescue Exception => e
            @messages.async.<< [Time.new, e.to_s]
            @messages.async.<< [Time.new, e.backtrace]
            false
        end


        def ip
            vm = @hypervisor.find_vm(@fqdn)
            vm.ip

        rescue Exception => e
            @messages.async.<< [Time.new, e.to_s]
            @messages.async.<< [Time.new, e.backtrace]
            false
        end


        def answers_ping?
            service = @template.os != 'windows' ? 22 : 3389
            host = @address.nil? ? @fqdn : @address

            @messages.async.<< [Time.new, "pinging #{host}:#{service}"] if Chef::Config[:verbosity]

            pingable = Net::Ping::TCP.new(host, service).ping?

            @messages.async.<< [Time.new, 'host is not responding to ping'] if !pingable

            pingable

        rescue Exception => e
            @messages.async.<< [Time.new, e.to_s]
            @messages.async.<< [Time.new, e.backtrace]
            false
        end


        def remove_client
            if not @simulate
                clients = @rest_client.get_rest('/clients')
                @rest_client.delete_rest(clients[@fqdn]) if clients.has_key?(@fqdn)

                !@rest_client.get_rest('/clients').has_key?(@fqdn)
            else
                true
            end
        end


        def update_node
            if not @simulate
                nodes = @rest_client.get_rest('/nodes')
                if nodes.has_key?(@fqdn)
                    @messages.async.<< [Time.new, "updating run list: #{@node.run_list}"]
                    node = @rest_client.get_rest("/nodes/#{@fqdn}")
                    node.run_list = @node.run_list
                    @rest_client.put_rest("/nodes/#{@fqdn}", node)
                end
            end

        rescue Net::HTTPFatalError => hfe
            @messages.async.<< [Time.new, hfe.to_s]
        end

        def provision
            options = {
                :simulate => @simulate,
                :customization_vlan => @networks[0].name,
                :customization_hostname => @vm_name,
                :customization_domain => @networks[0].domain,
                :customization_cpucount => @cpu_count,
                :customization_memory => @memoryGB,
                :customization_nics => [],
                :resource_pool => @actor
            }

            @networks.length.times do |i|
                nic = OpenStruct.new()

                if @address.is_a?(Array) && i < @address.length && @address[i] != ''
                    nic.ip = "#{@address[i]}/#{@networks[i].subnet.split('/')[1]}"
                    nic.gateway = @networks[i].gateway if i == 0

                elsif i == 0 && !@address.nil?
                    nic.ip = "#{@address}/#{@networks[i].subnet.split('/')[1]}"
                end

                options[:customization_nics] << nic
            end

            if not @address.nil?
                options[:customization_dns_ips] = @networks[0].dns
                options[:customization_dns_suffixes] = @networks.map { |net| net.domain if net.domain != '' }.delete_if { |domain| domain == nil }
            end

            @messages.async.<< [Time.new, "Cloning from template #{@template.name}"]
            @hypervisor.clone(@template, @fqdn, options) { |msg| @messages.async.<< [Time.new, msg] }
            @messages.async.<< [Time.new, 'Finished creating virtual machine']

            true

        rescue Exception => e
            @messages.async.<< [Time.new, e.to_s]
            @messages.async.<< [Time.new, e.backtrace]
            false
        end


        def bootstrap
            template_dir = File.dirname(__FILE__)
            bootstrap_options = {
                :simulate => @simulate,
                :env => @env,
                :run_list => "#{@roles}",
                :use_sudo => @template.os == 'ubuntu',
                :bootstrap_version => '10.16.2-1',
                :template_file => "#{template_dir}/bootstrap.erb",
                :identity_file => "#{Chef::Config[:ssh_certificate_path]}/#{@template.key}"
            }

            bootstrap_options[:address] = @address if @address

            bootstrapper = CatererBootstrapper.new(@fqdn, @template.user, bootstrap_options)
            bootstrapper.run { |output| @messages.async.<< [Time.new, output] }

            true

        rescue Exception => e
            @messages.async.<< [Time.new, e.to_s]
            @messages.async.<< [Time.new, e.backtrace]
            false
        end


        def prepare_test_args(context, args)
            if args.is_a? Hash
                # Hash
                args.each_pair { |key, value| args[key] = prepare_test_args(context, value) }
            elsif args.is_a? Array
                # Array
                args.collect { |arg| prepare_test_args(context, arg) }
            elsif args.is_a? String
                # String
                Erubis::Eruby.new(args).evaluate(context)
            else
                args
            end
        end


        def execute_test(test)
            if test.has_key?('tester')
                begin
                    require "#{Chef::Config[:tests_path]}/#{test['tester']}.rb"
                    test_result = nil

                    if test.has_key?('args')
                        context = OpenStruct.new()

                        begin
                            # try to add the node (if it exists) to the arguments'
                            # context
                            context.node = @rest_client.get_rest("/nodes/#{@fqdn}")
                            tester_args = prepare_test_args(context, test['args'])
                            @messages.async.<< [Time.new, "running acceptance test, arguments: #{tester_args.inspect}"]

                            test_result = send("test_#{test['tester']}", *tester_args, @simulate == :dryrun) { |msg| @messages.async.<< [Time.new, msg] }

                        rescue Exception => e
                            @messages.async.<< [Time.new, e.to_s]
                            @messages.async.<< [Time.new, e.backtrace]
                            false
                        end
                    else
                        test_result = send("test_#{test['tester']}", @simulate == :dryrun) { |msg| @messages.async.<< [Time.new, msg] }
                    end

                    @messages.async.<< [Time.new, "test_#{test['tester']} returned #{test_result.inspect}"] if not test_result.nil?

                    true if test_result

                rescue Exception => e
                    @messages.async.<< [Time.new, e.to_s]
                    @messages.async.<< [Time.new, e.backtrace]
                    false
                end

            else
                false
            end
        end


        def is_ready?
            return nil if not @accept_test

            if @accept_test.is_a? Array
                @accept_test.length == @accept_test.count { |test| execute_test test }

            else
                execute_test @accept_test
            end

        rescue Exception => e
            @messages.async.<< [Time.new, e.to_s]
            @messages.async.<< [Time.new, e.backtrace]
            false
        end


        def runner
            @machine.transition :locate_vm
        end


        def to_s
            "#{@fqdn}(@state=#{@machine.state})"
        end

        alias_method :inspect, :to_s
    end
end
