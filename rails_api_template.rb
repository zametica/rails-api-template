# frozen_string_literal: true

use_devise = ARGV.include? '--devise'
db_username = ask 'Postgres username (default: postgres)'
db_password = ask 'Postgres password (blank by default)'
app_name = @app_name.upcase

say 'Setting up the database', :yellow

db_config = <<-CODE
  username: <%= ENV['#{app_name}_DATABASE_USERNAME'] %>
  password: <%= ENV['#{app_name}_DATABASE_PASSWORD'] %>
CODE

%w[development test].each do |env|
  inject_into_file 'config/database.yml', db_config, after: "database: #{@app_name}_#{env}\n", force: true
  file ".env.#{env}", <<~CODE
    export #{app_name}_DATABASE_USERNAME=#{db_username.blank? ? 'postgres' : db_username}
    export #{app_name}_DATABASE_PASSWORD=#{db_password}
  CODE
end

if use_devise
  say 'Using devise...', :yellow
  # due to missing rails 7 support it has to come from the git source
  gem 'devise_token_auth', '>= 1.2.0', git: 'https://github.com/lynndylanhurley/devise_token_auth'

  application_controller = <<-CODE
  # frozen_string_literal: true

  class ApplicationController < ActionController::API
    include DeviseTokenAuth::Concerns::SetUserByToken
    before_action :configure_permitted_parameters, if: :devise_controller?

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
        render json: Users::UsersActivity.all, status: :ok
      end
    end
  end
  CODE

  file 'app/controllers/application_controller.rb', application_controller, force: true
  file 'app/controllers/api/v1/users_controller.rb', users_controller

  users_activity = <<-CODE
  # frozen_string_literal: true

  module Users
    class UsersActivity
      def self.all
        User.all
      end
    end
  end
  CODE

  file 'app/activities/users/users_activity.rb', users_activity

  inject_into_file 'db/seeds.rb' do
    <<~RUBY
      User.create({ email: 'test@example.com', password: 'P@ssw0rd', password_confirmation: 'P@ssw0rd' })
    RUBY
  end

  users_activity_spec = <<-CODE
  require 'rails_helper'

  RSpec.describe Users::UsersActivityTest do
    describe '#all' do
      context 'when users exist' do
        it 'returns a non-empty list' do
          User.create!({ email: 'test@all.com', password: 'P@ssw0rd' })
          assert_not_empty Users::UsersActivity.all
        end
      end

      context 'when users do not exist' do
        it 'returns empty list' do
          User.delete_all
          assert_empty Users::UsersActivity.all
        end
      end
    end
  end
  CODE

  users_factory = <<-RUBY
  FactoryBot.define do
    factory :user do
      email { Faker::Internet.email }
    end
  end
  RUBY

  file 'spec/activities/users/users_activity_test.rb', users_activity_spec
  file 'spec/factories/users.rb', users_factory

  route <<-CODE
    namespace :api, defaults: { format: :json } do
      namespace :v1 do
        resources :users, only: %i(index)
      end
    end
  CODE
end

say 'Application config', :yellow

application "config.autoload_paths += %W(\#{config.root}/lib)"

file 'app/activities/base_activity.rb', <<~RUBY
  class BaseActivity; end
RUBY

say 'Initializing error serializer', :yellow

file 'lib/error_serializer.rb', <<~RUBY
  module ErrorSerializer
    def self.serialize(errors)
      return if errors.nil?

      json = {}
      new_hash = errors.to_hash(true).map do |k, v|
        v.map do |msg|
          { status: '422', title: k, detail: msg }
        end
      end

      json[:errors] = new_hash.flatten
      json
    end
  end
RUBY

inject_into_file 'app/controllers/application_controller.rb',
                 after: /ActionController::API\n/ do
  <<-RUBY
    rescue_from ActiveRecord::RecordNotFound, with: :not_found
    rescue_from ActiveRecord::RecordInvalid,  with: :unprocessable_entity

    private

    def not_found
      head :not_found
    end

    def unprocessable_entity(error)
      render json: ErrorSerializer.serialize(error.record.errors), status: :unprocessable_entity
    end

  RUBY
end

say 'Configuring gems', :yellow

inject_into_file 'Gemfile', after: 'group :development, :test do' do
  <<-RUBY

  gem 'dotenv-rails'
  gem 'rubocop', require: false
  gem 'rspec-rails'
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

say 'Rubocop config', :yellow
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

say 'Git ignore', :yellow
inject_into_file '.gitignore' do
  <<~CODE
    .byebug_history
    /coverage
    .DS_Store
    .env*
  CODE
end

after_bundle do
  rails_command 'db:drop db:create'
  generate_devise if use_devise
  generate_rspec
  scaffold
  rails_command 'db:migrate'
  rails_command 'db:seed'
  run 'bin/spring stop'
  git :init
  git add: '.'
  git commit: "-a -m 'Initial commit'"
end

def generate_devise
  rails_command 'generate devise:install'
  rails_command 'generate devise_token_auth:install User api/v1/auth'
end

def generate_rspec
  rails_command 'generate rspec:install'

  inject_into_file 'spec/spec_helper.rb', before: 'RSpec.configure do |config|' do
    <<~RUBY
      require 'simplecov'

      SimpleCov.start do
        minimum_coverage(95.0)
        add_filter '/test/'
      end

    RUBY
  end
end

def scaffold
  scaffold_key = '--scaffold='
  scaffold = ARGV.find { |a| a.start_with? scaffold_key }
  generate(:scaffold, scaffold[scaffold_key.size..]) if scaffold
end
