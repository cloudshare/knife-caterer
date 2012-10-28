require 'chef/knife'

class Chef
    class Knife
        class Caterer < Knife

            banner = 'knife caterer'

            deps do
                require 'chef/shef/ext'
                require 'thread'
                require 'net/ping/tcp'
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
                :long => "--phase-start PHASENUM",
                :description => "Start with this phase (default:0)"

            option :final_phase,
                :short => "-f",
                :long => "--phase-final PHASENUM",
                :description => "Stop at this phase"

            option :dryrun,
                :short => "-n",
                :long => "--dry-run",
                :description => "Run simulation only, take no action"

            def read_composition()

                @actors = Hash.new { |hash, key| hash[key] = [] }
                @tasks = Hash.new { |hash, key| hash[key] = [] }
                @templates = {}
                @networks = {}
                @last_phase = 0

                db = data_bag_item(config[:environment], config[:composition])

                @vc = db["vc"]

                db["networks"].each_pair do |network, props|

                    @networks[network.to_sym] = Network.new(props['vlan'],
                                                            props['dns'],
                                                            props['subnet'],
                                                            props['gateway'],
                                                            props['domain'])
                end

                db["templates"].each_pair do |template, props|

                    @templates[template.to_sym] = Template.new(props['name'],
                                                            props['vc'],
                                                            props['user'],
                                                            props['key'],
                                                            props['os'],
                                                            @vc[props['vc']]['template-folder'])
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
                                        $options[:environment],
                                        @networks[props["networks"][0].to_sym].domain,
                                        props["roles"],
                                        props["networks"].collect {|net| @networks[net.to_sym]},
                                        @templates[props["template"].to_sym],
                                        props["cpus"],
                                        props["memoryGB"],
                                        address,
                                        props["phase"],
                                        props["acceptance-test"],
                                        @vc[@templates[props["template"].to_sym].vc]['vm-folder'],
                                        @vc[@templates[props["template"].to_sym].vc]['resource-pool'])

                        @actors[actor] << host
                    end
                end

                @last_phase = $options[:final_phase] if $options.has_key?(:final_phase)
            end

            def run()
                if config[:verbosity]
                    puts "Starting Caterer run"
                end

                Shef::Extensions.extend_context_object(self)

                read_composition()

                repeat = true
                phase = $options[:start_phase]

                while repeat
                    repeat = false
                    progress_made = false

                    @actors.each_pair do |name, hosts|

                        hosts.each do |host|

                            next if host.phase != phase

                            host_in_progress, host_made_progress, status = host.run()

                            repeat ||= host_in_progress
                            progress_made ||= host_made_progress
                        end
                    end

                    if repeat
                        if !progress_made
                            sleep(1)
                        else
                            ui.output(@actors)
                        end
                    else
                        phase += 1

                        if phase <= @last_phase
                            repeat = true
                        end
                    end
                end

                ui.output(@actors)
            end
        end
    end
end
