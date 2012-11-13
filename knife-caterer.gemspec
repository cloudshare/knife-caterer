Gem::Specification.new do |s|
  s.name        = 'knife-caterer'
  s.version     = '0.1.0'
  s.date        = '2012-11-13'
  s.summary     = "Manage provisining of complete environments"
  s.description = "A Chef Knife plugin to automate provisioning of complete environments"
  s.required_rubygems_version = Gem::Requirement.new(">=0") if s.respond_to? :required_rubygems_version=
  s.authors     = ["Leeor Aharon"]
  s.email       = 'leeor.aharon@gmail.com'
  s.files       = Dir["lib/**/*"]
  s.homepage    =
    'http://rubygems.org/gems/knife-caterer'

  s.add_dependency('rbvmomi', ["= 1.5.1"])
  s.add_dependency('celluloid', [">= 0.12.3"])
  s.add_dependency('net-ssh', [">= 2.2.2"])
end
