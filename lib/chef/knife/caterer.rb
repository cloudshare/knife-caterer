require 'chef/knife'
require 'catering'

module KnifeCaterer
    class Caterer < Chef::Knife

        include Catering

        banner 'knife caterer'

        deps do
            require 'chef/shef/ext'
        end

        option :composition,
            :short => '-d',
            :long => '--composition DESCRIPTION',
            :description => 'Environment composition'

        option :phase,
            :short => '-p',
            :long => '--phase PHASENUM',
            :description => 'Only run this phase'

        option :start_phase,
            :short => '-s',
            :long => '--start-phase PHASENUM',
            :description => 'Start with this phase (default:0)',
            :default => 0

        option :final_phase,
            :short => '-f',
            :long => '--final-phase PHASENUM',
            :description => 'Stop at this phase'

        option :dryrun,
            :short => '-n',
            :long => '--dry-run',
            :description => 'Run simulation only, take no action'

        option :calculate,
            :short => '-c',
            :long => '--calculate-only',
            :description => 'Calculate actions only, take no action'

        def read_composition

            @phases = Hash.new { |phases, phase| phases[phase] = Hash.new { |actors, name| actors[name] = [] } }
            @tasks = Hash.new { |hash, key| hash[key] = [] }
            @hypervisors = {}
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

            db['vc'].each_pair { |vc, props| @hypervisors[vc] = Catering::Hypervisor.new(Mash.new(props)) }

            db['networks'].each_pair do |network, props|

                options = Mash.new(props)
                options[:hypervisor] = @hypervisors[props['vc']]

                @networks[network.to_sym] = Catering::Network.new(options)
            end

            db['templates'].each_pair do |template, props|

                options = Mash.new(props)
                options[:hypervisor] = @hypervisors[props['vc']]

                @templates[template.to_sym] = Catering::Template.new(options[:name], options)
            end

            db['actors'].each_pair do |actor, props|

                @last_phase = props['phase'] if props['phase'] > @last_phase

                props['instances'].times do |instance|

                    address = props['addresses'].length > 0 ? props['addresses'][instance] : nil

                    vc = instance.modulo props['vcs'].length
                    host = Catering::Host.new(
                                actor,
                                instance + 1, 
                                config[:environment],
                                @networks[props['networks'][0].to_sym].domain,
                                props['run-list'],
                                props['networks'].collect { |net| @networks[net.to_sym] },
                                @templates[props['template'].to_sym],
                                props['cpus'],
                                props['memoryGB'],
                                address,
                                props['acceptance-test'],
                                @hypervisors[props['vcs'][vc]],
                                simulation_mode
                    )

                    @phases[props['phase'].to_i][actor] << host
                end
            end

            @last_phase = config[:final_phase].to_i if config.has_key?(:final_phase)
            puts "last phsae will be #{@last_phase}" if config[:verbosity]
        end

        def run
            puts 'Starting Caterer run'

            Shef::Extensions.extend_context_object(self)

            puts 'Reading environment composition'
            read_composition()

            ui.output(@phases)

            config[:start_phase] = config[:phase] if config[:phase]

            run_phases = @phases.keys.sort.select { |phase| phase >= config[:start_phase].to_i && phase <= @last_phase }

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

                        host.async.process_messages do |msg|
                            if msg.is_a? Array
                                time, text = msg

                                if text.respond_to? :gsub
                                    status[:messages] << text.gsub(/^/, "[#{time}] #{dict[:name]}: ")

                                elsif msg.is_a? Array
                                    text.each { |m| status[:messages] << m.gsub(/^/, "[#{time}] #{dict[:name]}: ") }
                                end
                            end

                            true
                        end
                    end

                    if status[:updated]
                        ui.output(status[:phases])
                        status[:updated] = false

                    elsif status[:messages].length > 0
                        status[:messages].delete_if { |msg| puts msg or true }

                    else
                        sleep 1
                    end
                end

                if status[:messages].length > 0
                    status[:messages].delete_if { |msg| puts msg or true }
                end

                futures.delete_if { |host, dict| host.success }

                ui.output(status[:phases])

                if futures.length > 0
                    # some host failed
                    futures.keys.each { |host| host.process_messages { |msg| puts msg or true } }
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
