require 'digest'
require 'yaml'
require 'base64'
require 'set'
require 'net/http'
require 'uri'

module Jekyll
  # Generates SRI hashes for JavaScript files and stores them in _data/sri.yml
  class JsSriGenerator < Generator
    safe true
    priority :lowest

    def generate(site)
      # Generator runs but actual processing happens in post_write hook
    end
  end

  # Process after all files are written to ensure compiled files are included
  Jekyll::Hooks.register :site, :post_write do |site|
    # Skip in development environment
    next if Jekyll.env == 'development'
    
    processor = SriProcessor.new(site)
    processor.process
  end

  # Main SRI processing logic
  class SriProcessor
    SRI_DATA_FILE = 'sri.yml'.freeze
    CACHE_FILE = '.sri_cache.yml'.freeze

    def initialize(site)
      @site = site
      @hashes = {}
      @unique_files = Set.new
      @cache = load_cache
    end

    def process
      process_js_files
      process_external_js_from_templates

      if @unique_files.any?
        save_sri_data
        save_cache
        log_success
      else
        Jekyll.logger.warn "SRI Generator:", "No JavaScript files found"
      end

      delete_cache
    end

    private

    def load_cache
      cache_file = File.join(@site.source, CACHE_FILE)
      File.exist?(cache_file) ? YAML.load_file(cache_file) : {}
    rescue => e
      Jekyll.logger.debug "SRI Generator:", "Could not load cache: #{e.message}"
      {}
    end

    def save_cache
      cache_file = File.join(@site.source, CACHE_FILE)
      File.write(cache_file, YAML.dump(@cache))
    rescue => e
      Jekyll.logger.debug "SRI Generator:", "Could not save cache: #{e.message}"
    end

    def delete_cache
      cache_file = File.join(@site.source, CACHE_FILE)
      File.delete(cache_file) if File.exist?(cache_file)
    rescue => e
      Jekyll.logger.debug "SRI Generator:", "Could not delete cache: #{e.message}"
    end

    def process_js_files
      js_files = Dir.glob(File.join(@site.dest, '**', '*.js'))
      js_files.each { |file| process_file(file) }
    end

    def process_external_js_from_templates
      # Scan HTML files for external JS references
      html_files = Dir.glob(File.join(@site.dest, '**', '*.html'))
      external_urls = Set.new

      html_files.each do |html_file|
        content = File.read(html_file)
        # Match script tags with src that look like external URLs
        content.scan(/<script[^>]+src=["']([^"']+)["'][^>]*>/) do |match|
          url = match[0]
          # Check if it's an external URL (http/https)
          external_urls.add(url) if url =~ /^https?:\/\//
        end
      end

      # Process external URLs
      external_urls.each { |url| process_external_url(url) }
    rescue => e
      Jekyll.logger.debug "SRI Generator:", "Error scanning templates: #{e.message}"
    end

    def process_external_url(url)
      # Check cache first
      if @cache[url] && @cache[url]['timestamp'] && 
         (Time.now - Time.parse(@cache[url]['timestamp'])) < 86400 # 24 hours
        use_cached_hash(url)
        return
      end

      # Fetch from URL
      Jekyll.logger.info "SRI Generator:", "Fetching external JS: #{url}"
      content = fetch_url(url)
      return unless content

      sri_hash = "sha512-#{Base64.strict_encode64(Digest::SHA512.digest(content))}"
      hash_data = { 'integrity' => sri_hash, 'crossorigin' => 'anonymous' }

      # Cache the result
      @cache[url] = hash_data.merge('timestamp' => Time.now.to_s)

      # Store in hashes
      @hashes[url] = hash_data
      @unique_files.add(url)

      Jekyll.logger.info "SRI Generator:", "Generated hash for external URL: #{url}"
    rescue => e
      Jekyll.logger.warn "SRI Generator:", "Could not fetch #{url}: #{e.message}"
    end

    def use_cached_hash(url)
      hash_data = {
        'integrity' => @cache[url]['integrity'],
        'crossorigin' => @cache[url]['crossorigin']
      }
      @hashes[url] = hash_data
      @unique_files.add(url)
      Jekyll.logger.debug "SRI Generator:", "Using cached hash for: #{url}"
    end

    def fetch_url(url)
      uri = URI.parse(url)
      response = Net::HTTP.get_response(uri)
      
      if response.code.to_i == 200
        response.body
      else
        Jekyll.logger.warn "SRI Generator:", "HTTP #{response.code} for #{url}"
        nil
      end
    rescue => e
      Jekyll.logger.warn "SRI Generator:", "Failed to fetch #{url}: #{e.message}"
      nil
    end

    def process_file(file_path)
      content = File.read(file_path)
      return if content.strip.empty?

      # Generate SRI hash
      sri_hash = "sha512-#{Base64.strict_encode64(Digest::SHA512.digest(content))}"
      
      # Get URL path
      url_path = file_path.sub(@site.dest, '')
      normalized = url_path.start_with?('/') ? url_path[1..-1] : url_path
      
      # Track unique file
      @unique_files.add(normalized)
      
      # Store hash with path variations for Liquid compatibility
      hash_data = { 'integrity' => sri_hash, 'crossorigin' => 'anonymous' }
      store_hash_variants(normalized, url_path, hash_data)
      
    rescue => e
      Jekyll.logger.error "SRI Generator:", "Error processing #{file_path}: #{e.message}"
    end

    def store_hash_variants(normalized, url_path, hash_data)
      # Store primary keys
      @hashes[normalized] = hash_data
      @hashes[url_path.start_with?('/') ? url_path : "/#{url_path}"] = hash_data
      
      # Store baseurl variants if configured
      return unless @site.baseurl && !@site.baseurl.empty?
      
      baseurl_path = url_path.sub(/^#{Regexp.escape(@site.baseurl)}/, '')
      return if baseurl_path == url_path
      
      @hashes[baseurl_path] = hash_data
      @hashes[baseurl_path.sub(/^\//, '')] = hash_data
    end

    def save_sri_data
      data_dir = File.join(@site.source, '_data')
      FileUtils.mkdir_p(data_dir)
      
      # Save only normalized paths to keep file clean
      clean_data = {}
      @unique_files.each { |path| clean_data[path] = @hashes[path] }
      
      File.write(
        File.join(data_dir, SRI_DATA_FILE),
        generate_yaml_content(clean_data)
      )
    end

    def generate_yaml_content(data)
      [
        "# Auto-generated SRI (Subresource Integrity) hashes",
        "# Generated: #{Time.now.strftime('%Y-%m-%d')}",
        "# Do not edit manually\n",
        YAML.dump(data)
      ].join("\n")
    end

    def log_success
      Jekyll.logger.info "SRI Generator:", 
        "Generated integrity hashes for #{@unique_files.size} JavaScript file(s)"
    end
  end

  # Liquid filters for SRI attributes
  module SriFilter
    def sri_attrs(input)
      # Return empty string in development mode
      return '' if development_mode?
      return '' if input.nil? || input.to_s.empty?
      
      data = find_sri_data(input.to_s.strip)
      data ? %{integrity="#{data['integrity']}" crossorigin="#{data['crossorigin']}"} : ''
    end

    def sri_integrity(input)
      # Return empty string in development mode
      return '' if development_mode?
      return '' if input.nil? || input.to_s.empty?
      
      data = find_sri_data(input.to_s.strip)
      data ? data['integrity'] : ''
    end

    def sri_crossorigin(input)
      # Return empty string in development mode
      return '' if development_mode?
      return '' if input.nil? || input.to_s.empty?
      
      data = find_sri_data(input.to_s.strip)
      data ? data['crossorigin'] : ''
    end

    private

    def development_mode?
      Jekyll.env == 'development'
    end

    def find_sri_data(path)
      sri_data = load_sri_data
      return nil unless sri_data

      # Try path variations
      [
        path,
        path.start_with?('/') ? path[1..-1] : path,
        path.start_with?('/') ? path : "/#{path}",
        remove_baseurl(path)
      ].compact.each do |variant|
        return sri_data[variant] if sri_data[variant]
      end
      
      nil
    end

    def load_sri_data
      site = @context.registers[:site]
      return site.data['sri'] if site.data['sri']

      sri_file = File.join(site.source, '_data', 'sri.yml')
      File.exist?(sri_file) ? YAML.load_file(sri_file) : nil
    rescue => e
      Jekyll.logger.error "SRI Filter:", "Error loading sri.yml: #{e.message}"
      nil
    end

    def remove_baseurl(path)
      site = @context.registers[:site]
      return nil unless site.baseurl && !site.baseurl.empty?
      
      stripped = path.sub(/^#{Regexp.escape(site.baseurl)}/, '')
      stripped == path ? nil : stripped
    end
  end
end

Liquid::Template.register_filter(Jekyll::SriFilter)
