inject_into_file 'Gemfile', before: 'group :development, :test do' do
  <<~RUBY
    gem 'devise_token_auth'

  RUBY
end

inject_into_file 'Gemfile', after: 'group :development, :test do' do
  <<-RUBY

  gem 'dotenv-rails'
  gem 'rubocop', require: false
  gem 'factory_bot_rails'
  RUBY
end

gem_group :development do
  gem 'web-console'
end

gem_group :test do
  gem 'shoulda-matchers'
  gem 'simplecov', require: false
  gem 'webmock'
  gem 'faker'
end

## CONFIG
file '.rubocop.yml', <<-CODE
  require:
    AllCops:
      Exclude:
        - db/**
        - db/migrate/**
        - bin/**
        - vendor/**/*

    Layout/LineLength:
      Max: 120

    Metrics/BlockLength:
      Exclude:
        - config/**/*

    Style/Documentation:
      Enabled: false
CODE

## CONTROLLERS
application_controller = <<-CODE
# frozen_string_literal: true

class ApplicationController < ActionController::API
  include DeviseTokenAuth::Concerns::SetUserByToken
  before_action :configure_permitted_parameters, if: :devise_controller?
  respond_to :json

  protected

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: %i(username first_name last_name))
  end
end
CODE

users_controller = <<-CODE
# frozen_string_literal: true

module Api::V1
  class UsersController < ApplicationController
    def index
      render json: UsersService.new.all, status: :ok
    end
  end
end
CODE

file 'app/controllers/application_controller.rb', application_controller, force: true
file 'app/controllers/api/v1/users_controller.rb', users_controller

## SERVICES
users_service = <<-CODE
#frozen_string_literal: true

module Api::V1
  class UsersService
    def all
      User.all
    end
  end
end
CODE

file 'app/services/api/v1/users_service.rb', users_service

## SEED
inject_into_file 'db/seeds.rb' do
  <<~RUBY
    User.create({ email: 'test@example.com', password: 'P@ssw0rd', password_confirmation: 'P@ssw0rd' })
  RUBY
end

## TEST
users_service_spec = <<-CODE
require 'test_helper'

class Api::V1::UsersServiceTest < ActiveSupport::TestCase
  def setup
    @service = Api::V1::UsersService.new
  end

  test '#all when users exist' do
    User.create!({ email: 'test@all.com', password: 'P@ssw0rd' })
    assert_not_empty @service.all
  end

  test '#all when users do not exist' do
    User.delete_all
    assert_empty @service.all
  end
end
CODE
users_fixture = <<-CODE
test:
  email: <%= Faker::Internet.email %>
CODE

file 'test/services/api/v1/users_service_test.rb', users_service_spec
file 'test/fixtures/users.yml', users_fixture

inject_into_file 'test/test_helper.rb', after: "require 'rails/test_help'" do
  <<-RUBY

  require 'simplecov'
  SimpleCov.start do
    minimum_coverage(95.0)
    add_filter '/test/'
  end
  RUBY
end

## DB
rails_command 'db:drop db:create'
rails_command 'generate devise:install'
rails_command 'generate devise_token_auth:install User api/v1/auth'
rails_command 'db:migrate'
rails_command 'db:seed'

route <<-CODE
  namespace :api, defaults: { format: :json } do
    namespace :v1 do
      resources :users, only: %i(index)
    end
  end
CODE

inject_into_file '.gitignore' do
  <<~CODE
    /coverage
    .DS_Store
    *.env
  CODE
end

after_bundle do
  run 'bin/spring stop'
  git :init
  git add: '.'
  git commit: "-a -m 'Initial commit'"
end

