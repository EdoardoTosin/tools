require 'yaml'
require 'fileutils'

module Jekyll
  class ScriptsGenerator < Generator
    safe true

    DEFAULT_SCRIPT_DIR = '_script'
    DEFAULT_SCRIPT_YML = '_data/script.yml'
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

      ensure_directory_exists(script_dir)
      scripts = find_scripts(script_dir)
      script_data = generate_script_data(scripts)
      write_yaml(script_yml_path, script_data)

      Jekyll.logger.info "ScriptsGenerator:", "Generated #{script_yml_path} with #{scripts.size} scripts."
    end

    private

    def ensure_directory_exists(dir)
      FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
    end

    def find_scripts(script_dir)
      Dir.glob(File.join(script_dir, '**/*')).select { |file| SCRIPT_EXTENSIONS.key?(File.extname(file)) }
    end

    def generate_script_data(scripts)
      scripts.map do |file|
        {
          'name' => File.basename(file),
          'type' => SCRIPT_EXTENSIONS[File.extname(file)],
          'root' => script_requires_root?(file)
        }
      end
    end

    def script_requires_root?(file)
      return false unless File.file?(file)

      File.foreach(file).any? { |line| line.include?(ROOT_PERMISSION_SUBSTRING) }
    end

    def write_yaml(path, data)
      File.open(path, 'w') do |file|
        file.puts "# List of script"
        file.puts ""
        data.each do |script|
          file.puts "- name: \"#{script['name']}\""
          file.puts "  type: \"#{script['type']}\""
          file.puts "  root: \"#{script['root'] ? 'true' : 'false'}\""
        end
      end
    rescue IOError => e
      Jekyll.logger.error "ScriptsGenerator:", "Failed to write YAML file: #{e.message}"
    end
  end
end
