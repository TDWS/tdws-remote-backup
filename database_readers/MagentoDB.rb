require 'nokogiri'
require 'colorize'

module MagentoDB
  def self.class_name
    name
  end
  
  def self.process(vhost_file: nil, dir: nil)
    unless Dir.exist?(dir)
      $logger.warn(dir + ' does not exists')
      return
    end

    return unless File.readlines(dir + '/index.php').grep(/MAGENTO_ROOT/i).any?

    $logger.info(self.class_name + " #{dir}/index.php".green)

    unless File.exist?(dir + '/app/etc/local.xml')
      $logger.error(self.class_name + "#{dir}/app/etc/local.xml cannot be found THIS SHOULD NOT HAPPEN\nvhost: #{vhost_file}".red)
      return
    end

    doc = Nokogiri::XML(File.open(dir + '/app/etc/local.xml'))
    dsetup = doc.at_css('//default_setup')

    unless ['pdo_mysql'].any? { |e| e == dsetup.at_css('type').content }
      $logger.error(self.class_name + "#{dir}/app/etc/local.xml cannot determine DATABASE TYPE THIS SHOULD NOT HAPPEN\nvhost: #{vhost_file}".red)
      return
    end
    
    if dsetup.at_css('type').content == 'pdo_mysql'
      
      sqlfile = $config['local_backup_dir'] + '/' + File.basename(vhost_file) + '.sql'
      
      command = "mysqldump --opt --user='%s' --password='%s' %s > %s"\
        % [dsetup.at_css('username').content\
        , dsetup.at_css('password').content\
        , dsetup.at_css('dbname').content\
        , sqlfile]
      $logger.info(self.class_name + " DUMPING MYSQL DB -> #{command}".green)
      Open3.popen2e("#{command}") do |stdin, stdout_err, wait_thr|
        
        unless wait_thr.value.success?
          while line = stdout_err.gets
            $logger.error("#{self.class_name} #{line}".red)
          end
          $logger.error("#{self.class_name} Failed... #{command} #{wait_thr.value}".red)
          return -1
        end
        return sqlfile

      end
    end
    -1
  end
end
