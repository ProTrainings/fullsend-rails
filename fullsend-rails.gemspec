lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "fullsend/version"

Gem::Specification.new do |spec|
  spec.name          = "fullsend-rails"
  spec.version       = Fullsend::VERSION
  spec.authors       = ["ProTrainings"]
  spec.summary       = "SQS-based ActionMailer delivery for the Fullsend email service"
  spec.description   = "Rails gem providing an ActionMailer delivery method that sends emails as JSON to an SQS FIFO queue, plus campaign tracking header helpers."
  spec.homepage      = "https://github.com/protrainings/fullsend-rails"
  spec.license       = "MIT"
  # Floors kept low so older consumers (e.g. blendedcpr on Ruby 2.6 / Rails
  # 5.2) can use the gem. The code targets no feature newer than these.
  spec.required_ruby_version = ">= 2.6"

  spec.files         = Dir["lib/**/*", "LICENSE.txt", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "aws-sdk-s3", "~> 1.0"
  spec.add_dependency "aws-sdk-sqs", "~> 1.0"
  spec.add_dependency "rails", ">= 5.2"

  spec.add_development_dependency "rspec", "~> 3.0"
end
