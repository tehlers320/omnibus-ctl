#
# Copyright:: Copyright (c) 2012 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "omnibus-ctl/version"
require 'json'
require 'fileutils'

module Omnibus
  class Ctl

    File::umask(022)

    SV_COMMAND_NAMES = %w[status up down once pause cont hup alarm interrupt quit
                      term kill start stop restart shutdown force-stop
                      force-reload force-restart force-shutdown check]

    attr_accessor :name, :display_name, :log_exclude, :base_path, :sv_path,
    :service_path, :etc_path, :data_path, :log_path, :command_map, :category_command_map,
    :fh_output, :kill_users, :verbose, :log_path_exclude

    def initialize(name, service_commands=true)
      @name = name
      @service_commands = service_commands
      @display_name = name
      @base_path = "/opt/#{name}"
      @sv_path = File.join(@base_path, "sv")
      @service_path = File.join(@base_path, "service")
      @log_path = "/var/log/#{name}"
      @data_path = "/var/opt/#{name}"
      @etc_path = "/etc/#{name}"
      @log_exclude = '(config|lock|@|gzip|tgz|gz)'
      @log_path_exclude = ['*/sasl/*']
      @fh_output = STDOUT
      @kill_users = []
      @verbose = false
      # backwards compat command map that does not have categories
      @command_map = { }

      # categoired commands that we want by default
      @category_command_map = {
        "general" => {
          "show-config" => {
            :desc => "Show the configuration that would be generated by reconfigure.",
            :arity => 1
          },
          "reconfigure" => {
            :desc => "Reconfigure the application.",
            :arity => 1
          },
          "cleanse" => {
            :desc => "Delete *all* #{display_name} data, and start from scratch.",
            :arity => 2
          },
          "uninstall" => {
            :arity => 1,
            :desc => "Kill all processes and uninstall the process supervisor (data will be preserved)."
          },
          "help" => {
            :arity => 1,
            :desc => "Print this help message."
          }
        }
      }
      service_command_map = {
        "service-management" => {
          "service-list" => {
            :arity => 1,
            :desc => "List all the services (enabled services appear with a *.)"
          },
          "status" => {
            :desc => "Show the status of all the services.",
            :arity => 2
          },
          "tail" => {
            :desc => "Watch the service logs of all enabled services.",
            :arity => 2
          },
          "start" => {
            :desc => "Start services if they are down, and restart them if they stop.",
            :arity => 2
          },
          "stop" => {
            :desc => "Stop the services, and do not restart them.",
            :arity => 2
          },
          "restart" => {
            :desc => "Stop the services if they are running, then start them again.",
            :arity => 2
          },
          "once" => {
            :desc => "Start the services if they are down. Do not restart them if they stop.",
            :arity => 2
          },
          "hup" => {
            :desc => "Send the services a HUP.",
            :arity => 2
          },
          "term" => {
            :desc => "Send the services a TERM.",
            :arity => 2
          },
          "int" => {
            :desc => "Send the services an INT.",
            :arity => 2
          },
          "kill" => {
            :desc => "Send the services a KILL.",
            :arity => 2
          },
          "graceful-kill" => {
            :desc => "Attempt a graceful stop, then SIGKILL the entire process group.",
            :arity => 2
          }
        }
      }
      @category_command_map.merge!(service_command_map) if service_commands?
    end

    SV_COMMAND_NAMES.each do |sv_cmd|
      method_name = sv_cmd.gsub(/-/, "_")
      Omnibus::Ctl.class_eval <<-EOH
      def #{method_name}(*args)
        run_sv_command(*args)
      end
      EOH
    end

    # merges category_command_map and command_map,
    # removing categories
    def get_all_commands_hash
      without_categories = {}
      category_command_map.each do |category, commands|
        without_categories.merge!(commands)
      end
      command_map.merge(without_categories)
    end

    def service_commands?
      @service_commands
    end

    def load_files(path)
      Dir["#{path}/*.rb"].each do |file|
        eval(IO.read(file))
      end
    end

    def add_command(name, description, arity=1, &block)
      @command_map[name] = { :desc => description, :arity => arity }
      metaclass = class << self; self; end
      # Ruby does not like dashes in method names
      method_name = name.gsub(/-/, "_")
      metaclass.send(:define_method, method_name.to_sym) { |*args| block.call(*args) }
    end

    def add_command_under_category(name, category, description, arity=1, &block)
      # add new category if it doesn't exist
      @category_command_map[category] = {} unless @category_command_map.has_key?(category)
      @category_command_map[category][name] = { :desc => description, :arity => arity }
      metaclass = class << self; self; end
      # Ruby does not like dashes in method names
      method_name = name.gsub(/-/, "_")
      metaclass.send(:define_method, method_name.to_sym) { |*args| block.call(*args) }
    end

    def exit!(error_code)
      exit error_code
    end

    def log(msg)
      fh_output.puts msg
    end

    def get_pgrp_from_pid(pid)
      ps=`which ps`.chomp
      `#{ps} -p #{pid} -o pgrp=`.chomp
    end

    def get_pids_from_pgrp(pgrp)
      pgrep=`which pgrep`.chomp
      `#{pgrep} -g #{pgrp}`.split(/\n/).join(" ")
    end

    def sigkill_pgrp(pgrp)
      pkill=`which pkill`.chomp
      run_command("#{pkill} -9 -g #{pgrp}")
    end

    def run_command(command)
      system(command)
      $?
    end

    def service_list(*args)
      get_all_services.each do |service_name|
        print "#{service_name}"
        print "*" if service_enabled?(service_name)
        print "\n"
      end
      exit! 0
    end

    def cleanup_procs_and_nuke(filestr)
      begin
        run_sv_command("stop")
      rescue SystemExit
      end

      FileUtils.rm_f("/etc/init/#{name}-runsvdir.conf") if File.exists?("/etc/init/#{name}-runsvdir.conf")
      run_command("egrep -v '#{base_path}/embedded/bin/runsvdir-start' /etc/inittab > /etc/inittab.new && mv /etc/inittab.new /etc/inittab") if File.exists?("/etc/inittab")
      run_command("kill -1 1")

      backup_dir = Time.now.strftime("/root/#{name}-cleanse-%FT%R")
      FileUtils.mkdir_p("/root") unless File.exists?("/root")
      FileUtils.rm_rf(backup_dir)
      FileUtils.cp_r(etc_path, backup_dir) if File.exists?(etc_path)
      run_command("rm -rf #{filestr}")

      begin
        graceful_kill
      rescue SystemExit
      end

      run_command("pkill -HUP -u #{kill_users.join(',')}") if kill_users.length > 0
      run_command("pkill -HUP -f 'runsvdir -P #{service_path}'")
      sleep 3
      run_command("pkill -TERM -u #{kill_users.join(',')}") if kill_users.length > 0
      run_command("pkill -TERM -f 'runsvdir -P #{service_path}'")
      sleep 3
      run_command("pkill -KILL -u #{kill_users.join(',')}") if kill_users.length > 0
      run_command("pkill -KILL -f 'runsvdir -P #{service_path}'")

      get_all_services.each do |die_daemon_die|
        run_command("pkill -KILL -f 'runsv #{die_daemon_die}'")
      end

      log "Your config files have been backed up to #{backup_dir}."
      exit! 0
    end

    def uninstall(*args)
      cleanup_procs_and_nuke("/tmp/opt")
    end

    def cleanse(*args)
      log "This will delete *all* configuration, log, and variable data associated with this application.\n\n*** You have 60 seconds to hit CTRL-C ***\n\n"
      unless args[1] == "yes"
        sleep 60
      end
      cleanup_procs_and_nuke("#{service_path}/* /tmp/opt #{data_path} #{etc_path} #{log_path}")
    end

    def get_all_services_files
      Dir[File.join(sv_path, '*')]
    end

    def get_all_services
      get_all_services_files.map { |f| File.basename(f) }.sort
    end

    def service_enabled?(service_name)
      File.symlink?("#{service_path}/#{service_name}")
    end

    def run_sv_command(sv_cmd, service=nil)
      exit_status = 0
      if service
        exit_status += run_sv_command_for_service(sv_cmd, service)
      else
        get_all_services.each do |service_name|
          exit_status += run_sv_command_for_service(sv_cmd, service_name) if global_service_command_permitted(sv_cmd, service_name)
        end
      end
      exit! exit_status
    end

    # run an sv command for a specific service name
    def run_sv_command_for_service(sv_cmd, service_name)
      if service_enabled?(service_name)
        status = run_command("#{base_path}/init/#{service_name} #{sv_cmd}")
        return status.exitstatus
      else
        log "#{service_name} disabled" if sv_cmd == "status" && verbose
        return 0
      end
    end

    # if we're running a global service command (like p-c-c status)
    # across all of the services, there are certain cases where we
    # want to prevent services files that exist in the service
    # directory from being activated. This method is the logic that
    # blocks those services
    def global_service_command_permitted(sv_cmd, service_name)
      # For services that have been removed, we only want to
      # them to respond to the stop command. They should not show
      # up in status, and they should not be started.
      if removed_services.include?(service_name)
        return sv_cmd == "stop"
      end

      # For keepalived, we only want it to respond to the status
      # command when running global service commands like p-c-c start
      # and p-c-c stop
      if service_name == "keepalived"
        return sv_cmd == "status"
      end

      # If c-s-c status is called, check to see if the service
      # is hidden supposed to be hidden from the status results
      # (mover for example should be hidden).
      if sv_cmd == "status"
        return !(hidden_services.include?(service_name))
      end

      # All other services respond normally to p-c-c * commands
      return true
    end

    # removed services are configured via the attributes file in
    # the main omnibus cookbook
    def removed_services
      # in the case that there is no running_config (the config file does
      # not exist), we know that this will be a new server, and we don't
      # have to worry about pre-upgrade services hanging around. We can safely
      # return an empty array when running_config is nil
      if (cfg = running_config)
        key = package_name.gsub(/-/, '_')
        cfg[key]["removed_services"] || []
      else
        []
      end
    end

    # hidden services are configured via the attributes file in
    # the main omnibus cookbook
    #
    # hidden services are services that we do not want to show up in
    # c-s-c status.
    def hidden_services
      # in the case that there is no running_config (the config file does
      # not exist), we don't want to return nil, just return an empty array.
      # worse result with doing that is services that we don't want to show up in
      # c-s-c status will show up.
      if (cfg = running_config)
        key = package_name.gsub(/-/, '_')
        cfg[key]["hidden_services"] || []
      else
        []
      end
    end

    # translate the name from the config to the package name.
    # this is a special case for the private-chef package because
    # it is configured to use the name and directory structure of
    # 'opscode', not 'private-chef'
    def package_name
      case @name
      when "opscode"
        "private-chef"
      else
        @name
      end
    end

    # returns nil when chef-server-running.json does not exist
    def running_config
      @running_config ||= begin
        if File.exists?("#{etc_path}/chef-server-running.json")
          JSON.parse(File.read("#{etc_path}/chef-server-running.json"))
        end
      end
    end

    def show_config(*args)
      status = run_command("#{base_path}/embedded/bin/chef-client -z -c #{base_path}/embedded/cookbooks/solo.rb -j #{base_path}/embedded/cookbooks/show-config.json -l fatal")
      if status.success?
        exit! 0
      else
        exit! 1
      end
    end

    def reconfigure(exit_on_success=true)
      status = run_command("#{base_path}/embedded/bin/chef-client -z -c #{base_path}/embedded/cookbooks/solo.rb -j #{base_path}/embedded/cookbooks/dna.json")
      if status.success?
        log "#{display_name} Reconfigured!"
        exit! 0 if exit_on_success
      else
        exit! 1
      end
    end

    def tail(*args)
      # find /var/log -type f -not -path '*/sasl/*' | grep -E -v '(lock|@|tgz|gzip)' | xargs tail --follow=name --retry
      command = "find #{log_path}"
      command << "/#{args[1]}" if args[1]
      command << ' -type f'
      command << log_path_exclude.map { |path| " -not -path #{path}" }.join(' ')
      command << " | grep -E -v '#{log_exclude}' | xargs tail --follow=name --retry"

      system(command)
    end

    def is_integer?(string)
      return true if Integer(string) rescue false
    end

    def graceful_kill(*args)
      service = args[1]
      exit_status = 0
      get_all_services.each do |service_name|
        next if !service.nil? && service_name != service
        if service_enabled?(service_name)
          pidfile="#{sv_path}/#{service_name}/supervise/pid"
          pid=File.read(pidfile).chomp if File.exists?(pidfile)
          if pid.nil? || !is_integer?(pid)
            log "could not find #{service_name} runit pidfile (service already stopped?), cannot attempt SIGKILL..."
            status = run_command("#{base_path}/init/#{service_name} stop")
            exit_status = status.exitstatus if exit_status == 0 && !status.success?
            next
          end
          pgrp=get_pgrp_from_pid(pid)
          if pgrp.nil? || !is_integer?(pgrp)
            log "could not find pgrp of pid #{pid} (not running?), cannot attempt SIGKILL..."
            status = run_command("#{base_path}/init/#{service_name} stop")
            exit_status = status.exitstatus if exit_status == 0 && !status.success?
            next
          end
          run_command("#{base_path}/init/#{service_name} stop")
          pids=get_pids_from_pgrp(pgrp)
          if !pids.empty?
            log "found stuck pids still running in process group: #{pids}, sending SIGKILL" unless pids.empty?
            sigkill_pgrp(pgrp)
          end
        else
          log "#{service_name} disabled, not stopping"
          exit_status = 1
        end
      end
      exit! exit_status
    end

    def help(*args)
      log "#{$0}: command (subcommand)\n"
      command_map.keys.sort.each do |command|
        log command
        log "  #{command_map[command][:desc]}"
      end
      category_command_map.each do |category, commands|
        # Remove "-" and replace with spaces in category and capalize for output
        category_string = category.gsub("-", " ").split.map(&:capitalize).join(' ')
        log "#{category_string} Commands:\n"

        # Print each command in this category
        commands.keys.sort.each do |command|
          log "  #{command}"
          log "    #{commands[command][:desc]}"
        end
      end
      exit! 1
    end

    # Set options. Silently ignore bad options.
    # This allows the test subcommand to pass on pedant options
    def parse_options!(args)
      args.each do |option|
        case option
        when "--verbose", "-v"
          @verbose = true
        end
      end
    end

    # If it begins with a '-', it is an option.
    def is_option?(arg)
      arg && arg[0] == '-'
    end

    # retrieves the commmand from either the command_map
    # or the category_command_map, if the command is not found
    # return nil
    def retrieve_command(command_to_run)
      if command_map.has_key?(command_to_run)
        command_map[command_to_run]
      else
        command = nil
        category_command_map.each do |category, commands|
          command = commands[command_to_run] if commands.has_key?(command_to_run)
        end
        # return the command, or nil if it wasn't found
        command
      end
    end

    def run(args)
      # Ensure Omnibus related binaries are in the PATH
      ENV["PATH"] = [File.join(base_path, "bin"),
                     File.join(base_path, "embedded","bin"),
                     ENV['PATH']].join(":")

      command_to_run = args[0]

      # This piece of code checks if the argument is an option. If it is,
      # then it sets service to nil and adds the argument into the options
      # argument. This is ugly. A better solution is having a proper parser.
      # But if we are going to implement a proper parser, we might as well
      # port this to Thor rather than reinventing Thor. For now, this preserves
      # the behavior to complain and exit with an error if one attempts to invoke
      # a pcc command that does not accept an argument. Like "help".
      options = args[2..-1] || []
      if is_option?(args[1])
        options.unshift(args[1])
        service = nil
      else
        service = args[1]
      end

      # returns either hash content of comamnd or nil
      command = retrieve_command(command_to_run)

      if command.nil?
        log "I don't know that command."
        if args.length == 2
          log "Did you mean: #{$0} #{service} #{command_to_run}?"
        end
        help
      end

      if args.length > 1 && command[:arity] != 2
        log "The command #{command_to_run} does not accept any arguments"
        exit! 2
      end

      parse_options! options

      method_to_call = command_to_run.gsub(/-/, '_')
      # Filter args to just command and service. If you are loading
      # custom commands and need access to the command line argument,
      # use ARGV directly.
      actual_args = [command_to_run, service].reject(&:nil?)
      self.send(method_to_call.to_sym, *actual_args)
    end

  end
end
