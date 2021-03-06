#!/usr/bin/env ruby
require 'dotenv'
require 'erubis'

def osx?
  RUBY_PLATFORM.downcase =~ /darwin/
end

# This script will create a fully-working gov.uk-style setup locally

`./make_env`
Dotenv.load './env'

organisation = 'theodi'

projects     = {
  'signonotron2' =>     'signon',
  'static' =>           'static',
  'panopticon' =>       'panopticon',
  'publisher' =>        'publisher',
  'asset-manager' =>    'asset-manager',
  'content_api' =>      'contentapi',
  'frontend-www' =>     'www',
  'rummager' =>         'search'
}

def colour text, colour
  "\x1b[%sm%s\x1b[0m" % [
    colour,
    text
  ]
end

def red text
  colour text, "31"
end

def green text
  colour text, "32"
end

def make_vhost ourname, port
  if osx?
    # Add pow symlink
    system "rm ~/.pow/#{ourname}"
    command = "ln -sf %s/%s ~/.pow/%s" % [
      Dir.pwd,
      ourname,
      ourname
    ]
    system command
    # Symlink powrc file to load rvm correctly
    command = "ln -sf %s/powrc %s/%s/.powrc" % [
      Dir.pwd,
      Dir.pwd,
      ourname
    ]
    system command
  else
    template = File.read("templates/vhost.erb")
    template = Erubis::Eruby.new(template)
    f = File.open "#{ourname}/vhost", "w"
    f.write template.result(
      :servername => ourname,
      :port => port,
      :domain => ENV['GOVUK_APP_DOMAIN'],
    )
    f.close

    command = "sudo rm -f /etc/nginx/sites-enabled/%s" % [
      ourname
    ]
    system command

    command = "sudo ln -sf %s/%s/vhost /etc/nginx/sites-enabled/%s" % [
      Dir.pwd,
      ourname,
      ourname
    ]
    system command
  end
end

puts green "We're going to grab all the actual applications we need."

pwd = `pwd`.strip

port = 3000
projects.each_pair do |theirname, ourname|
  if not Dir.exists? ourname.to_s
    puts "%s %s %s %s" % [
      green("Cloning"),
      red(theirname),
      green("into"),
      red(ourname)
    ]
    system "git clone https://github.com/#{organisation}/#{theirname}.git #{ourname}"
  else
    puts "%s %s" % [
      green("Updating"),
      red(ourname)
    ]
    system "cd #{ourname} && git pull origin master && cd ../"
  end

  puts "%s %s" % [
    green("Bundling"),
    red(ourname)
  ]

  Dir.chdir ourname do
    system "bundle"
  end

  env_path = "%s/env" % [
    Dir.pwd,
  ]
  system "rm -f #{ourname}/.env"
  system "ln -sf #{env_path} #{ourname}/.env"

  unless osx?
    if File.exists? "%s/Procfile" % [
      ourname
    ]

      puts "%s %s" % [
        green("Generating upstart scripts for"),
        red(ourname)
      ]

      Dir.chdir ourname.to_s do
        command = "sudo bundle exec foreman export -a %s -u %s -p %d upstart /etc/init" % [
          ourname,
          `whoami`.strip,
          port
        ]
        system command
      end
    end
  end

  make_vhost ourname, port

  port += 1000
end

# THINGS BEYOND HERE ARE DESTRUCTIVE
#exit

puts green "Now we need to generate application tokens in the signonotron."

def oauth_id(output)
  output.match(/config.oauth_id     = '(.*?)'/)[1]
end

def oauth_secret(output)
  output.match(/config.oauth_secret = '(.*?)'/)[1]
end

def bearer_token(output)
  output.match(/Access token: ([0-9a-z]*)/)[1]
end

