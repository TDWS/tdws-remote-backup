module ApacheVhost
    attr_accessor :processed_dirs
    @processed_dirs = []
    
    def self.process(dir)
      unless Dir.exist?(dir)
        $logger.warn(dir + ' does not exists')
        return
      end

      Dir.glob(dir + '/*').select do |vhost_file|
        next unless File.file? vhost_file
        c = 0
        File.readlines(vhost_file).each do |vhost_line|
          m = vhost_line.scan(/DocumentRoot.?"(.+)"/i)
          next if m.none?
          c += 1
          @processed_dirs.push([m.flatten.join, vhost_file])
        end
        $logger.warn(vhost_file + ' no matches for DocumentRoot') if c == 0
      end
      @processed_dirs
    end
end