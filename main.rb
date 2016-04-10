require 'rubygems'
require 'bundler/setup'
Bundler.setup(:default)
require 'colorize'
require 'logger'
require 'json'
require 'English'
require 'pathname'
require 'open3'

$logger = Logger.new(STDOUT)
$logger.level = Logger::INFO

$config = JSON.parse(File.read('config.json'))
def rotation
  dir = $config['local_backup_dir'] + '/'
  configtime = $config['rotation']['hours']\
    + $config['rotation']['days'] * 24\
    + $config['rotation']['months'] * 30.4167

  Dir.glob(dir + '*') do |file|
    mtime = File.mtime(file)
    timenow = Time.now
    timenow = timenow.hour + timenow.day * 24 + timenow.month * 30.4167

    filetime = mtime.hour\
      + mtime.day * 24\
      + mtime.month * 30.4167

    if (timenow - filetime - configtime) > 0.0
      $logger.info("Deleting #{file} due rotation".blue)
      File.delete(file)
      # FIXME: fireup remote deletion
    end
  end
end

def backupDir(*dir)
  rotation
  dir = dir.map(&lambda do |d|
    return d if File.directory?(d)
    return File.basename(d) if File.file?(d)
  end)
  filename = $config['local_backup_dir'] + '/' + Time.new.strftime('%Y-%m-%d-%H_%M') + '.tar'
  command = "tar -C #{$config['local_backup_dir']} -cf #{filename} #{dir.join(' ')}"
  $logger.info("Starting to pack #{command}")
  Open3.popen2e(command.to_s) do |_stdin, stdout_err, wait_thr|
    unless wait_thr.value.success?
      while line = stdout_err.gets
        $logger.error("#{__method__} #{line}".red)
      end
      $logger.error("#{__method__}: Packing failed... #{command} #{wait_thr.value}".red)
      return -1
    end
  end
  $logger.info(command.green)
  filename
end

def processDB(vhost_file: nil, dir: nil, site: nil)
  # custom sites
  if site
    # if user supplied custom dumping command
    if site['db']['command']
      $logger.info("#{__method__}: CUSTOM db dumping: #{site['db']['command']}".green)
      Open3.popen2e((site['db']['command']).to_s) do |_stdin, stdout_err, wait_thr|
        unless wait_thr.value.success?
          while line = stdout_err.gets
            $logger.error("#{__method__} #{line}".red)
          end
          $logger.error("#{__method__}: Failed custom dumping, aborting... #{site['db']['command']} #{wait_thr.value}".red)
          return -1
        end
      end

      # check for missing dump files
      site['db']['command_files'].each do |file|
        missing = []
        missing.push(file) unless File.exist?(file)
        if missing.any?
          $logger.error("#{__method__}: Dumping were successfull however... file check failed #{missing.join(',')} -> #{site['db']['command_files'].join(',')}".red)
          return -1
        end
      end

      # everything is ok
      return site['db']['command_files']
    end

    # if not supplied custom command
    # db types...
    if site['db']['type']
      require_relative "database_readers/#{site['db']['type']}.rb"
      process_result = eval(site['db']['type']).process(site: site)
      return process_result if process_result != -1
    end
    return -1
  end # end custom site

  # try to auto guess
  Dir.glob('database_readers/*') do |file|
    mname = File.basename(file, '.rb')
    next unless (mname =~ /^Custom/).nil?
    require_relative file
    process_result = eval(mname).process(vhost_file: vhost_file, dir: dir)
    return process_result if process_result != -1
  end
  -1 # error
end

$config['custom_sites'].each do |site|
  unless Dir.exist?(site['dir'])
    $logger.info("Directory #{site['dir']} doesn't exists... skipping".blue)
    next
  end
  $logger.info("Custom processing #{site['dir']}")
  db = processDB(site: site)

  if db == -1
    $logger.error('Cannot backup DB ... Aborting'.red)
  else
    backup_file = backupDir(site['dir'], *db)
    dbfiles = db.is_a?(Enumerable) ? db.join(' ') : db

    $logger.info { "#{__method__} #{$config['onFinish']} #{backup_file}".green }
    Open3.popen2e("#{$config['onFinish']} #{backup_file}") do |_stdin, stdout_err, wait_thr|
      unless wait_thr.value.success?
        while line = stdout_err.gets
          $logger.error("#{__method__} #{line}".red)
        end
        $logger.error("#{__method__} Failed onFinish... #{$config['onFinish']} #{wait_thr.value}".red)
        return -1
      end
    end if $config['onFinish']

    $logger.info("Deleting db temp files... #{dbfiles}".blue)
    File.delete(*db)
  end
end if $config['custom_sites'].is_a? Array

require_relative 'vhost_readers/apache'
$config['vhosts_dirs'].each do |e|
  list = ApacheVhost.process(e)
  next unless list.any?
  list.each do |dir, vhost_file|
    $logger.info("Apache processing #{vhost_file} (DocumentRoot) -> #{dir}")
    unless Dir.exist?(dir)
      $logger.info("Directory #{dir} doesn't exists... skipping".blue)
      next
    end
    db = processDB(vhost_file: vhost_file, dir: dir)
    if db == -1
      $logger.error('Cannot backup DB ... Aborting'.red)
    else
      backup_file = backupDir(dir, *db)
      $logger.info("Deleting db temp files... #{db}".blue)
      File.delete(*db)
      $logger.info { "#{__method__} #{$config['onFinish']} #{backup_file}".green }
      Open3.popen2e("#{$config['onFinish']} #{backup_file}") do |_stdin, stdout_err, wait_thr|
        unless wait_thr.value.success?
          while line = stdout_err.gets
            $logger.error("#{__method__} #{line}".red)
          end
          $logger.error("#{__method__} Failed onFinish... #{$config['onFinish']} #{wait_thr.value}".red)
          return -1
        end
      end if $config['onFinish']
    end
  end
end if $config['vhosts_dirs'].is_a? Array