Dir.chdir("signon") do

  puts green "Setting up signonotron database..."

  system "bundle exec rake db:create; bundle exec rake db:migrate"

  puts green "Make signonotron work in dev mode..."

  system "bundle exec ./script/make_oauth_work_in_dev"

  apps = {
    'panopticon' => 'metadata management',
    'publisher' => 'content editing',
    'asset-manager' => 'media uploading',
    'contentapi' => 'internal API for content access',
  }
  apps.each_pair do |app, description|

    puts "%s %s" % [
      green("Generating application keys for"),
      red(app)
    ]

    begin
      str = `bundle exec rake applications:create name=#{app} description="#{description}" home_uri="http://#{app}.#{ENV['GOVUK_APP_DOMAIN']}" redirect_uri="http://#{app}.#{ENV['GOVUK_APP_DOMAIN']}/auth/gds/callback" supported_permissions=signin,access_unpublished`
      File.open('../oauthcreds', 'a') do |f|
        f << "#{app.upcase.gsub('-','_')}_OAUTH_ID=#{oauth_id(str)}\n"
        f << "#{app.upcase.gsub('-','_')}_OAUTH_SECRET=#{oauth_secret(str)}\n"
      end
    rescue
      nil
    end

  end

  # Generate bearer tokens for asset-manager clients

  api_clients = [
    'publisher',
    'contentapi'
  ]
  api_clients.each do |app|

    puts "%s %s" % [
      green("Generating bearer tokens for"),
      red(app)
    ]

    begin
      str = `bundle exec rake api_clients:create[#{app},"#{app}@example.com",asset-manager,signin]`
      File.open('../oauthcreds', 'a') do |f|
        f << "#{app.upcase.gsub('-','_')}_ASSET_MANAGER_BEARER_TOKEN=#{bearer_token(str)}\n"
        f << "#{app.upcase.gsub('-','_')}_API_CLIENT_BEARER_TOKEN=#{bearer_token(str)}\n"
      end
    rescue
      nil
    end

  end

  # Generate bearer tokens for content API clients

  puts green("Generating content-api bearer tokens for frontends")

  begin
    # Create a frontend application
    str = `bundle exec rake applications:create name=frontends description="Front end apps" home_uri="http://frontends.#{ENV['GOVUK_APP_DOMAIN']}" redirect_uri="http://frontends.#{ENV['GOVUK_APP_DOMAIN']}/auth/gds/callback" supported_permissions=access_unpublished`
    # Generate a bearer token for frontends to access contentapi
    str = `bundle exec rake api_clients:create[frontends,"frontends@example.com",contentapi,access_unpublished]`
    File.open('../oauthcreds', 'a') do |f|
      f << "QUIRKAFLEEG_FRONTEND_CONTENTAPI_BEARER_TOKEN=#{bearer_token(str)}\n"
    end
  rescue
    nil
  end


  puts green "We'll generate a couple of sample users for you. You can add more by doing something like:"
  puts red "$ cd signon"
  puts red "$ GOVUK_APP_DOMAIN=#{ENV['GOVUK_APP_DOMAIN']} DEV_DOMAIN=#{ENV['DEV_DOMAIN']} bundle exec rake users:create name='Alice' email=alice@example.com applications=#{apps.keys.join(',')}"

  {
    'alice' => 'alice@example.com',
    'bob' => 'bob@example.com',
  }.each_pair do |name, email|
    begin
      system "GOVUK_APP_DOMAIN=#{ENV['GOVUK_APP_DOMAIN']} DEV_DOMAIN=#{ENV['DEV_DOMAIN']} bundle exec rake users:create name='#{name}' email=#{email} applications=#{apps.keys.join(',')}"
    rescue
      nil
    end
  end

end

Dir.chdir('search') do
  puts green("Creating indices for rummager")
  system 'RUMMAGER_INDEX=all bundle exec rake rummager:migrate_index'
end

system './make_env'

# Seed data in panopticon - tags, really
Dir.chdir("panopticon") do
  system "bundle exec rake db:seed"
end

projects.each_pair do |theirname, ourname|
  if osx?
    system "mkdir -p #{ourname}/tmp"
    system "touch #{ourname}/tmp/restart.txt"
  else
    `sudo service #{ourname} restart`
  end
end

unless osx?
  system "sudo service nginx restart"
end
