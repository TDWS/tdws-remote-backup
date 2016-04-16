module ApacheVhost
  attr_accessor :processed_vhosts
  @processed_vhosts = []

  def self.process(dir)
    unless Dir.exist?(dir)
      $logger.warn(dir + ' does not exists')
      @processed_vhosts
    end

    Dir.glob(dir + '/*').select do |vhost_file|
      next unless File.file?(vhost_file) && File.readable?(vhost_file)
      content = File.read(vhost_file)
      content.scan(/(<VirtualHost.*?>.*?<\/VirtualHost>)/im) do |vsection|
        vsection = vsection[0]
        documentRoot = vsection.match(/DocumentRoot "(.*)?"/i)
        serverName = vsection.match(/ServerName (.*)?/i)
        vHead = vsection.match(/<VirtualHost.*?>/i)
        unless documentRoot
          $logger.warn("#{vhost_file} #{vHead} missing DocumentRoot can't get path... skipping")
          next
        end
        unless serverName
          $logger.warn("#{vhost_file} #{vHead} missing ServerName can't get name... skipping")
          next
        end
        @processed_vhosts.push({'name' => serverName[1], 'dir' => documentRoot[1]})
      end
    end
    @processed_vhosts
  end
end
