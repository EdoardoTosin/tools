require 'yaml'
require 'fileutils'
require 'digest'

module Jekyll
  class ScriptManagerGenerator < Generator
    safe true

    DEFAULT_SCRIPT_DIR = '_script'
    DEFAULT_SCRIPT_YML = '_data/script.yml'
    SCRIPT_CATALOG_MD = 'SCRIPT_CATALOG.md'
    HASH_FILE_PATH = '.script_hash' # File to store the hash of the directory state
    SCRIPT_EXTENSIONS = {
      '.sh' => 'linux',
      '.bash' => 'linux',
      '.py' => 'python',
      '.pyw' => 'python',
      '.ps1' => 'windows'
    }
    ROOT_PERMISSION_SUBSTRING = "Note: The script must run with root permissions."

    def generate(site)
      script_dir = File.join(site.source, DEFAULT_SCRIPT_DIR)
      script_yml_path = File.join(site.source, DEFAULT_SCRIPT_YML)
      md_path = File.join(site.source, SCRIPT_CATALOG_MD)

      ensure_directory_exists(script_dir)
      scripts = find_scripts(script_dir)

      # Compute hash of the current state of scripts
      current_hash = compute_hash(scripts)
      previous_hash = read_previous_hash

      # Only generate files if there are changes in the _script directory
      if current_hash != previous_hash
        generate_script_yaml(script_yml_path, scripts)
        generate_script_catalog_md(md_path, scripts, site)
        save_current_hash(current_hash)

        Jekyll.logger.info "ScriptManagerGenerator:", "Generated #{script_yml_path} and #{md_path} with #{scripts.size} scripts."
      else
        Jekyll.logger.info "ScriptManagerGenerator:", "No changes detected in #{DEFAULT_SCRIPT_DIR}. Skipping generation."
      end
    end

    private

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
        file.puts "# List of scripts"
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

      content = "# List of Scripts\n\n"
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
        script_url = "#{site_url_baseurl(site)}/#{script_name}"
        
        content += "- [#{script_name}](#{script})\n\n  ```\n"
        if title == "Python"
          content += "  curl -sSL \"#{script_url}\" | python3\n"
        elsif title == "Linux"
          use_sudo = check_sudo && script_requires_root?(script)
          content += "  curl -sSL \"#{script_url}\""
          content += use_sudo ? " | sudo " : " | "
          content += (File.extname(script) == '.bash' ? "bash" : "sh") + "\n"
        elsif title == "Windows"
          content += "  Invoke-RestMethod \"#{script_url}\" | Invoke-Expression\n"
        end
        content += "  ```\n\n"
      end
      content
    end

    def site_url_baseurl(site)
      site_url = site.config['domain_url'] || ''
      base_url = site.config['baseurl'] || ''
      "#{site_url}#{base_url}"
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

    # Hashing methods
    def compute_hash(scripts)
      digest = Digest::SHA256.new
      scripts.each { |file| digest.update(File.read(file)) }
      digest.hexdigest
    end

    def read_previous_hash
      File.exist?(HASH_FILE_PATH) ? File.read(HASH_FILE_PATH).chomp : nil
    end

    def save_current_hash(current_hash)
      File.open(HASH_FILE_PATH, 'w') { |file| file.puts(current_hash) }
    rescue IOError => e
      Jekyll.logger.error "ScriptManagerGenerator:", "Failed to write hash file: #{e.message}"
    end
  end
end
