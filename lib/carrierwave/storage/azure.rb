require 'azure'
require 'azure/blob/auth/shared_access_signature'

module CarrierWave
  module Storage
    class Azure < Abstract
      def store!(file)
        azure_file = CarrierWave::Storage::Azure::File.new(uploader, connection, uploader.store_path)
        azure_file.store!(file)
        azure_file
      end

      def retrieve!(identifer)
        CarrierWave::Storage::Azure::File.new(uploader, connection, uploader.store_path(identifer))
      end

      def connection
        @connection ||= begin
          %i(storage_account_name storage_access_key storage_blob_host).each do |key|
            ::Azure.config.send("#{key}=", uploader.send("azure_#{key}"))
          end
          ::Azure::Blob::BlobService.new
        end
      end

      class File
        attr_reader :path
        BLOCK_SIZE = 2**20

        def initialize(uploader, connection, path)
          @uploader = uploader
          @connection = connection
          @path = path
          @blocks = []
        end

        def store!(file)
          @content_type = file.content_type
          @content = file.read
          if is_large_file?(file)
            store_large_file(file)
          else
            @connection.create_block_blob(@uploader.azure_container, @path, @content, content_type: @content_type)
          end
          true
        end

        def is_large_file?(file)
          file.size.to_f / BLOCK_SIZE >= 64
        end

        def store_large_file(file)
          while (block = file.read(BLOCK_SIZE))
            block_id = random_block_id
            @blocks << [block_id]
            @connection.create_blob_block(@uploader.azure_container, @path, block_id, block, content_type: @content_type)
          end
          @connection.commit_blob_blocks(@uploader.azure_container, @path, @blocks, content_type: @content_type)
        end

        def random_block_id
          (0...8).map { ("a".."z").to_a[rand(26)] }.join
        end

        def url(options = {})
          _path = ::File.join(@uploader.azure_container, @path)
          _url = if private_container?
                   signed_url(_path, options.slice(:expiry))
                 else
                   public_url(_path, options)
                 end
          _url
        end

        def read
          content
        end

        def content_type
          @content_type = blob.properties[:content_type] if @content_type.nil? && !blob.nil?
          @content_type
        end

        def content_type=(new_content_type)
          @content_type = new_content_type
        end

        def exists?
          !blob.nil?
        end

        def size
          blob.properties[:content_length] unless blob.nil?
        end

        def filename
          URI.decode(url).gsub(/.*\/(.*?$)/, '\1')
        end

        def extension
          @path.split('.').last
        end

        def delete
          begin
            @connection.delete_blob(@uploader.azure_container, @path)
            true
          rescue ::Azure::Core::Http::HTTPError
            false
          end
        end

        private

        def blob
          load_content if @blob.nil?
          @blob
        end

        def content
          load_content if @content.nil?
          @content
        end

        def load_content
          @blob, @content = begin
            @connection.get_blob(@uploader.azure_container, @path)
          rescue ::Azure::Core::Http::HTTPError
          end
        end

        def get_container_acl(container_name, options = {})
          begin
            acl_data = @connection.get_container_acl(container_name, options)
            acl = if acl_data.is_a?(Array)
                    acl_data.size > 0 ? acl_data[0] : nil
                  else
                    acl_data
                  end
            acl
          rescue ::Azure::Core::Http::HTTPError => exception
            puts "#{self.class.name}.get_container_acl raised HTTPError exception, with reason:\n #{exception.message}"
            nil
          end
        end

        def sign(path, options = {})
          uri = if @uploader.asset_host
                  URI("#{@uploader.asset_host}/#{path}")
                else
                  @connection.generate_uri(path)
                end
          account = @uploader.send(:azure_storage_account_name)
          secret_key = @uploader.send(:azure_storage_access_key)
          ::Azure::Blob::Auth::SharedAccessSignature.new(account, secret_key)
                                                    .signed_uri(uri, options)
        end

        def private_container?
          acl = get_container_acl( @uploader.send(:azure_container), {} )
          acl && acl.public_access_level.nil?
        end

        def signed_url(path, options = {})
          expiry = options[:expiry] ? (Time.now.to_i + options[:expiry].to_i) : nil
          _options = { permissions: 'r', resource: 'b' }
          _options[:expiry] = Time.at(expiry).utc.iso8601 if expiry
          sign( path, options.merge!(_options) ).to_s
        end

        def public_url(path, options = {})
          if @uploader.asset_host
            "#{@uploader.asset_host}/#{path}"
          else
            @connection.generate_uri(path).to_s
          end
        end
      end
    end
  end
end
