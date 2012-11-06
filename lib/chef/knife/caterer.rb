require 'chef/knife'

class Chef
    class Knife
        class Caterer < Knife

            banner = 'knife caterer'

            deps do
                require 'chef/shef/ext'
            end

            option :composition,
                :short => "-d",
                :long => "--composition DESCRIPTION",
                :description => "Environment composition"

            option :phase,
                :short => "-p",
                :long => "--phase PHASENUM",
                :description => "Only run this phase"

            option :start_phase,
                :short => "-s",
                :long => "--start-phase PHASENUM",
                :description => "Start with this phase (default:0)",
                :default => 0

            option :final_phase,
                :short => "-f",
                :long => "--final-phase PHASENUM",
                :description => "Stop at this phase"

            option :dryrun,
                :short => "-n",
                :long => "--dry-run",
                :description => "Run simulation only, take no action"

            option :calculate,
                :short => "-c",
                :long => "--calculate-only",
                :description => "Calculate actions only, take no action"

            def read_composition

                @phases = Hash.new { |phases, phase| phases[phase] = Hash.new { |actors, name| actors[name] = [] } }
                @tasks = Hash.new { |hash, key| hash[key] = [] }
                @templates = {}
                @networks = {}
                @last_phase = 0

                if config[:dryrun]
                    simulation_mode = :dryrun
                elsif config[:calculate]
                    simulation_mode = :calc
                else
                    simulation_mode = nil
                end

                db = data_bag_item(config[:environment], config[:composition])

                db["vc"].each_pair do |vc, props|
                    @vc = Hypervisor.new(vc,
                                         props['host'],
                                         props['type'],
                                         :template_folder => props['template-folder'],
                                         :datastore => props['datastore'],
                                         :vm_folder => props['vm-folder'],
                                         :resource_pool => props['resource-pool'])
                end

                db["networks"].each_pair do |network, props|

                    @networks[network.to_sym] = Network.new(props['vlan'],
                                                            @vc,
                                                            props['dns'],
                                                            props['subnet'],
                                                            props['gateway'],
                                                            props['domain'])
                end

                db["templates"].each_pair do |template, props|

                    @templates[template.to_sym] = Template.new(props['name'],
                                                               @vc,
                                                               props['user'],
                                                               props['key'],
                                                               props['os'])
                end

                db["actors"].each_pair do |actor, props|

                    @last_phase = props['phase'] if props['phase'] > @last_phase

                    props["instances"].times do |instance|

                        address = nil
                        if props["addresses"].length > 0
                            address = props["addresses"][instance]
                        end

                        host = Host.new(actor,
                                        instance + 1, 
                                        config[:environment],
                                        @networks[props["networks"][0].to_sym].domain,
                                        props["run-list"],
                                        props["networks"].collect { |net| @networks[net.to_sym] },
                                        @templates[props["template"].to_sym],
                                        props["cpus"],
                                        props["memoryGB"],
                                        address,
                                        props["acceptance-test"],
                                        @vc,
                                        simulation_mode)

                        @phases[props["phase"].to_i][actor] << host
                    end
                end

                @last_phase = config[:final_phase].to_i if config.has_key?(:final_phase)
                puts "last phsae will be #{@last_phase}" if config[:verbosity]
            end

            def run
                $stdout.sync = true

                if config[:verbosity]
                    puts "Starting Caterer run"
                end

                Shef::Extensions.extend_context_object(self)

                read_composition()

                ui.output(@phases)

                run_phases = @phases.keys.sort.select do |phase|
                    phase >= config[:start_phase] and phase <= @last_phase
                end

                status = {}
                status[:phases] = Hash.new { |phases, phase| phases[phase] = Hash.new { |actors, name| actors[name] = {} } }

                @phases.each_pair do |phase, actors|
                    actors.each_pair do |name, hosts|
                        hosts.each do |host|
                            status[:phases][phase][name][host.fqdn] = host.state
                        end
                    end
                end
                status[:updated] = true
                status[:messages] = []

                run_phases.each do |phase|

                    futures = {}
                    completed = []
                    states = []

                    @phases[phase].each_pair do |name, hosts|
                        hosts.each do |host|
                            futures[host] = {
                                :future => host.future.runner,
                                :name => host.fqdn,
                                :actor => name
                            }
                            states << host.state
                        end
                    end

                    puts "Waiting on #{futures.length} future(s)"
                    while futures.length > completed.length
                        completed = futures.values.select { |dict| dict[:future].ready? }

                        futures.each_pair do |host, dict|
                            host.async.state do |state|
                                if status[:phases][phase][dict[:actor]][dict[:name]] != state
                                    status[:phases][phase][dict[:actor]][dict[:name]] = state
                                    status[:updated] = true
                                end
                            end

                            host.messages.async.delete_if do |msg|
                                if msg.respond_to? :gsub
                                    status[:messages] << msg.gsub(/^/, "#{dict[:name]}: ")

                                elsif msg.is_a? Array
                                    msg.each do |m|
                                        status[:messages] << m.gsub(/^/, "#{dict[:name]}: ")
                                    end
                                end
                            end
                        end

                        if status[:updated]
                            ui.output(status[:phases])
                            status[:updated] = false
                            puts "Waiting for #{futures.length - completed.length} more future(s) to finish"

                        elsif status[:messages].length > 0
                            status[:messages].delete_if { |msg| puts msg or true }

                        else
                            sleep 1
                        end
                    end

                    futures.delete_if { |host, dict| host.success }

                    ui.output(status[:phases])

                    if futures.length > 0
                        # some host failed
                        futures.keys.each { |host| host.messages.delete_if { |msg| puts msg or true } }
                        ui.output(futures.keys)
                        break
                    end
                end

            rescue Exception => e
                puts e.to_s
                puts e.backtrace
            end
        end
    end
end
