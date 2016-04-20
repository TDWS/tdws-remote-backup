###############################################################
#     Backup script to dump databases and specific folder     #
#  v.0.1.0  by Kerekes Edwin, TD Web Services, Ti Dimensie AG #
#        For more Information: http://tdwebservices.com/      #
###############################################################
require 'rubygems'
require 'bundler/setup'
Bundler.setup(:default)
require 'colorize'
require 'logger'
require 'json'
require 'English'
require 'pathname'
require 'open3'
require 'net/smtp'
require 'socket'

$mailstream = StringIO.new
$logger = Logger.new($mailstream)
$logger.level = Logger::INFO

$config = JSON.parse(File.read('config.json'))
def open3(method_name: nil, command: nil, onErrorLine: nil, onError: nil, onSuccess: nil, ignoreExitCodes: [0])
    Open3.popen2e(command.to_s) do |_stdin, stdout_err, wait_thr|
        unless ignoreExitCodes.include?(wait_thr.value.to_i)
            while line = stdout_err.gets
                if onErrorLine.respond_to? :call
                    onErrorLine.call(line)
                    next
                end
                $logger.error("#{method_name} #{line}".red)
            end
            return onError.call(line) if onError.respond_to? :call
            $logger.error("#{method_name}: Command failed... #{command} #{wait_thr.value}".red)
            return -1
        end
        return onSuccess.call if onSuccess.respond_to? :call
    end
end

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

def backupDir(site_name, *dir)
    rotation
    dir = dir.map(&lambda do |d|
        return d if File.directory?(d)
        return File.basename(d) if File.file?(d)
    end)
    filename = $config['local_backup_dir'] + '/' + site_name + '-' + Time.new.strftime('%Y-%m-%d-%H_%M') + '.tar'
    if $config['onPacking']
        # "onPacking": "tar -C $backupdir -cf $filename $files",
        onPacking = $config['onPacking'].gsub('$backupdir', $config['local_backup_dir'])
        onPacking = onPacking.gsub('$filename', filename)
        onPacking = onPacking.gsub('$files', dir.join(' '))
        $logger.info { "#{__method__} #{onPacking}...".green }
        return -1 if open3(method_name: __method__, command: onPacking, ignoreExitCodes: $config['onPackingIgnoreExitCode']) == -1
    else
        $logger.error('Missing packing command... skipping')
        return -1
    end
    filename
end

def processDB(site_name: nil, dir: nil, custom_site: nil)
    if custom_site
        # if user supplied custom dumping command
        if custom_site['db']['command']
            $logger.info("#{__method__}: CUSTOM db dumping: #{custom_site['db']['command']}".green)
            return if open3(method_name: __method__, command: custom_site['db']['command'].to_s) == -1

            # check for missing dump files
            custom_site['db']['command_files'].each do |file|
                missing = []
                missing.push(file) unless File.exist?(file)
                if missing.any?
                    $logger.error("#{__method__}: Dumping were successfull however... file check failed #{missing.join(',')} -> #{custom_site['db']['command_files'].join(',')}".red)
                    return -1
                end
            end

            # everything is ok
            return custom_site['db']['command_files']
        end

        # if not supplied custom command
        # db types...
        if custom_site['db']['type']
            require_relative "database_readers/#{custom_site['db']['type']}.rb"
            process_result = eval(custom_site['db']['type']).process(custom_site: custom_site)
            return process_result if process_result != -1
        end
        return -1
    end # end custom custom_site

    # try to auto guess which database fits in
    # module names must start with `Custom` ...
    # return on first hit
    Dir.glob('database_readers/*') do |file|
        mname = File.basename(file, '.rb')
        next unless (mname =~ /^Custom/).nil?
        require_relative file
        process_result = eval(mname).process(site_name: site_name, dir: dir)
        return process_result if process_result != -1
    end
    -1 # error
end

# --custom sites--
$config['custom_sites'].each do |site|
    unless Dir.exist?(site['dir'])
        $logger.info("Directory #{site['dir']} doesn't exists... skipping".blue)
        next
    end
    $logger.info("Custom processing #{site['dir']}")
    db = processDB(custom_site: site)

    if db == -1
        $logger.error('Cannot backup DB ... Aborting'.red)
    else
        backup_file = backupDir(site['name'], site['dir'], *db)

        # just to make logging happy
        dbfiles = db.is_a?(Enumerable) ? db.join(' ') : db
        $logger.info("Deleting db temp files... #{dbfiles}".blue)

        File.delete(*db)

        if site['onFinish']
            onFinish = site['onFinish'].gsub(/$files/, backup_file)
            $logger.info { "#{__method__} #{onFinish}".green }
            return -1 if open3(method_name: __method__, command: onFinish) == -1
        end

    end
end if $config['custom_sites'].is_a? Array

# --apache sites--
require_relative 'vhost_readers/apache'
$config['vhosts_dirs'].each do |e|
    list = ApacheVhost.process(e)
    next unless list.any?
    list.each do |site|
        dir = site['dir']
        site_name = site['name']
        $logger.info("Apache processing #{site_name} (DocumentRoot) -> #{dir}")
        unless Dir.exist?(dir)
            $logger.info("Directory #{dir} doesn't exists... skipping".blue)
            next
        end
        db = processDB(site_name: site_name, dir: dir)
        if db == -1
            $logger.error('Cannot backup DB ... Aborting'.red)
        else
            backup_file = backupDir(site_name, dir, *db)
            $logger.info("Deleting db temp files... #{db}".blue)
            File.delete(*db)
            next if backup_file == -1
            if $config['onFinish']
                onFinish = $config['onFinish'].gsub('$files', backup_file)
                $logger.info { "#{__method__} #{onFinish}...".blue }
                next if open3(method_name: __method__, command: onFinish) == -1
            end
        end
    end
end if $config['vhosts_dirs'].is_a? Array

def sendMail(smtp)
    subject = $config['ReportMailServer']['subject'].gsub('$hostname', Socket.gethostname)
    subject = subject.gsub('$date', Time.new.strftime('%Y-%m-%d-%H_%M'))

    msgstr = <<-END_OF_MESSAGE
From: Backuper <#{$config['ReportMailServer']['host']}>
To: BackuperAdmin <#{$config['ReportMailServer']['to']}>
Subject: #{subject}

    #{$mailstream.string}
    END_OF_MESSAGE

    smtp.send_message(msgstr, $config['ReportMailServer']['from'], $config['ReportMailServer']['to'])
end

if $config['ReportMailServer']['username']
    Net::SMTP.start($config['ReportMailServer']['host'],
                    $config['ReportMailServer']['port'],
                    $config['ReportMailServer']['host'],
                    $config['ReportMailServer']['username'],
                    $config['ReportMailServer']['password'], :login) { |smtp| sendMail(smtp) }
else
    Net::SMTP.start($config['ReportMailServer']['host'], $config['ReportMailServer']['port']) { |smtp| sendMail(smtp) }
end
