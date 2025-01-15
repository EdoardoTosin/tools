require 'yaml'
require 'fileutils'
require 'digest'

module Jekyll
  class ScriptManagerGenerator < Generator
    safe true

    DEFAULT_SCRIPT_DIR = '_script'
    DEFAULT_SCRIPT_YML = '_data/script.yml'
    SCRIPT_CATALOG_MD = 'SCRIPT_CATALOG.md'
    SCRIPT_EXTENSIONS = {
      '.sh' => 'linux',
      '.bash' => 'linux',
      '.py' => 'python',
      '.pyw' => 'python',
      '.ps1' => 'windows'
    }
    ROOT_PERMISSION_SUBSTRING = "Note: The script must run with root permissions."

    @@last_run_time = Time.now

    def generate(site)
      script_dir = File.join(site.source, DEFAULT_SCRIPT_DIR)
      script_yml_path = File.join(site.source, DEFAULT_SCRIPT_YML)
      md_path = File.join(site.source, SCRIPT_CATALOG_MD)

      ensure_directory_exists(script_dir)

      # Check if files are missing or if the source has changed
      if files_missing?(script_yml_path, md_path) || source_changed?(script_dir)
        # Retrieve all script files
        scripts = find_scripts(script_dir)

        # Generate files
        generate_script_yaml(script_yml_path, scripts)
        generate_script_catalog_md(md_path, scripts, site)

        @@last_run_time = Time.now
        Jekyll.logger.info "ScriptManagerGenerator:", "Generated #{script_yml_path} and #{md_path} with #{scripts.size} scripts."
      else
        Jekyll.logger.info "ScriptManagerGenerator:", "No changes detected. Skipping generation."
      end
    end

    private

    # Check if either of the target files is missing
    def files_missing?(*files)
      files.any? { |file| !File.exist?(file) }
    end

    # Check if the source directory has changed since the last run
    def source_changed?(script_dir)
      Dir.glob(File.join(script_dir, '**/*')).any? do |file|
        File.mtime(file) > @@last_run_time
      end
    end

    # Generate _data/script.yml
    def generate_script_yaml(path, scripts)
      script_data = scripts.map do |file|
        {
          'name' => File.basename(file),
          'type' => SCRIPT_EXTENSIONS[File.extname(file)],
          'root' => script_requires_root?(file)
        }
      end

      write_yaml(path, script_data)
    end

    def write_yaml(path, data)
      File.open(path, 'w') do |file|
        file.puts "# Script Catalog"
        file.puts ""
        data.each do |script|
          file.puts "- name: \"#{script['name']}\""
          file.puts "  type: \"#{script['type']}\""
          file.puts "  root: \"#{script['root'] ? 'true' : 'false'}\""
        end
      end
    rescue IOError => e
      Jekyll.logger.error "ScriptManagerGenerator:", "Failed to write YAML file: #{e.message}"
    end

    # Generate SCRIPT_CATALOG.md
    def generate_script_catalog_md(path, scripts, site)
      python_scripts, linux_scripts, windows_scripts = categorize_scripts(scripts)

      # Main title with explanation of SHA-256 integrity checks
      content = "# Script Catalog\n\n"
      content += "_The SHA-256 hash values next to each script are provided for integrity verification._\n\n"

      content += generate_section("Python", python_scripts, site) unless python_scripts.empty?
      content += generate_section("Linux", linux_scripts, site, true) unless linux_scripts.empty?
      content += generate_section("Windows", windows_scripts, site) unless windows_scripts.empty?

      File.open(path, 'w') { |file| file.write(content) }
    rescue IOError => e
      Jekyll.logger.error "ScriptManagerGenerator:", "Failed to write Markdown file: #{e.message}"
    end

    # Categorize scripts by type
    def categorize_scripts(scripts)
      python_scripts = []
      linux_scripts = []
      windows_scripts = []

      scripts.each do |script|
        case File.extname(script)
        when '.py', '.pyw'
          python_scripts << script
        when '.bash', '.sh'
          linux_scripts << script
        when '.ps1'
          windows_scripts << script
        end
      end

      [python_scripts, linux_scripts, windows_scripts]
    end

    # Generate content for each script section
    def generate_section(title, scripts, site, check_sudo = false)
      content = "## #{title}\n\n"
      scripts.each do |script|
        script_name = File.basename(script)
        # Get the relative path of the script file from the _script directory
        relative_path = Pathname.new(script).relative_path_from(Pathname.new(site.source)).to_s
        # Compute SHA-256 hash of the script
        hash = compute_file_hash(script)

        content += "- [#{script_name}](#{relative_path}) `#{hash}`\n\n"

        if title == "Python"
          content += "  Linux:\n\n  ```\n"
          content += "  curl -sSL \"#{site_url_baseurl(site)}/#{File.basename(script)}\" | python\n"
          content += "  ```\n\n"
          content += "  Windows:\n\n  ```\n"
          content += "  irm \"#{site_url_baseurl(site)}/#{File.basename(script)}\" | python\n"
          content += "  ```\n\n"
        elsif title == "Linux"
          content += "  ```\n"
          use_sudo = check_sudo && script_requires_root?(script)
          content += "  curl -sSL \"#{site_url_baseurl(site)}/#{File.basename(script)}\""
          content += use_sudo ? " | sudo " : " | "
          content += (File.extname(script) == '.bash' ? "bash" : "sh") + "\n"
          content += "  ```\n\n"
        elsif title == "Windows"
          content += "  ```\n"
          content += "  irm \"#{site_url_baseurl(site)}/#{File.basename(script)}\" | iex\n"
          content += "  ```\n\n"
        end
      end
      content
    end

    def site_url_baseurl(site)
      site_url = site.config['domain_url'] || ''
      base_url = site.config['baseurl'] || ''
      "#{site_url}#{base_url}"
    end

    # Compute SHA-256 hash for a file
    def compute_file_hash(file)
      Digest::SHA256.file(file).hexdigest
    end

    # Utility methods
    def script_requires_root?(file)
      File.foreach(file).any? { |line| line.include?(ROOT_PERMISSION_SUBSTRING) }
    end

    def ensure_directory_exists(dir)
      FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
    end

    def find_scripts(script_dir)
      Dir.glob(File.join(script_dir, '**/*')).select { |file| SCRIPT_EXTENSIONS.key?(File.extname(file)) }
    end
  end
end
