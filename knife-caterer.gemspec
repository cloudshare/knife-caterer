Gem::Specification.new do |s|
  s.name        = 'knife-caterer'
  s.version     = '0.0.1'
  s.date        = '2012-10-28'
  s.summary     = "Manage provisining of complete environments"
  s.description = "A Chef Knife plugin to automate provisioning of complete environments"
  s.required_rubygems_version = Gem::Requirement.new(">=0") if s.respond_to? :required_rubygems_version=
  s.authors     = ["Leeor Aharon"]
  s.email       = 'leeor.aharon@gmail.com'
  s.files       = Dir["lib/**/*"]
  s.homepage    =
    'http://rubygems.org/gems/knife-caterer'

  s.add_dependency('knife-vsphere', [">= 0.2.3"])
end
