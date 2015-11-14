require "non-stupid-digest-assets"
require "ember-cli/html_page"
require "ember-cli/shell"

module EmberCli
  class App
    class BuildError < StandardError; end

    attr_reader :name, :options, :paths

    delegate :root, to: :paths

    def initialize(name, **options)
      @name, @options = name.to_s, options
      @paths = PathSet.new(
        app: self,
        configuration: EmberCli.configuration,
        environment: Rails.env,
        rails_root: Rails.root,
        ember_cli_root: EmberCli.root,
      )
      @shell = Shell.new(
        paths: @paths,
        env: env_hash,
        options: options,
      )
    end

    def compile
      @compiled ||= begin
        prepare
        @shell.compile
        check_for_build_error!
        copy_index_html_file
        true
      end
    end

    def install_dependencies
      @shell.install
    end

    def run
      prepare
      @shell.run
      copy_index_html_file
    end

    def running?
      @shell.running?
    end

    def run_tests
      prepare

      @shell.test
    end

    def index_html(sprockets:, head:, body:)
      html_page = HtmlPage.new(
        content: index_file.read,
        head: head,
        body: body,
      )

      html_page.render
    end

    def exposed_js_assets
      [vendor_assets, application_assets]
    end
    alias exposed_css_assets exposed_js_assets

    def vendor_assets
      "#{name}/assets/vendor"
    end

    def application_assets
      "#{name}/assets/#{ember_app_name}"
    end

    def wait
      wait_for_build_complete_or_error
    end

    private

    def check_for_build_error!
      raise_build_error! if build_error?
    end

    def reset_build_error!
      if build_error?
        paths.build_error_file.delete
      end
    end

    def build_error?
      paths.build_error_file.exist? && paths.build_error_file.size?
    end

    def raise_build_error!
      backtrace = paths.build_error_file.readlines.reject(&:blank?)
      message = "#{name.inspect} has failed to build: #{backtrace.first}"

      error = BuildError.new(message)
      error.set_backtrace(backtrace)

      fail error
    end

    def prepare
      @prepared ||= begin
        reset_build_error!
        symlink_to_assets_root
        add_assets_to_precompile_list
        true
      end
    end

    def copy_index_html_file
      if EmberCli.env.production?
        FileUtils.cp(paths.app_assets.join("index.html"), index_file)
      end
    end

    def index_file
      if EmberCli.env.production?
        paths.applications.join("#{name}.html")
      else
        paths.dist.join("index.html")
      end
    end

    def symlink_to_assets_root
      paths.app_assets.make_symlink paths.dist
    rescue Errno::EEXIST
      # Sometimes happens when starting multiple Unicorn workers.
      # Ignoring...
    end

    def add_assets_to_precompile_list
      assets = %r{\A#{name}/}

      Rails.configuration.assets.precompile << assets
      NonStupidDigestAssets.whitelist << assets
    end

    def ember_app_name
      @ember_app_name ||= options.fetch(:name){ package_json.fetch(:name) }
    end

    def package_json
      @package_json ||=
        JSON.parse(paths.package_json_file.read).with_indifferent_access
    end

    def excluded_ember_deps
      Array.wrap(options[:exclude_ember_deps]).join(?,)
    end

    def env_hash
      ENV.to_h.tap do |vars|
        vars["RAILS_ENV"] = Rails.env
        vars["EXCLUDE_EMBER_ASSETS"] = excluded_ember_deps
        vars["BUNDLE_GEMFILE"] = paths.gemfile.to_s if paths.gemfile.exist?
      end
    end

    def wait_for_build_complete_or_error
      loop do
        check_for_build_error!
        break unless paths.lockfile.exist?
        sleep 0.1
      end
    end
  end
end
