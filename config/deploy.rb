require "bundler/capistrano"
require "airbrake/capistrano"

set :application, "shelr"

set :scm, :git
set :repository, "git://github.com/antono/shelr.tv.git"
set :user, 'shelr'
set :branch, :master
set :deploy_via, :remote_cache

ssh_options[:forward_agent] = true
ssh_options[:port] = 22

role :web, "shelr"                          # Your HTTP server, Apache/etc
role :app, "shelr"                          # This may be the same as your `Web` server
role :db,  "shelr", :primary => true        # This is where Rails migrations will run

default_run_options[:pty] = true

def restart_unicorn signal = 'USR2'
  run "kill -#{signal} `cat #{shared_path}/pids/unicorn.pid`"
end

namespace :deploy do
  task :start do
    run "cd #{current_path} && bundle exec unicorn -E production -D -c config/unicorn.production.rb"
  end

  task :stop do
    run "kill -9 `cat #{shared_path}/pids/unicorn.pid`"
  end

  task :restart do
    restart_unicorn
  end

end

namespace :sitemap do
  task :copy_old do
    run "if [ -e #{previous_release}/public/sitemap_index.xml.gz ];
           then cp #{previous_release}/public/sitemap* #{current_release}/public/;
         fi"
  end

  task :refresh do
    run "cd #{latest_release} && RAILS_ENV=production bundle exec rake sitemap:refresh"
    run "cd #{latest_release} && mv public/sitemap* public/assets/"
  end
end


namespace :solr do
  task :start do
    run "cd #{current_path} && RAILS_ENV=production bundle exec rake sunspot:solr:start"
  end

  task :stop do
    run "cd #{current_path} && RAILS_ENV=production bundle exec rake sunspot:solr:stop"
  end

  task :restart do
    run "cd #{current_path} && RAILS_ENV=production bundle exec rake sunspot:solr:stop"
    run "cd #{current_path} && RAILS_ENV=production bundle exec rake sunspot:solr:start"
  end
end

namespace :config do
  namespace :unicorn do
    config_path = ::Pathname.new ::File.expand_path('..', __FILE__)
    file_name   = 'unicorn.production.rb'

    task :generate, roles: [:app] do
      require 'erb'

      template = ::ERB.new ::File.read(config_path.join(%{#{file_name}.erb}))

      ::File.open config_path.join(%{../tmp/unicorn.#{stage}.conf.rb}), 'w+' do |file|
        file.write template.result(binding)
      end
    end

    task :upload, roles: [:app] do
      top.upload config_path.join(%{../tmp/unicorn.#{stage}.rb}).to_s,
                 %{#{current_path}/config/#{file_name}},
                 via: :scp
    end

    before 'config:unicorn:upload', 'config:unicorn:generate'

    task :apply, roles: [:app] do
      generate
      upload
      restart_unicorn 'HUP'
    end

  end

  # copy configs from shared path

  task :cp, roles: [:app] do
    run %{cp -Rf #{shared_path}/configs/* #{latest_release}/config}
  end

end

_cset(:backup_path) { "#{shared_path}/backups" }
_cset(:skip_backup_tables, ['sessions'])

namespace :backup do

  def latest
    capture("cd #{backup_path} && ls -t | head -1").strip
  end

  desc "Create a backup on the server"
  task :create, :roles => :db, :only => {:primary => true} do
    rails_env = fetch(:rails_env, "production")
    skip_tables = Array(skip_backup_tables).join(',')
    run "cd #{current_path}; bundle exec rake db:backup:create RAILS_ENV=#{rails_env} BACKUP_DIR=#{backup_path} SKIP_TABLES=#{skip_tables}"
  end

  desc "Retreive a backup from the server. Gets the latest by default, set :backup_version to specify which version to copy"
  task :download, :roles => :db, :only => {:primary => true} do
    version = fetch(:backup_version, latest)
    run "tar -C #{backup_path} -czf #{backup_path}/#{version}.tar.gz #{version}"
    `mkdir -p backups`
    get "#{backup_path}/#{version}.tar.gz", "backups/#{version}.tar.gz"
    run "rm #{backup_path}/#{version}.tar.gz"
    `tar -C backups -zxf backups/#{version}.tar.gz`
    `rm backups/#{version}.tar.gz`
  end

  desc "Creates a new remote backup and clones it to the local database"
  task :mirror, :roles => :db, :only => {:primary => true} do
    create
    download
    `rake db:backup:restore`
  end

end

before "deploy", "backup:create"
after 'deploy:update_code', 'config:cp'
after "deploy:update_code", "sitemap:copy_old"
after "deploy", "sitemap:refresh"

# recompile assets after updating config
load 'deploy/assets'
