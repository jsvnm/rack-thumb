require 'rack'
require 'digest/sha1'
require 'tempfile'
require File.dirname(File.dirname(__FILE__)) + '/rack/mapel'

module Rack

#   The Rack::Thumb middleware intercepts requests for images that have urls of
#   the form <code>/path/to/image_{metadata}.ext</code> and returns rendered
#   thumbnails. Rendering options include +width+, +height+ and +gravity+. If
#   both +width+ and +height+ are supplied, images are resized and optionally
#   cropped to fit the aspect ratio.
#
#   Rack::Thumb is file-server agnostic to provide maximum deployment
#   flexibility. Simply set it up in front of any downstream application that
#   can serve the source images. Example:
#
#     # rackup.ru
#     require 'rack/thumb'
#
#     use Rack::Thumb
#     use Rack::Static, :urls => ["/media"]
#
#     run MyApp.new
#
#   See the example directory for more <tt>Rack</tt> configurations. Because
#   thumbnailing is an expensive operation, you should run Rack::Thumb
#   behind a cache, such as <tt>Rack::Cache</tt>.
#
#   Link to thumbnails from your templates as follows:
#
#     /media/foobar_50x50.jpg     # => Crop and resize to 50x50
#     /media/foobar_50x50-nw.jpg  # => Crop and resize with northwest gravity
#     /media/foobar_50x.jpg       # => Resize to a width of 50, preserving AR
#     /media/foobar_x50.jpg       # => Resize to a height of 50, preserving AR
#     /media/foobar_50xx50.jpg    # => Resize to a maximum height and width of 50, preserving AR
#
#   To prevent pesky end-users and bots from flooding your application with
#   render requests you can set up Rack::Thumb to check for a <tt>SHA-1</tt> signature
#   that is unique to every url. Using this option, only thumbnails requested
#   by your templates will be valid. Example:
#
#     use Rack::Thumb, {
#       :secret => "My secret",
#       :keylength => "16"        # => Only use 16 digits of the SHA-1 key
#     }
#
#   You can then use your +secret+ to generate secure links in your templates:
#
#     /media/foobar_50x100-sw-a267c193a7eff046.jpg  # => Successful
#     /media/foobar_120x250-a267c193a7eff046.jpg    # => Returns a bad request error
#

  class Thumb
    RE_TH_BASE = /_([0-9]+x|x[0-9]+|[0-9]+xx?[0-9]+)(-(?:nw|n|ne|w|c|e|sw|s|se))?(-(?:raw))?/
    RE_TH_EXT = /(\.(?:jpg|jpeg|png|gif))/i
    TH_GRAV = {
      '-nw' => :northwest,
      '-n' => :north,
      '-ne' => :northeast,
      '-w' => :west,
      '-c' => :center,
      '-e' => :east,
      '-sw' => :southwest,
      '-s' => :south,
      '-se' => :southeast
    }

    def initialize(app, options={})
      @app = app
      @keylen = options[:keylength]
      @secret = options[:secret]
      @write = options[:write]
      @routes = generate_routes(options[:urls] || ["/"], options[:prefix])
      @crop = options[:crop]
      @preserve_metadata = options[:preserve_metadata]
      @ttl = options[:ttl]
    end

    # Generates routes given a list of prefixes.
    def generate_routes(urls, prefix = nil)
      urls.map do |url|
        prefix = prefix ? escape_regex(prefix) : ''
        url = url == "/" ? '' : escape_regex(url)
        key = @keylen ? "-([0-9a-f]{#{@keylen}})" : ""
        /^#{prefix}(#{url}.+)#{RE_TH_BASE}#{key}#{RE_TH_EXT}$/
      end
    end

    def escape_regex(input)
      return input if input.is_a?(Regexp)
      Regexp.escape(input)
    end

    def call(env)
      dup._call(env)
    end

    def _call(env)
      response = catch(:halt) do
        throw :halt unless %w{GET HEAD}.include? env["REQUEST_METHOD"]
        @env = env
        @path = env["PATH_INFO"]
        @routes.each do |regex|
          if match = @path.match(regex)
            @source, dim, grav, opt = extract_meta(match)
            @options = extract_options(opt)
            @image = get_source_image
            @thumb = render_thumbnail(dim, grav) unless head?
            serve
          end
        end
        nil
      end
      response || @app.call(env)
    end

    # Extracts filename and options from the path.
    def extract_meta(match)
      result = if @keylen
        extract_signed_meta(match)
      else
        extract_unsigned_meta(match)
      end
      throw :halt unless result
      result
    end

    # Extracts filename and options from a signed path.
    def extract_signed_meta(match)
      base, dim, grav, opt, sig, ext = match.captures
      digest = Digest::SHA1.hexdigest("#{base}_#{dim}#{grav}#{opt}#{ext}#{@secret}")[0..@keylen-1]
      throw(:halt, bad_request) unless sig && (sig == digest)
      [base + ext, dim, grav]
    end

    # Extracts filename and options from an unsigned path.
    def extract_unsigned_meta(match)
      base, dim, grav, opt, ext = match.captures
      [base + ext, dim, grav, opt]
    end

    def extract_options(string)
      return unless string
      string.split("-").tap do |options|
        @raw = options.include?("raw")
      end
    end

    # Fetch the source image from the downstream app, returning the downstream
    # app's response if it is not a success.
    def get_source_image
      status, headers, body = @app.call(@env.merge(
        "PATH_INFO" => @source
      ))

      unless (status >= 200 && status < 300) &&
          (headers["Content-Type"].split("/").first == "image")
        throw :halt, [status, headers, body]
      end

      @source_headers = headers
      @source_body = body

      if !head?
        if body.respond_to?(:path)
          ::File.open(body.path, 'rb')
        elsif body.respond_to?(:each)
          data = ''
          body.each { |part| data << part.to_s }
          Tempfile.new(::File.basename(@path)).tap do |f|
            f.binmode
            f.write(data)
            f.close
          end
        end
      else
        nil
      end
    end

    # Renders a thumbnail from the source image.
    def render_thumbnail(dim, grav)
      gravity = grav ? TH_GRAV[grav] : :center
      width, height = parse_dimensions(dim)
      origin_width, origin_height = Mapel.info(@image.path)[:dimensions]
      width = [width, origin_width].min if width
      height = [height, origin_height].min if height
      transform_image(width, height, gravity)
    end

    # Performs the image transformation.
    #
    # Mapel.orient and Mapel.strip require a patched version of Mapel:
    #   https://github.com/vidibus/mapel
    #
    def transform_image(width, height, gravity)
      file.tap do |output|
        Mapel(@image.path).gravity(gravity).tap do |cmd|
          if width && height && @crop == true
            cmd.resize!(width, height)
          else
            cmd.resize(width, height, 0, 0, ">")
          end
          unless @raw
            cmd.try(:orient)
            cmd.try(:strip) unless @preserve_metadata == true
          end
          cmd.to(output.path).run
        end
      end
    end

    # Serves the thumbnail. If this is a HEAD request we strip the body as well
    # as the content length because the render was never run.
    def serve
      response = if head?
        @source_headers.delete("Content-Length")
        [200, @source_headers, []]
      else
        headers = @source_headers.merge("Content-Length" => ::File.size(@thumb.path).to_s)
        headers["Cache-Control"] = "public, max-age=#{@ttl}" if @ttl
        [200, headers, self]
      end
      throw :halt, response
    end

    # Parses the rendering options; returns false if rendering options are invalid
    def parse_dimensions(meta)
      if meta.match(/(\d*)x(x?)(\d*)/)
        dimensions = [$1,$3]
        @crop = $2 == "" if @crop == nil
      end

      dimensions.map! do |dim|
        if dim.empty?
          nil
        elsif dim.index('0') == 0
          throw :halt, bad_request
        else
          dim.to_i
        end
      end
      dimensions.any? ? dimensions : throw(:halt, bad_request)
    end

    # Returns a Tempfile or a file pointer.
    def file
      !!@write ? create_file : create_tempfile
    end

    # Creates a new tempfile
    def create_tempfile
      Tempfile.new(::File.basename(@path)).tap { |f| f.close }
    end

    # Creates a file at the requested location
    def create_file
      ::File.open(::File.join(@source_body.root, @path), "w+").tap { |f| f.close }
    end

    def bad_request
      body = "Bad thumbnail parameters in #{@path}\n"
      [400, {"Content-Type" => "text/plain",
         "Content-Length" => body.size.to_s},
       [body]]
    end

    def head?
      @env["REQUEST_METHOD"] == "HEAD"
    end

    def each
      ::File.open(@thumb.path, "rb") do |file|
        while part = file.read(8192)
          yield part
        end
      end
    end

    def to_path
      @thumb.path
    end
  end
end
