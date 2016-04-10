require 'nokogiri'
require 'colorize'

module CustomMysql
  def self.class_name
    name
  end

  def self.process(site: nil)
    unless Dir.exist?(site['dir'])
      $logger.warn(site['dir'] + ' does not exists')
      return
    end

    sqlfile = $config['local_backup_dir'] + '/' + site['db']['name'] + '.sql'

    command = "mysqldump --opt --user='%s' --password='%s' %s > %s"\
      % [site['db']['username']\
      , site['db']['password']\
      , site['db']['name']\
      , sqlfile]
    $logger.info(class_name + " DUMPING MYSQL DB -> #{command}".green)
    Open3.popen2e(command.to_s) do |_stdin, stdout_err, wait_thr|
      unless wait_thr.value.success?
        while line = stdout_err.gets
          $logger.error("#{class_name} #{line}".red)
        end
        $logger.error("#{class_name} Failed... #{command} #{wait_thr.value}".red)
        return -1
      end
      return sqlfile
    end
    -1
  end
end
