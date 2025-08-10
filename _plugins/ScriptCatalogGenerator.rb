require 'yaml'
require 'fileutils'
require 'digest'
require 'pathname'

module Jekyll
  class ScriptManagerGenerator < Generator
    safe true

    DEFAULT_SCRIPT_DIR   = 'script'
    DEFAULT_SCRIPT_YML   = '_data/script.yml'
    SCRIPT_CATALOG_MD    = 'SCRIPT_CATALOG.md'
    GITHUB_RAW_BASE_URL  = 'https://raw.githubusercontent.com/EdoardoTosin/tools/refs/heads/main/script'
    SCRIPT_EXTENSIONS    = {
      '.sh'   => 'linux',
      '.bash' => 'linux',
      '.py'   => 'python',
      '.pyw'  => 'python',
      '.ps1'  => 'windows'
    }.freeze
    ROOT_PERMISSION_SUBSTRING = "Note: The script must run with root permissions."

    # class-level last run timestamp (initialized when the class is loaded)
    @last_run_time = Time.now
    class << self
      attr_accessor :last_run_time
    end

    def generate(site)
      script_dir      = File.join(site.source, DEFAULT_SCRIPT_DIR)
      script_yml_path = File.join(site.source, DEFAULT_SCRIPT_YML)
      md_path         = File.join(site.source, SCRIPT_CATALOG_MD)

      ensure_directory_exists(script_dir)

      if files_missing?(script_yml_path, md_path) || source_changed?(script_dir)
        scripts = find_scripts(script_dir)
        metadata = scripts.sort.map { |f| build_metadata(f, site) }

        generate_script_yaml(script_yml_path, metadata)
        generate_script_catalog_md(md_path, metadata, site)

        self.class.last_run_time = Time.now
        Jekyll.logger.info "ScriptManagerGenerator:", "Generated #{script_yml_path} and #{md_path} with #{metadata.size} scripts."
      else
        Jekyll.logger.info "ScriptManagerGenerator:", "No changes detected. Skipping generation."
      end
    rescue => e
      Jekyll.logger.error "ScriptManagerGenerator:", "Failed to generate script catalog: #{e.class}: #{e.message}"
      Jekyll.logger.debug e.backtrace.join("\n")
    end

    private

    # --- file checks --------------------------------------------------------
    def files_missing?(*files)
      files.any? { |file| !File.exist?(file) }
    end

    # only consider script files when checking for changes
    def source_changed?(script_dir)
      return true unless Dir.exist?(script_dir)

      script_files = Dir.glob(File.join(script_dir, '**', '*')).select do |p|
        File.file?(p) && SCRIPT_EXTENSIONS.key?(File.extname(p).downcase)
      end

      script_files.any? { |file| File.mtime(file) > self.class.last_run_time }
    end

    # --- discovery & metadata ----------------------------------------------
    def find_scripts(script_dir)
      return [] unless Dir.exist?(script_dir)

      Dir.glob(File.join(script_dir, '**', '*')).select do |file|
        File.file?(file) && SCRIPT_EXTENSIONS.key?(File.extname(file).downcase)
      end
    end

    # read the file once and compute metadata (hash, root flag, ext, relative path)
    def build_metadata(file, site)
      content = File.binread(file) rescue ''
      ext     = File.extname(file).downcase
      {
        name:         File.basename(file),
        path:         file,
        relative_path: Pathname.new(file).relative_path_from(Pathname.new(site.source)).to_s,
        ext:          ext,
        type:         SCRIPT_EXTENSIONS[ext],
        root:         content.include?(ROOT_PERMISSION_SUBSTRING),
        hash:         Digest::SHA256.hexdigest(content)
      }
    end

    # --- YAML output (keeps original formatting) ----------------------------
    def generate_script_yaml(path, metadata)
      File.open(path, 'w') do |f|
        f.puts "# Script Catalog"
        f.puts ""
        metadata.each do |m|
          f.puts "- name: \"#{m[:name]}\""
          f.puts "  type: \"#{m[:type]}\""
          f.puts "  root: \"#{m[:root] ? 'true' : 'false'}\""
        end
      end
    rescue IOError => e
      Jekyll.logger.error "ScriptManagerGenerator:", "Failed to write YAML file: #{e.message}"
    end

    # --- Markdown output ---------------------------------------------------
    def generate_script_catalog_md(path, metadata, site)
      by_type = metadata.group_by { |m| m[:type] }

      python_scripts  = (by_type['python'] || []).sort_by { |m| m[:name].downcase }
      linux_scripts   = (by_type['linux']  || []).sort_by { |m| m[:name].downcase }
      windows_scripts = (by_type['windows']|| []).sort_by { |m| m[:name].downcase }

      lines = []
      lines << "# Script Catalog"
      lines << ""
      lines << "_The SHA-256 hash values next to each script are provided for integrity verification._"
      lines << ""

      lines.concat section_lines("Python", python_scripts, site) unless python_scripts.empty?
      lines.concat section_lines("Linux",  linux_scripts,  site, check_sudo: true) unless linux_scripts.empty?
      lines.concat section_lines("Windows", windows_scripts, site) unless windows_scripts.empty?

      File.write(path, lines.join("\n") + "\n")
    rescue IOError => e
      Jekyll.logger.error "ScriptManagerGenerator:", "Failed to write Markdown file: #{e.message}"
    end

    def section_lines(title, scripts, site, check_sudo: false)
      lines = []
      lines << "## #{title}"
      lines << ""
      scripts.each do |m|
        github_raw_url = "#{GITHUB_RAW_BASE_URL}/#{m[:name]}"
        lines << "- [#{m[:name]}](#{m[:relative_path]}) `#{m[:hash]}`"
        lines << ""

        case title
        when "Python"
          lines << "  Linux:"
          lines << ""
          lines << "  ```"
          lines << "  curl -sSL \"#{github_raw_url}\" | python"
          lines << "  ```"
          lines << ""
          lines << "  Windows:"
          lines << ""
          lines << "  ```"
          lines << "  irm \"#{github_raw_url}\" | python"
          lines << "  ```"
          lines << ""
        when "Linux"
          lines << "  ```"
          use_sudo = check_sudo && m[:root]
          cmd = "  curl -sSL \"#{github_raw_url}\""
          cmd += use_sudo ? " | sudo " : " | "
          cmd += (m[:ext] == '.bash' ? 'bash' : 'sh')
          lines << cmd
          lines << "  ```"
          lines << ""
        when "Windows"
          lines << "  ```"
          lines << "  irm \"#{github_raw_url}\" | iex"
          lines << "  ```"
          lines << ""
        end
      end
      lines
    end

    # --- utilities --------------------------------------------------------
    def ensure_directory_exists(dir)
      FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
    end
  end
end
