# frozen_string_literal: true

require "active_record"
require "fabrication"
require "test_prof"
require "test_prof/factory_bot"

require "activerecord-jdbc-adapter" if defined? JRUBY_VERSION
require "activerecord-jdbcsqlite3-adapter" if defined? JRUBY_VERSION

begin
  require "activerecord-import"
rescue LoadError
end

def sqlite_file_config
  FileUtils.mkdir_p TestProf.config.output_dir
  db_path = File.join(TestProf.config.output_dir, "testdb.sqlite")
  db_path_2 = File.join(TestProf.config.output_dir, "testdb_2.sqlite")

  FileUtils.rm(db_path) if File.file?(db_path)
  FileUtils.rm(db_path_2) if File.file?(db_path_2)

  {
    primary: {
      database: db_path,
      adapter: "sqlite3"
    },
    secondary: {
      database: db_path_2,
      adapter: "sqlite3"
    }
  }
end

def postgres_config
  require "active_record/database_configurations"

  configs = []
  configs << ActiveRecord::DatabaseConfigurations::UrlConfig.new(
    "test",
    "primary",
    ENV.fetch("DATABASE_URL"),
    {"database" => ENV.fetch("DB_NAME", "test_prof_test")}
  )

  configs << ActiveRecord::DatabaseConfigurations::UrlConfig.new(
    "test",
    "secondary",
    ENV.fetch("DATABASE_URL_2"),
    {"database" => ENV.fetch("DB_NAME_2", "test_prof_test_2")}
  )
end

DB_CONFIG =
  case ENV["DB"]
  when "sqlite-file"
    sqlite_file_config
  when "postgres"
    postgres_config
  else
    {
      primary: {
        database: ":memory:",
        adapter: "sqlite3"
      },
      secondary: {
        database: ":memory:",
        adapter: "sqlite3"
      }
    }
  end

ActiveRecord::Base.configurations = DB_CONFIG
ActiveRecord::Base.legacy_connection_handling = false if ActiveRecord::Base.respond_to?(:legacy_connection_handling)

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: {writing: :primary}
end

class User < ApplicationRecord
  validates :name, presence: true
  has_many :posts, dependent: :destroy

  def clone
    copy = dup
    copy.name = "#{name} (cloned)"
    copy
  end
end

class Post < ApplicationRecord
  belongs_to :user

  attr_accessor :dirty
end

class SecondaryRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: {writing: :secondary}
end

class Event < SecondaryRecord
end

# #truncate_tables is not supported in older Rails, let's just ignore the failures
ApplicationRecord.connection.truncate_tables(*ApplicationRecord.connection.tables) rescue nil # rubocop:disable Style/RescueModifier
SecondaryRecord.connection.truncate_tables(*SecondaryRecord.connection.tables) rescue nil # rubocop:disable Style/RescueModifier

ActiveRecord::Schema.define do
  @connection = ApplicationRecord.connection
  using_pg = @connection.adapter_name == "PostgreSQL"

  enable_extension "pgcrypto" if using_pg

  create_table :users, id: (using_pg ? :uuid : :bigint), if_not_exists: true do |t|
    t.string :name
    t.string :tag
  end

  create_table :posts, if_not_exists: true do |t|
    t.text :text
    if using_pg
      t.uuid :user_id
    else
      t.bigint :user_id
    end
    t.foreign_key :users
    t.timestamps
  end
end

ActiveRecord::Schema.define do
  @connection = SecondaryRecord.connection
  using_pg = @connection.adapter_name == "PostgreSQL"

  enable_extension "pgcrypto" if using_pg

  create_table :events, id: (using_pg ? :uuid : :bigint), if_not_exists: true do |t|
    t.string :data
  end
end

ActiveRecord::Base.logger = Logger.new($stdout) if ENV["LOG"]

TestProf::FactoryBot.define do
  factory :user do
    sequence(:name) { |n| "John #{n}" }

    trait :with_posts do
      after(:create) do
        TestProf::FactoryBot.create_pair(:post)
      end
    end

    trait :traited do
      tag { "traited" }
    end

    trait :other_trait do
      tag { "other_trait" }
    end
  end

  factory :post do
    sequence(:text) { |n| "Post ##{n}" }
    user

    trait :with_bad_user do
      user { create(:user) }
    end

    trait :with_traited_user do
      association :user, factory: %i[user traited]
    end

    trait :with_other_traited_user do
      association :user, factory: %i[user other_trait]
    end
  end

  factory :event do
    sequence(:data) { |n| "Event ##{n}" }
  end
end

Fabricator(:user) do
  name Fabricate.sequence(:name) { |n| "John #{n}" }
end

Fabricator(:post) do
  text Fabricate.sequence(:text) { |n| "Post ##{n}}" }
  user
end

Fabricator(:event) do
  data Fabricate.sequence(:data) { |n| "Event ##{n}}" }
end
