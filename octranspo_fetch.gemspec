Gem::Specification.new do |s|
  s.name        = 'octranspo_fetch'
  s.version     = '0.0.5'
  s.date        = '2016-09-05'
  s.summary     = "Fetch data from OC Tranpo API"
  s.description = "A simple wrapper around the OC Transpo API with some minimal caching."
  s.authors     = ["Jason Walton", "Kevin Ross"]
  s.files       = ["lib/octranspo_fetch.rb"]
  s.homepage    =
    'http://rubygems.org/gems/octranspo_fetch'
  s.license       = 'MIT'
  s.add_runtime_dependency "nokogiri",    [">= 1.5.10"]
  s.add_runtime_dependency "rest-client", [">= 1.6.7"]
  s.add_runtime_dependency "lru_redux",   [">= 0.8.1"]
end
