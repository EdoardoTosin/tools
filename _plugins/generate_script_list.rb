module Jekyll
  class ScriptListGenerator < Generator
    safe true

    def generate(site)
      scripts = Dir['_script/*']
      return if scripts.empty?

      md_path = File.join(site.source, 'SCRIPT_CATALOG.md')

      python_scripts = []
      linux_scripts = []
      windows_scripts = []

      scripts.each do |script|
        case File.extname(script)
        when '.py', '.pyw'
          python_scripts << script
        when '.bash'
          linux_scripts << script
        when '.sh'
          linux_scripts << script
        when '.ps1'
          windows_scripts << script
        end
      end

      content = "# List of Script\n\n"

      unless python_scripts.empty?
        content += "## Python\n\n"
        python_scripts.each do |script|
          content += "- [#{File.basename(script)}](#{script})\n\n  ```\n"
          content += "  curl -sSL \"#{site_url_baseurl(site)}/#{File.basename(script)}\" | python3\n"
          content += "  ```\n\n"
        end
      end

      unless linux_scripts.empty?
        content += "## Linux\n\n"
        linux_scripts.each do |script|
          content += "- [#{File.basename(script)}](#{script})\n\n  ```\n"
          content += "  curl -sSL \"#{site_url_baseurl(site)}/#{File.basename(script)}\""
          if File.extname(script) == '.bash'
            content += " | bash\n"
          else
            content += " | sh\n"
          end
          content += "  ```\n\n"
        end
      end

      unless windows_scripts.empty?
        content += "## Windows\n\n"
        windows_scripts.each do |script|
          content += "- [#{File.basename(script)}](#{script})\n\n  ```\n"
          content += "  Invoke-RestMethod \"#{site_url_baseurl(site)}/#{File.basename(script)}\" | Invoke-Expression\n"
          content += "  ```\n\n"
        end
      end

      # Corrected file writing part
      File.open(md_path, 'w') { |file| file.write(content) }

      total_scripts = python_scripts.size + linux_scripts.size + windows_scripts.size
      Jekyll.logger.info "ScriptListGenerator:", "Generated #{md_path} with #{total_scripts} scripts."
    end

    def site_url_baseurl(site)
      site_url = site.config['domain_url'] || ''
      base_url = site.config['baseurl'] || ''
      "#{site_url}#{base_url}"
    end
  end
end
