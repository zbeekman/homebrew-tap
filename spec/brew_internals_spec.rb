# typed: true
# frozen_string_literal: true

# Homebrew's own specs turn this cop off in `Library/Homebrew/test/.rubocop.yml`
# ("RSpec helper methods typecheck better as regular methods"); the tap's style
# config does not inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require "api/source_download"
require "ask"
require "caveats"
require "cask/cask"
require "cmd/install"
require "cmd/reinstall"
require "cmd/upgrade"
require "download_queue"
require "messages"
require "open3"
require "system_config"
require "tab"
require_relative "../cmd/install-timed"
require_relative "../lib/timed/command"
require_relative "../lib/timed/runner"
require_relative "support/bottles"

# Canaries: each pins a brew internal the `-timed` commands rely on, so a brew
# change fails here instead of during a real upgrade. When one fails, first
# re-check the `-timed` behaviour that depends on it. Then prefer a test of the
# behaviour itself over a pin of brew's source text wherever it is practical
# and adds little code or verbosity; pin the new text only otherwise.
RSpec.describe "brew internals", type: :system do
  include TimedBottleHelper

  def brew_source(path) = (HOMEBREW_LIBRARY_PATH/path).read

  # `[command, sudo]` for each `run`/`run!` call with a `sudo:` argument.
  def sudo_calls(path)
    brew_source(path)
      .scan(/\.run!?[\s(]+"([^"]+)"(?:(?!\.run!?[\s(]).)*?sudo:\s*(nil|true)/m)
  end

  # The value of every `sudo:` keyword in the file, whatever the call looks
  # like; shorthand `sudo:` gives `""`.
  def sudo_values(path) = brew_source(path).scan(/\bsudo:[ \t]*([^,)\s]*)/).flatten

  # `stanza` is Cask DSL source: Sorbet cannot see the DSL's generated methods.
  def artifacts(stanza, config: nil)
    Cask::Cask.new("timed-canary", config:) do
      version "1.0"
      sha256 :no_check
      url "file:///dev/null"
      instance_eval(stanza, __FILE__, __LINE__)
    end.artifacts
  end

  # `[stanza, directive]` for each directive with a value that
  # `AbstractUninstall.dispatch_directives` dispatches, run with `options`
  # over the `uninstall` and then the `zap` stanzas of `stanzas` (Cask DSL
  # source), as `Installer#uninstall_artifacts` orders them.
  def dispatched(stanzas, **options)
    all = artifacts(stanzas)
    directive_artifacts = [*all.grep(Cask::Artifact::Uninstall), *all.grep(Cask::Artifact::Zap)]
    calls = []
    directive_artifacts.each do |stanza|
      allow(stanza).to receive(:dispatch_uninstall_directive) do |directive|
        calls << [stanza.class.dsl_key, directive] if stanza.directives[directive].present?
      end
    end
    Cask::Artifact::AbstractUninstall.dispatch_directives(directive_artifacts, command: SystemCommand, **options)
    calls
  end

  # The message of the error the source-build check of `brew install argv`
  # raises for a bottled and an unbottled formula, with or without the
  # developer tools, or `nil` if it goes on.
  def build_flags_error(argv, developer_tools:)
    allow(DevelopmentTools).to receive(:installed?).and_return(developer_tools)
    # Keeps the support tier a source build notes out of the run's exit.
    allow(Homebrew::Diagnostic).to receive(:support_tiers).and_return([])
    # RuboCop's project index only sees this tap, so it takes brew's
    # `InstallCmd` for a typo of `InstallTimed`.
    command = Homebrew::Cmd::InstallCmd.new([*argv, "timed-canary"]) # rubocop:disable Lint/NameTypo
    command.check_build_flags([true, false].map { |bottled| instance_double(Formula, bottled?: bottled) })
    nil
  rescue BuildFlagsError => e
    e.message
  end

  describe "tap commands" do
    # How `brew` finds each of this tap's commands, every `cmd/*.rb`.
    it "are only found when executable" do
      dir = mktmpdir
      %w[plain runnable].each { |name| FileUtils.touch dir/"#{name}.rb" }
      (dir/"runnable.rb").chmod(0755)
      allow(Commands).to receive(:tap_cmd_directories).and_return([dir])
      found = %w[plain runnable].to_h { |name| [name, Commands.external_ruby_v2_cmd_path(name)] }
      expect(found).to eq("plain" => nil, "runnable" => dir/"runnable.rb")
    end

    it "in this tap are all executable" do
      expect((Pathname(__FILE__).dirname.parent/"cmd").children.reject(&:executable?)).to eq([])
    end
  end

  describe "the `cmd_args` block of the wrapped commands" do
    it "is kept in `@parser_block`" do
      commands = %w[upgrade install reinstall].map { |name| Timed::Command.builtin(name) }
      block_classes = commands.to_h { |command| [command.name, command.instance_variable_get(:@parser_block).class] }
      expect(block_classes).to eq(commands.to_h { |command| [command.name, Proc] })
    end
  end

  describe "Tab" do
    let(:receipt) { mktmpdir/"foo/1.0/INSTALL_RECEIPT.json" }
    let(:content) do
      JSON.pretty_generate("homebrew_version" => "5.0.0", "build_times" => { "wall_seconds" => 1.0 })
    end

    before { receipt.dirname.mkpath }

    it "ignores unknown keys when reading a receipt" do
      expect(Tab.from_file_content(content, receipt).homebrew_version).to eq("5.0.0")
    end

    it "drops unknown keys when writing a receipt" do
      Tab.from_file_content(content, receipt).write
      expect(JSON.parse(receipt.read)).not_to have_key("build_times")
    end

    it "writes receipts with `JSON.pretty_generate`" do
      Tab.from_file_content(content, receipt).write
      expect(receipt.read).to eq(JSON.pretty_generate(JSON.parse(receipt.read)))
    end
  end

  describe "Cask::Artifact::AbstractArtifact#requires_sudo?" do
    it "is true for the stanzas that need root" do
      stanzas = {
        "pkg"                  => 'pkg "Foo.pkg"',
        "keyboard_layout"      => 'keyboard_layout "Foo.bundle"',
        "installer with sudo"  => 'installer script: { executable: "install.sh", sudo: true }',
        "install step as root" => 'postflight_steps steps: [{ type: "run", executable: "/usr/bin/true", sudo: true }]',
      }
      requires_sudo = stanzas.transform_values { |stanza| artifacts(stanza).any?(&:requires_sudo?) }
      expect(requires_sudo).to eq(stanzas.transform_values { true })
    end

    it "is false for app" do
      expect(artifacts('app "Foo.app"').any?(&:requires_sudo?)).to be(false)
    end

    it "is false for an install step with `sudo: :if_needed`" do
      steps = [{ type: "remove", paths: [{ path: "/opt/x/f" }], sudo: "if_needed" }]
      expect(artifacts("postflight_steps steps: #{steps.inspect}").any?(&:requires_sudo?)).to be(false)
    end

    it "is false for a `set_ownership` install step" do
      steps = [{ type: "set_ownership", paths: [{ path: "/Applications/Foo.app" }] }]
      expect(artifacts("postflight_steps steps: #{steps.inspect}").any?(&:requires_sudo?)).to be(false)
    end
  end

  it "covers every flight block stanza with Cask::Artifact::AbstractFlightBlock" do
    keys = Cask::DSL::ARTIFACT_BLOCK_CLASSES.flat_map do |klass|
      if klass < Cask::Artifact::AbstractFlightBlock
        [klass.dsl_key, klass.uninstall_dsl_key]
      else
        [klass]
      end
    end
    expect(keys).to contain_exactly(:preflight, :postflight, :uninstall_preflight, :uninstall_postflight)
  end

  it "prefixes the uninstall flight block keys with `uninstall_`, and no other" do
    prefixed = Cask::DSL::ARTIFACT_BLOCK_CLASSES.to_h do |klass|
      [klass.name, [klass.dsl_key, klass.uninstall_dsl_key].map { |key| key.start_with?("uninstall_") }]
    end
    expect(prefixed).to eq(Cask::DSL::ARTIFACT_BLOCK_CLASSES.to_h { |klass| [klass.name, [false, true]] })
  end

  describe "cask file-permission sudo fallbacks" do
    let(:expected_sudo_calls) do
      {
        "cask/artifact/moved.rb"                   => [["/bin/cp", "nil"], ["/bin/cp", "nil"], ["/bin/cp", "nil"]],
        "cask/artifact/symlinked.rb"               => [["/bin/ln", "nil"]],
        "extend/os/mac/cask/artifact/symlinked.rb" => [["/bin/ln", "nil"]],
        "cask/utils.rb"                            => [["mkdir", "nil"], ["rmdir", "nil"], ["/bin/rm", "nil"],
                                                       ["chown", "true"]],
      }
    end

    it "runs the same commands with `sudo:` in each file" do
      expect(expected_sudo_calls.to_h { |path, _calls| [path, sudo_calls(path)] }).to eq(expected_sudo_calls)
    end

    it "has no other `sudo:` arguments in each file" do
      expect(expected_sudo_calls.to_h { |path, _calls| [path, sudo_values(path)] })
        .to eq(expected_sudo_calls.transform_values { |calls| calls.map(&:last) })
    end

    it "still goes through Cask::Utils.gain_permissions_* in `moved.rb` and `symlinked.rb`" do
      helpers = %w[cask/artifact/moved.rb cask/artifact/symlinked.rb extend/os/mac/cask/artifact/symlinked.rb]
                .flat_map { |path| brew_source(path).scan(/Utils\.(gain_permissions_\w+)/).flatten }
      expect(helpers.uniq).to contain_exactly("gain_permissions_mkpath", "gain_permissions_remove")
    end
  end

  describe "`Relocated#add_altname_metadata`" do
    it "runs `chmod` and `xattr -w` with `sudo: nil`" do
      expect(sudo_calls("cask/artifact/relocated.rb")).to eq([["chmod", "nil"], ["/usr/bin/xattr", "nil"]])
    end

    it "has no other `sudo:` arguments" do
      expect(sudo_values("cask/artifact/relocated.rb")).to eq(["nil", "nil"])
    end

    it "changes the target of a bundle" do
      expect(brew_source("cask/artifact/moved.rb")).to include("add_altname_metadata(target, source.basename")
    end

    it "changes the source of a link on macOS" do
      expect(brew_source("extend/os/mac/cask/artifact/symlinked.rb"))
        .to include("add_altname_metadata(source, target.basename")
    end

    it "does nothing when the names match, ignoring case" do
      expect(brew_source("cask/artifact/relocated.rb"))
        .to include("return if altname.to_s.casecmp(file.basename.to_s)&.zero?")
    end

    it "runs commands only on macOS, so it is a no-op on Linux" do
      file = mktmpdir/"Foo.app"
      file.mkpath
      ran = []
      [:run, :run!].each do |method|
        allow(SystemCommand).to receive(method) do |executable|
          ran << executable
          instance_double(SystemCommand::Result, stdout: "")
        end
      end
      artifacts('app "Foo.app"').to_a.fetch(0).add_altname_metadata(file, Pathname("Bar.app"), command: SystemCommand)
      expect(ran.any?).to be(OS.mac?), "`OS.mac?` is #{OS.mac?}, but it ran #{ran.inspect}"
    end
  end

  describe "`sudo: :if_needed` install steps" do
    it "checks `dirname.writable?` of a removed path and of a symlink's target" do
      checked = brew_source("install_steps.rb").scan(/step\["sudo"\] == "if_needed" && !(\w+)\.dirname\.writable\?/)
      expect(checked.flatten).to eq(["path", "target", "target"])
    end
  end

  describe "optional install steps" do
    it "counts for sudo only when `include_optional` is set, which `requires_sudo?` leaves out" do
      expect(brew_source("install_steps.rb")).to include(
        '(include_optional && (step["sudo"] == "if_needed" || step["type"] == "set_ownership"))',
      )
      expect(brew_source("cask/artifact/install_steps.rb"))
        .to include("sudo_required?(steps, include_optional: false)")
    end
  end

  describe "`requires_sudo?` of install steps" do
    it "is false unless the artifact has an `install_phase`, so `Uninstall*Steps` never count" do
      expect(brew_source("cask/artifact/install_steps.rb")).to include("respond_to?(:install_phase) &&")
    end

    it "is not defined on `Uninstall*Steps`" do
      steps = [Cask::Artifact::UninstallPreflightSteps, Cask::Artifact::UninstallPostflightSteps]
      expect(steps.map { |klass| klass.method_defined?(:install_phase) }).to eq([false, false])
    end
  end

  describe "`uninstall signal` on upgrade and reinstall" do
    it "is skipped unless `on_upgrade` names it, read with `Array()` and `to_s`, so a String counts" do
      on_upgrades = [nil, ":quit", ":signal", '"signal"', "[:signal]", '["signal"]']
      modes = { "upgrade" => { upgrade: true }, "reinstall" => { reinstall: true }, "uninstall" => {} }
      actual = on_upgrades.to_h do |on_upgrade|
        option = ", on_upgrade: #{on_upgrade}" if on_upgrade
        stanza = %Q(uninstall signal: ["TERM", "com.foo"]#{option})
        [on_upgrade, modes.transform_values { |mode| dispatched(stanza, **mode).include?([:uninstall, :signal]) }]
      end
      named = { "upgrade" => true, "reinstall" => true, "uninstall" => true }
      unnamed = { "upgrade" => false, "reinstall" => false, "uninstall" => true }
      expect(actual).to eq({ nil => unnamed, ":quit" => unnamed, ":signal" => named, '"signal"' => named,
                             "[:signal]" => named, '["signal"]' => named })
    end
  end

  describe "`uninstall login_item` on upgrade and reinstall" do
    it "returns early because brew passes a `successor`" do
      body = brew_source("cask/artifact/abstract_uninstall.rb")[/^      def uninstall_login_item\(.*?^      end$/m]
      expect(body).to match(/\A[^\n]*\n\s+return if successor\n/)
      expect(brew_source("cask/upgrade.rb")).to include("old_cask_installer.start_upgrade(successor: new_cask")
      expect(brew_source("cask/installer.rb")).to include("cask_installer.uninstall(successor: @cask)")
    end
  end

  describe "`Cask::Utils` around missing paths" do
    it "makes a symlink's directory without sudo, and has nothing to remove for a missing path" do
      expect(brew_source("install_steps.rb"))
        .to match(/def create_symlink\(source, target, step\)\n\s+target\.dirname\.mkpath\n\s+if step\["sudo"\]/)
      remove_body = brew_source("cask/utils.rb")[/^    def self\.gain_permissions_remove\(.*?^    end$/m]
      expect(remove_body).to match(/# Nothing to remove\.\n\s+return\n\s+end\n/)
      expect(brew_source("cask/utils.rb")).to include("dir = path.ascend.find(&:directory?)")
    end
  end

  describe "removing an install-step link on uninstall" do
    it "removes a link to the source, absolute or `relative`, and leaves any other link" do
      dir = mktmpdir
      (dir/"bin").mkpath
      (dir/"bin/mine").make_symlink(dir/"src")
      (dir/"bin/other").make_symlink("/elsewhere")
      (dir/"bin/rel").make_symlink("../src")
      steps = [
        ["mine", { "path" => (dir/"src").to_s }],
        ["other", { "path" => (dir/"src").to_s }],
        ["rel", { "path" => "../src", "base" => "relative" }],
      ].map do |name, source|
        { "type" => "symlink", "source" => source, "target" => { "path" => (dir/"bin"/name).to_s },
          "uninstall" => true }
      end
      Homebrew::InstallSteps::Runner.new(context: Object.new).run(steps, phase: :uninstall)
      expect(%w[mine other rel].to_h { |name| [name, (dir/"bin"/name).symlink?] })
        .to eq({ "mine" => false, "other" => true, "rel" => false })
    end
  end

  describe "`reinstall --zap`" do
    it "is offered by `reinstall`, not `upgrade`" do
      zap_options = %w[reinstall upgrade].to_h do |name|
        options = Timed::Command.builtin(name).parser.processed_options
        [name, options.any? { |_short, long, _desc, _hidden| long == "--zap" }]
      end
      expect(zap_options).to eq({ "reinstall" => true, "upgrade" => false })
    end

    it "is passed on only by `reinstall`, which calls `Installer#zap` only from `uninstall_existing_cask`" do
      passed_on = %w[cmd/install.rb cmd/upgrade.rb cmd/reinstall.rb].to_h do |path|
        [path, brew_source(path).scan(/zap:\s*args\.zap\?/).length]
      end
      zap_calls = %w[cask/installer.rb cask/upgrade.rb cask/reinstall.rb].flat_map do |path|
        brew_source(path).scan(/\.zap\b/).map { |call| [path, call] }
      end
      expect([passed_on, zap_calls.map(&:first)])
        .to eq([{ "cmd/install.rb" => 0, "cmd/upgrade.rb" => 0, "cmd/reinstall.rb" => 2 }, ["cask/installer.rb"]])
    end

    it "replaces `uninstall(successor:)` with `Installer#zap` for a reinstall of the installed cask" do
      body = brew_source("cask/installer.rb")[/^    def uninstall_existing_cask\n.*?^    end$/m]
      expect(body).to include("zap? ? cask_installer.zap : cask_installer.uninstall(successor: @cask)")
      expect(body).to match(/Installer\.new\(@cask, .*reinstall: true\)/)
    end

    it "uninstalls the installed cask without a successor, with its `zap` stanzas" do
      body = brew_source("cask/installer.rb")[/^    def zap\(dry_run: false\)\n.*?^    end$/m]
      expect(body.lines.map(&:strip).grep(/uninstall_artifacts|zap_phase|load_installed_caskfile|zap_stanzas =/))
        .to eq(["load_installed_caskfile!", "zap_stanzas = @cask.artifacts.grep(Artifact::Zap)",
                "uninstall_artifacts(clear: true, zap_stanzas:)"])
    end

    it "dispatches the `zap` stanzas after the `uninstall` stanza, with the installer's `successor` and " \
       "`reinstall`, then again for the deferred directives" do
      body = brew_source("cask/installer.rb")[/^    def uninstall_artifacts\(.*?^    end$/m]
      calls = body.scan(/AbstractUninstall\.dispatch_directives\((.*?)\)$/m).flatten
                  .map { |args| args.gsub(/\s+/, " ") }
      expect([body.include?("directive_artifacts = [*artifacts.grep(Artifact::Uninstall), *zap_stanzas]"), calls])
        .to eq([true, ["directive_artifacts, command: @command, force: force?, successor:, upgrade: upgrade?, " \
                       "reinstall: reinstall?, quit:",
                       "directive_artifacts, command: @command, deferred: true, force: force?, successor:"]])
    end

    it "dispatches every directive of the `uninstall` and `zap` stanzas over both passes, but `signal` as a " \
       "reinstall, unless the stanza's own `on_upgrade` names it" do
      directives = 'early_script: "e.sh", launchctl: "com.foo", quit: "com.foo", signal: ["TERM", "com.foo"], ' \
                   'login_item: "Foo", kext: "com.foo", script: "x.sh", pkgutil: "com.foo", ' \
                   'delete: "/Library/Foo", trash: "~/Foo", rmdir: "~/Foo"'
      stanzas = { "neither" => "uninstall #{directives}\nzap #{directives}",
                  "zap's"   => "uninstall #{directives}\nzap #{directives}, on_upgrade: :signal" }
      actual = stanzas.transform_values do |source|
        (dispatched(source, reinstall: true) + dispatched(source, deferred: true)).sort
      end
      every = [:uninstall, :zap].product(Cask::Artifact::AbstractUninstall::ORDERED_DIRECTIVES)
      expect(actual).to eq({ "neither" => (every - [[:uninstall, :signal], [:zap, :signal]]).sort,
                             "zap's"   => (every - [[:uninstall, :signal]]).sort })
    end

    it "runs `uninstall_login_item` unless brew passes a `successor`" do
      body = brew_source("cask/artifact/abstract_uninstall.rb")[/^      def uninstall_login_item\(.*?^      end$/m]
      expect(body.scan(/\breturn\b.*/)).to eq(["return if successor"])
    end
  end

  describe "`install --force` over an existing bundle" do
    it "fails without `force` and otherwise deletes the target, with permission recovery" do
      app = artifacts('app "Foo.app"', config: Cask::Config.new(explicit: { appdir: mktmpdir })).to_a.fetch(0)
      removed = []
      allow(Cask::Utils).to receive(:gain_permissions_remove).and_wrap_original do |remove, path, **options|
        removed << path
        remove.call(path, **options)
      end
      outcomes = [false, true].to_h do |force|
        [app.source, app.target].each { |bundle| (bundle/"Contents").mkpath }
        removed.clear
        raised = begin
          app.install_phase(force:, command: NeverSudoSystemCommand)
          false
        rescue Cask::CaskError
          true
        end
        [force, [raised, removed.dup]]
      end
      expect(outcomes).to eq(false => [true, []], true => [false, [app.target]])
    end

    it "is reached through the `force` that `brew install` passes to the cask installer" do
      # One entry per call, in `#fetch_installers` then `#install_casks`.
      calls = brew_source("cmd/install.rb").scan(/Cask::Installer\.new\(\n.*?^ +\)$/m)
      installer = brew_source("cask/installer.rb")
      expect([calls.map { |call| call.match?(/^\s+force:\s+args\.force\?,$/) },
              installer.include?("force: force?, predecessor:"),
              brew_source("cask/artifact/moved.rb").include?("move(adopt:, auto_updates:, force:,")])
        .to eq([[true, true], true, true])
    end
  end

  describe "`symlink` install step with `source_glob`" do
    it "links into a target directory, so `if_needed` checks that directory" do
      body = brew_source("install_steps.rb")[/^        when "symlink"\n.*?^        when "write"/m]
      expect(body.lines.map(&:strip).grep(/sources\.length|mkpath|create_symlink/))
        .to eq(["if sources.length > 1 || target.directory?", "target.mkpath",
                "sources.each { |source| create_symlink(source, target/source.basename, step) }",
                "create_symlink(source, target, step) if source",
                "create_symlink(link_source(step_path(step, \"source\")), target, step)"])
    end
  end

  describe "`SystemCommand.run` with `sudo: nil`" do
    it "retries with sudo when the command fails, which `set_ownership`'s `chown` relies on" do
      retry_block = brew_source("system_command.rb")[/^    if sudo\.nil\?\n.*?^    end$/m]
      expect(retry_block).to match(/return result\n\s+end\n\s+sudo = true\n/)
    end
  end

  describe "uninstalling a cask" do
    it "runs the `uninstall_phase` of every artifact but `uninstall` and `zap`, whose directives it dispatches " \
       "around them, on upgrade and on reinstall" do
      all = artifacts(<<~RUBY, config: Cask::Config.new(explicit: { appdir: mktmpdir }))
        app "Foo.app"
        binary "foo"
        uninstall_preflight_steps { touch "a" }
        uninstall_postflight_steps { touch "b" }
        uninstall quit: "com.foo"
        zap trash: "~/Foo"
      RUBY
      calls = []
      all.select { |artifact| artifact.respond_to?(:uninstall_phase) }.each do |artifact|
        allow(artifact).to receive(:uninstall_phase) do |**options|
          calls << [artifact.class.dsl_key, options.slice(:skip, :force, :successor, :upgrade, :reinstall)]
        end
      end
      allow(Cask::Artifact::AbstractUninstall).to receive(:dispatch_directives) do |stanzas, **options|
        calls << [stanzas.map { |stanza| stanza.class.dsl_key }, options.slice(:deferred, :upgrade, :reinstall)]
      end
      cask = all.to_a.fetch(0).cask
      # As `start_upgrade` (without `--force`) and `zap` (`reinstall --zap`,
      # always forced by `uninstall_existing_cask`) call it.
      actual = { upgrade: [], reinstall: all.grep(Cask::Artifact::Zap) }.to_h do |mode, zap_stanzas|
        calls.clear
        installer = Cask::Installer.new(cask, force: mode == :reinstall, upgrade: mode == :upgrade,
                                              reinstall: mode == :reinstall)
        if mode == :upgrade
          installer.uninstall_artifacts(successor: cask, quit: true)
        else
          installer.uninstall_artifacts(clear: true, zap_stanzas:)
        end
        [mode, calls.dup]
      end
      expected = { upgrade: [:uninstall], reinstall: [:uninstall, :zap] }.to_h do |mode, stanzas|
        flags = { upgrade: mode == :upgrade, reinstall: mode == :reinstall }
        phase = { skip: flags[:reinstall], force: flags[:reinstall], successor: (cask if flags[:upgrade]), **flags }
        [mode, [[:uninstall_preflight_steps, phase], [stanzas, flags], [:app, phase], [:binary, phase],
                [:uninstall_postflight_steps, phase], [stanzas, { deferred: true }]]]
      end
      expect(actual).to eq(expected)
    end

    it "has a `post_uninstall_phase` only in `uninstall`, which runs its deferred directives" do
      classes = [*Cask::DSL::ORDINARY_ARTIFACT_CLASSES, *Cask::DSL::ARTIFACT_BLOCK_CLASSES,
                 *Cask::DSL::INSTALL_STEP_ARTIFACT_CLASSES]
      body = brew_source("cask/artifact/uninstall.rb")[/^      def post_uninstall_phase\(.*?^      end$/m]
      expect([classes.select { |klass| klass.method_defined?(:post_uninstall_phase) }, body.lines.map(&:strip)[1]])
        .to eq([[Cask::Artifact::Uninstall],
                "AbstractUninstall.dispatch_directives([self], command:, deferred: true, force:, successor:)"])
    end

    it "does so from `uninstall` (reinstall) and `start_upgrade`" do
      source = brew_source("cask/installer.rb")
      expect([source[/^    def uninstall\(.*?^    end$/m], source[/^    def start_upgrade\(.*?^    end$/m]])
        .to match([/uninstall_artifacts\(clear: true, successor:\)/, /uninstall_artifacts\(successor:, quit:\)/])
    end

    it "runs a flight block's `dsl_key` on install and its `uninstall_dsl_key` on uninstall" do
      source = brew_source("cask/artifact/abstract_flight_block.rb")
      expect([source[/^      def install_phase\(.*?^      end$/m][/abstract_phase\(.*\)/],
              source[/^      def uninstall_phase\(.*?^      end$/m][/abstract_phase\(.*\)/]])
        .to eq(["abstract_phase(self.class.dsl_key)", "abstract_phase(self.class.uninstall_dsl_key)"])
    end

    it "removes only `symlink` steps with `uninstall: true` from `preflight_steps` and `postflight_steps`" do
      body = brew_source("install_steps.rb")[/^      def run_uninstall_step\(step\)\n.*?^      end$/m]
      expect(body).to match(
        /\A[^\n]*\n\s+return if step\.fetch\("type"\) != "symlink"\n\s+return if step\["uninstall"\] != true\n/,
      )
      expect(body).to include("return unless target.symlink?",
                              'step["sudo"] == true || (step["sudo"] == "if_needed" && !target.dirname.writable?)')
    end

    it "loads the installed caskfile to reinstall it" do
      body = brew_source("cask/installer.rb")[/^    def load_installed_caskfile!.*?^    end$/m]
      expect(body).to include("CaskLoader.load_from_installed_caskfile(installed_caskfile)")
    end

    it "doesn't load a Ruby caskfile to reinstall a cask that isn't trusted, with tap trust on, as " \
       "`Timed::Command.installed_cask` follows, keeping the new cask (and its `zap`)" do
      body = brew_source("cask/installer.rb")[/^    def load_installed_caskfile!.*?^    end$/m].to_s
      guard = ["tab = CaskLoader.load_installed_tab(@cask)", "tap = tab.tap", "tap ||= @cask.tap",
               'if installed_caskfile.extname == ".rb" &&', "Homebrew::EnvConfig.require_tap_trust? &&", "tap &&",
               "!Homebrew::Trust.trusted?(:cask, \"\#{tap.name}/\#{@cask.token}\")"]
      lines = body.lines.map(&:strip)
      untrusted = body[/trusted\?.*?^\s+return$/m]
      zap = brew_source("cask/installer.rb")[/^    def zap\(dry_run: false\)\n.*?^    end$/m].to_s
      expect([guard.map { |line| lines.index(line) }.then { |at| at.all? && at == at.sort },
              untrusted&.exclude?("@cask ="), zap.include?("@cask.artifacts.grep(Artifact::Zap)")])
        .to eq([true, true, true])
    end

    it "uninstalls instead the artifacts the untrusted cask recorded, replayed as `Timed::Command.recorded_cask` " \
       "replays them" do
      source = brew_source("cask/installer.rb")
      untrusted = source[/^    def load_installed_caskfile!.*?^    end$/m].to_s[/trusted\?.*?^\s+return$/m].to_s
      replay = ["dsl = DSL.new(@cask)",
                "default_uninstall_artifact_keys = DSL::ACTIVATABLE_ARTIFACT_CLASSES.filter_map do |klass|",
                "next if [Artifact::Uninstall, Artifact::Zap].include?(klass)",
                "next if !klass.method_defined?(:uninstall_phase) && !klass.method_defined?(:post_uninstall_phase)",
                "Array(tab.uninstall_artifacts).each do |artifact_entry|",
                "next unless default_uninstall_artifact_keys.include?(dsl_key)",
                "args = Array(raw_args)", "if args.last.is_a?(Hash)", "*args[...-1],",
                "**T.cast(args.last, T::Hash[T.any(Symbol, String), T.anything]).transform_keys(&:to_sym),",
                "dsl.public_send(dsl_key, *args)",
                "@default_uninstall_artifacts ||= dsl.artifacts"]
      expect([replay.map { |line| untrusted.lines.map(&:strip).include?(line) },
              source.match?(/def artifacts\n\s+@default_uninstall_artifacts \|\| @cask\.artifacts\n/)])
        .to eq([replay.map { true }, true])
    end
  end

  describe "`brew upgrade` of a cask" do
    it "uninstalls the installed caskfile's cask and merges its config into the new cask's" do
      expect(brew_source("cask/upgrade.rb")).to include(
        "CaskLoader.load_from_installed_caskfile(installed_caskfile)",
        "Installer.new(old_cask, **old_options)",
        "new_cask.config = new_cask.default_config.merge(old_config)",
      )
    end
  end

  describe "the casks the wrapped commands act on" do
    it "are, for `brew upgrade`, the outdated ones below `--minimum-version`, but not `installer manual` ones" do
      expected = ["casks = minimum_version_casks(casks, quiet: true)",
                  "return false if minimum_version.present? && casks.empty?", "",
                  "outdated_casks = Cask::Upgrade.outdated_casks(", "casks,", "args:,",
                  "force: args.force?,", "quiet: true,", "greedy: args.greedy?,",
                  "greedy_latest: args.greedy_latest?,", "greedy_auto_updates: args.greedy_auto_updates?,",
                  "summary_pinned: final_upgrade_summary.pinned_casks,", ")", "return true if outdated_casks.empty?",
                  "", "manual_installer_casks = outdated_casks.select do |cask|", "cask.artifacts.any? do |artifact|",
                  "artifact.is_a?(Cask::Artifact::Installer) && artifact.manual_install"]
      expect("cmd/upgrade.rb" => lines_from("cmd/upgrade.rb", expected.fetch(0), expected.length))
        .to eq("cmd/upgrade.rb" => expected)
    end

    it "are, for `brew install`, the new ones and the installed, outdated ones it upgrades" do
      expected = ["installed_casks, new_casks = casks.partition(&:installed?)", "",
                  "fetch_casks = if Homebrew::EnvConfig.no_install_upgrade?", "new_casks", "else",
                  "upgrade_casks = Cask::Upgrade.outdated_casks(casks, args:, force: true, quiet: true)",
                  "new_casks | upgrade_casks", "end",
                  "Install.ask_casks fetch_casks, skip_cask_deps: args.skip_cask_deps? if ask"]
      expect("cmd/install.rb" => lines_from("cmd/install.rb", expected.fetch(0), expected.length))
        .to eq("cmd/install.rb" => expected)
    end

    it "are printed by `Install.print_dry_run_casks`, which `brew install --dry-run` and the cask prompts use, " \
       "and which returns the dependencies to install that make brew ask" do
      ask_casks = brew_source("install.rb")[/^      def ask_casks\(.*?^      end$/m].to_s
      expect([brew_source("cmd/install.rb").include?(
        "Install.print_dry_run_casks(casks, skip_cask_deps: args.skip_cask_deps?, include_installed: false)",
      ), brew_source("cmd/reinstall.rb").include?(
        'Install.ask_casks casks, action: "reinstallation", skip_cask_deps: args.skip_cask_deps? if ask',
      ), ask_casks.include?("dependency_names = print_dry_run_casks("),
              ask_casks.match?(/planned_names:\s+cask_names \+ dependency_names,\n\s+requested_names: cask_names,/)])
        .to eq([true, true, true, true])
    end

    it "are uninstalled, on upgrade, as their installed caskfile defines them, or as rebuilt from it" do
      expect(brew_source("cask/upgrade.rb"))
        .to include("CaskLoader.recover_from_installed_caskfile(installed_caskfile, fallback_cask: c)")
    end
  end

  describe "the cask installer's dependencies" do
    it "installs a missing cask dependency before the cask, unless `--skip-cask-deps` is set" do
      source = brew_source("cask/installer.rb")
      def_lines = ->(name) { source[/^    def #{name}\b.*?^    end$/m].to_s.lines.map(&:strip) }
      install_missing = "cask_installers.reject { |installer| installer.cask.installed? }.each(&:install)"
      wanted = {
        "fetch"                                 => "satisfy_cask_and_formula_dependencies",
        "satisfy_cask_and_formula_dependencies" => install_missing,
        "missing_cask_and_formula_dependencies" => "cask_or_formula.installed?",
        "dependency_installers"                 => "next if skip_cask_deps?",
      }
      expect(wanted.to_h { |name, line| [name, def_lines.call(name).include?(line)] })
        .to eq(wanted.transform_values { true })
    end
  end

  describe "`set_ownership` install steps" do
    it "fails without App Management permission, and runs `chown` with `sudo: nil`" do
      body = brew_source("install_steps.rb")[/^      def run_set_ownership\(step\)\n.*?^      end$/m]
      expect(body).to match(/app_management_permissions_granted\?.*raise ::Cask::CaskError/m)
      expect(body).to match(/@command\.run!\("chown".*?sudo: nil\)/m)
    end
  end

  it "rolls back a failed cask upgrade" do
    revert_lines = brew_source("cask/upgrade.rb").lines.grep(/revert_upgrade/).map(&:strip)
    expect("cask/upgrade.rb" => revert_lines)
      .to eq("cask/upgrade.rb" => ["old_cask_installer.revert_upgrade(predecessor: new_cask) if started_upgrade"])
  end

  describe "Homebrew::Ask.confirm?" do
    def confirmed_on_tty?(key)
      allow($stdin).to receive_messages(tty?: true, getch: key)
      allow($stdout).to receive(:tty?).and_return(true)
      Homebrew::Ask.confirm?(action: "upgrade")
    end

    it "returns false without a TTY" do
      allow($stdin).to receive(:tty?).and_return(false)
      expect(Homebrew::Ask.confirm?(action: "upgrade")).to be(false)
    end

    it "returns true on y" do
      expect(confirmed_on_tty?("y")).to be(true)
    end

    it "exits 1 on n" do
      expect { confirmed_on_tty?("n") }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end
  end

  describe "`brew update-if-needed`" do
    def update_if_needed(env)
      script = <<~SH
        brew() { echo "brew $*"; }
        source "#{HOMEBREW_LIBRARY_PATH}/utils/auto-update.sh"
        source "#{HOMEBREW_LIBRARY_PATH}/cmd/update-if-needed.sh"
        homebrew-update-if-needed
        echo "not exec'd"
      SH
      env = { "PATH" => ENV.fetch("PATH"), "HOMEBREW_REPOSITORY" => mktmpdir.to_s, **env }
      Open3.capture2(env, "/bin/bash", "-c", script, unsetenv_others: true).first
    end

    it "updates without `HOMEBREW_AUTO_UPDATE_CHECKED`, and doesn't exec" do
      expect(update_if_needed({})).to eq("brew update --auto-update\nnot exec'd\n")
    end

    it "is a no-op with `HOMEBREW_AUTO_UPDATE_CHECKED` set" do
      expect(update_if_needed("HOMEBREW_AUTO_UPDATE_CHECKED" => "1")).to eq("not exec'd\n")
    end
  end

  # The lines of brew's `path` from the one that is `first` on, stripped and
  # with runs of spaces squeezed.
  def lines_from(path, first, count)
    lines = brew_source(path).lines.map { |line| line.strip.squeeze(" ") }
    lines.index(first)&.then { |index| lines[index, count] }
  end

  # A formula named `name` with nothing more than a URL, in the tap `tap`
  # (homebrew/core without one).
  def plain_formula(name, tap: nil, alias_path: nil)
    formula(name, tap:, alias_path:) do
      T.bind(self, T.class_of(Formula))
      url "https://brew.sh/#{name}-1.0.tgz"
    end
  end

  # A keg of `name` at `version` with the receipt `receipt`, linked into each
  # of `links` (`opt` and the prefix by default).
  def installed_keg(name, version, receipt: {}, links: [HOMEBREW_PREFIX/"opt", HOMEBREW_LINKED_KEGS])
    keg = HOMEBREW_CELLAR/name/version
    keg.mkpath
    (keg/AbstractTab::FILENAME).write(JSON.generate(receipt))
    links.each do |dir|
      dir.mkpath
      FileUtils.ln_s keg, dir/name
    end
    keg
  end

  # What `brew upgrade-timed` upgrades (`UpgradeTimed#run`'s `upgradeable`
  # and `roots`), as brew does.
  it "drops pinned formulae, then upgrades each to its alias's new target unless that is up to date" do
    # `UpgradeCmd` is brew's command, not a typo of `UpgradeTimed`.
    cmd = Homebrew::Cmd::UpgradeCmd.new([]) # rubocop:disable Lint/NameTypo
    pinned, renamed, current, target, installed = %w[pinned renamed current target installed].map do |name|
      plain_formula(name)
    end
    allow(pinned).to receive(:pinned?).and_return(true)
    allow(renamed).to receive(:latest_formula).and_return(target)
    allow(current).to receive(:latest_formula).and_return(installed)
    allow(installed).to receive(:latest_version_installed?).and_return(true)
    allow(cmd).to receive(:formula_outdated?).and_return(true)
    allow(Homebrew::Install).to receive(:perform_preinstall_checks_once)
    allow(Homebrew::Upgrade).to receive_messages(
      formula_installers: [instance_double(FormulaInstaller)],
      dependants:         Homebrew::Upgrade::Dependents.new(upgradeable: [], pinned: [], skipped: []),
    )
    context = cmd.formulae_upgrade_context([pinned, renamed, current], show_upgrade_summary: false)
    expect([context&.formulae_to_install, context&.pinned_formulae]).to eq([[target, current], [pinned]])
  end

  # Whether `brew upgrade-timed` asks before it upgrades (`UpgradeTimed#run`'s
  # `Install.ask_prompt_needed?` call), as brew does.
  it "asks about its plan by full name, against the named arguments as given" do
    # `UpgradeCmd` is brew's command, not a typo of `UpgradeTimed`.
    cmd = Homebrew::Cmd::UpgradeCmd.new(%w[--formula myalias]) # rubocop:disable Lint/NameTypo
    # A tapped formula, whose full name is not its name.
    tap = Tap.fetch("user", "tap")
    named = plain_formula("foo", tap:, alias_path: tap.alias_dir/"myalias")
    allow(cmd.args.named).to receive(:to_formulae_and_casks_and_unavailable).and_return([named])
    # Brew plans to upgrade the named formula, which it names as it names its
    # plan.
    allow(cmd).to receive(:upgrade_outdated_formulae!) do |formulae|
      cmd.final_upgrade_summary.version_changes.concat(cmd.formula_version_changes(formulae))
    end
    stop = Class.new(StandardError)
    expect(Homebrew::Install).to receive(:ask_prompt_needed?)
      .with(hash_including(planned_names: %w[user/tap/foo], requested_names: %w[myalias])).and_raise(stop)
    expect { cmd.run }.to raise_error(stop)
  end

  # `Timed::Planner.split`, which splits an upgrade batch before a slow
  # keg-only formula that follows another, as brew moves it to the front,
  # in the lists `UpgradeTimed#run` and `InstallTimed#run` (its `:upgrade`
  # batches) give it as `keg_only:`.
  it "upgrades keg-only formulae first" do
    keg_only = formula("keg-only") do
      T.bind(self, T.class_of(Formula))
      url "https://brew.sh/keg-only-1.0.tgz"
      keg_only "it is"
    end
    # The order brew makes the installers in, which it upgrades in.
    made = []
    allow(Homebrew::Upgrade).to receive(:create_formula_installer) do |formula|
      made << formula.name
      raise CannotInstallFormulaError, formula.name
    end
    Homebrew::Upgrade.formula_installers([plain_formula("plain"), keg_only], flags: [])
    expect(made).to eq(%w[keg-only plain])
  end

  # `Timed::Runner.run`, which takes a failed call that printed `Installation
  # times` as one brew finished, not stopped early.
  it "prints `Installation times` only if anything was installed" do
    expect { Messages.new.display_install_times }.not_to output.to_stdout
  end

  # `Timed::Runner.run`'s `stops_at_failure`, which `ReinstallTimed#run`
  # passes and reads `stopped_early` from to skip its last casks, and which
  # takes a failed call that printed `Installation times` (`INSTALL_TIMES`,
  # which brew prints for the `--display-times` it passes) as one brew
  # finished, not stopped early.
  it "finishes `brew reinstall --display-times`, printing `Installation times`, after the dependents, but never " \
     "after a failed build", :aggregate_failures do
    foo = plain_formula("foo")
    allow(Homebrew::Install).to receive_messages(perform_preinstall_checks_once: nil, ask_formulae: nil)
    # Nothing to download or clean up.
    allow(Homebrew::Install).to receive(:enqueue_formulae) { |installers, **| installers }
    allow(Homebrew::Cleanup).to receive_messages(install_clean!: nil, periodic_clean!: nil)
    marker = "<upgrading dependents>"
    allow(Homebrew::Upgrade).to receive(:upgrade_dependents) do
      # Into brew's output, which `output` captures below.
      puts marker # rubocop:disable RSpec/Output
      []
    end
    # The marker and the times heading brew prints, in order, after each kind
    # of failure.
    printed = { BuildError => [], RuntimeError => [marker, Timed::Runner::INSTALL_TIMES] }
    [BuildError.new(foo, "make", [], {}), RuntimeError.new("failed")].each do |error|
      # Brew's record of an installed formula, as its install leaves it, so
      # it has times to print; a new one each run, so none is left behind.
      messages = Messages.new
      messages.package_installed("foo", 1.0)
      allow(Homebrew).to receive(:messages).and_return(messages)
      allow(Homebrew::Reinstall).to receive(:reinstall_formula).and_raise(error)
      # `Reinstall` is brew's command, not a typo of `ReinstallTimed`.
      cmd = Homebrew::Cmd::Reinstall.new(%w[--formula --display-times foo]) # rubocop:disable Lint/NameTypo
      allow(cmd.args.named).to receive(:to_formulae_and_casks_and_unavailable).and_return([foo])
      expected = printed.fetch(error.class)
      order = satisfy("print #{expected} after a #{error.class}") do |text|
        text.lines(chomp: true).select { |line| [marker, Timed::Runner::INSTALL_TIMES].include?(line) } == expected
      end
      expect do
        cmd.run
      rescue BuildError
        # Brew's global handler reports it.
        nil
      end.to output(order).to_stdout
    end
  end

  it "prints `Installation times` in a fixed format" do
    messages = Messages.new
    messages.package_installed("llvm", 2811.4)
    expect { messages.display_install_times }
      .to output("==> Installation times\nllvm                   2811.400 s\n").to_stdout
  end

  it "prints `Installation times` as `Timed::Runner.parse` reads them, even with one space between the columns" do
    messages = Messages.new
    messages.package_installed("llvm", 2811.4)
    messages.package_installed("a-formula-with-a-long-name", 123456.789)
    lines = []
    allow(messages).to receive(:puts) { |line| lines << [line, nil] }
    messages.display_install_times
    expect(Timed::Runner.parse(lines).transform_values { |build| build["install_seconds"] })
      .to eq("llvm" => 2811.4, "a-formula-with-a-long-name" => 123456.789)
  end

  # `Timed::Runner.parse`: `DEPENDENCY_HEADING`, `INSTALL_TIME` and
  # `Parser#builds`, which takes each dependency's time from its parent's.
  it "times a formula's install from before it installs its dependencies, each named after the formula it is a " \
     "dependency of, so `Timed::Runner.parse` takes their times from its time" do
    foo, bar = %w[foo bar].map { |name| plain_formula(name, tap: Tap.fetch("user", "tap")) }
    stub_formula_loader(bar, call_original: true)
    messages = Messages.new
    allow(Homebrew).to receive(:messages).and_return(messages)
    # Each pour takes 100 seconds, and nothing else takes any time.
    now = Time.now
    allow(Time).to receive(:now) { now }
    allow_any_instance_of(FormulaInstaller).to receive(:pour) { now += 100 }
    allow_any_instance_of(FormulaInstaller)
      .to receive_messages(pour_bottle?: true, lock: nil, prelude: nil, finish: nil)
    allow_any_instance_of(FormulaInstaller).to receive(:compute_dependencies) do |installer|
      if installer.formula == foo
        [Dependency.new(bar.full_name)]
      else
        []
      end
    end
    lines = []
    allow($stdout).to receive(:puts) { |*printed| lines.concat(printed.map { ["#{it}\n", nil] }) }
    FormulaInstaller.new(foo).install
    messages.display_install_times
    expect(Timed::Runner.parse(lines).transform_values { |build| build["install_seconds"] })
      .to eq("foo" => 100.0, "bar" => 100.0)
  end

  # `Timed::Command.dependency_names`, which `InstallTimed#run` (the
  # dependencies of a formula it can't expand), `ReinstallTimed#reinstall`,
  # and `Timed::Command.dependents_call`, `.linkage_call`, `.fixable?`,
  # `.repairable` and `.run_dependencies` compare by full name, and which
  # prunes by `Dependency.action` itself, as it passes a block.
  describe "`Dependency.expand`" do
    it "names each dependency it keeps by its formula's full name, and prunes by `action` only without a block" do
      tap = Tap.fetch("user", "tap")
      %w[bar opt].each { |name| stub_formula_loader(plain_formula(name, tap:), name) }
      foo = formula("foo", tap:) do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/foo-1.0.tgz"
        depends_on "bar"
        depends_on "opt" => :optional
      end
      expect([foo.recursive_dependencies.map(&:name), foo.recursive_dependencies { nil }.map(&:name)])
        .to eq([%w[user/tap/bar], %w[user/tap/bar user/tap/opt]])
    end
  end

  # The action brew's `command` asks to confirm, with the formulae `named`
  # given to it, or `nil` if it goes on unasked, where
  # `Install.formulae_ask_prompt_needed?` says `needed`.
  def asked(command, named, needed:)
    allow(command.args.named).to receive_messages(to_formulae_and_casks:                 named,
                                                  to_formulae_and_casks_and_unavailable: named)
    allow(Homebrew::Install).to receive_messages(perform_preinstall_checks_once: nil,
                                                 formulae_ask_prompt_needed?:    needed)
    allow(Homebrew::Cleanup).to receive(:periodic_clean!)
    allow(Homebrew::Ask).to receive(:confirm?) { |action:| throw :asked, action }
    # Where brew goes on to install without asking.
    allow(Homebrew::Upgrade).to receive(:dependent_formula_installers) { throw :asked, nil }
    catch(:asked) do
      command.run
      nil
    end
  end

  describe "`brew reinstall`" do
    it "has no `--dry-run`, so `brew reinstall-timed` adds its own and prints brew's plan in-process" do
      options = Timed::Command.builtin("reinstall").parser.processed_options.flat_map { |short, long| [short, long] }
      expect(options & %w[-n --dry-run]).to eq([])
    end

    # `ReinstallTimed#run`, which loads the names it is given as
    # `brew reinstall` does.
    it "loads the names it is given through their installed kegs" do
      # `Reinstall` is brew's command, not a typo of `ReinstallTimed`.
      cmd = Homebrew::Cmd::Reinstall.new(%w[foo]) # rubocop:disable Lint/NameTypo
      allow(cmd.args.named).to receive(:to_formulae_and_casks_and_unavailable) { |**options| throw :loaded, options }
      expect(catch(:loaded) { cmd.run }).to eq(method: :resolve)
    end

    # `ReinstallTimed#reinstall`, which asks, by
    # `Install.formulae_ask_prompt_needed?`, after printing brew's plan with
    # `Install.ask_formulae(action: "reinstallation", prompt: false)`, unless
    # `--no-ask`, even when it reinstalls no formula.
    it "asks by `Install.formulae_ask_prompt_needed?`, through `Install.ask_formulae`, unless `--no-ask`, but " \
       "never when it reinstalls no formula, where `brew reinstall-timed` asks anyway" do
      foo, pinned = %w[foo pinned].map { |name| plain_formula(name) }
      allow(pinned).to receive(:pinned?).and_return(true)
      runs = { "needed" => [[], [foo], true], "not needed" => [[], [foo], false],
               "--no-ask" => [["--no-ask"], [foo], true], "pinned only" => [[], [pinned], true] }
      outcomes = runs.transform_values do |argv, named, needed|
        # `Reinstall` is brew's command, not a typo of `ReinstallTimed`.
        asked(Homebrew::Cmd::Reinstall.new([*argv, *named.map(&:name)]), named, needed:) # rubocop:disable Lint/NameTypo
      end
      expect(outcomes).to eq("needed" => "reinstallation", "not needed" => nil, "--no-ask" => nil,
                             "pinned only" => nil)
    end

    # `Timed::Receipts.receipt` and `.receipt_stat`, which
    # `Timed::Runner::REINSTALLED` reads for `ReinstallTimed#reinstall` before
    # and after (`Timed::Receipts.installed_since?`) from `opt`.
    it "reinstalls the keg in `opt`, linking the new one there, whose receipt `Timed::Receipts.receipt_stat` reads" do
      foo = plain_formula("foo")
      old = installed_keg("foo", "0.9", links: [HOMEBREW_PREFIX/"opt"])
      # A newer keg, outside `opt`.
      installed_keg("foo", "1.1", links: [])
      new = installed_keg("foo", "1.0", links: [])
      reinstalled = Homebrew::Reinstall.build_install_context(foo, flags: []).keg.to_s
      opt = [true, false].to_h do |link_keg|
        foo.opt_prefix.unlink
        FileUtils.ln_s old, foo.opt_prefix
        FormulaInstaller.new(foo, link_keg:).link(Keg.new(new))
        [link_keg, foo.opt_prefix.realpath]
      end
      expect([reinstalled, opt]).to eq([old.to_s, { true => new.realpath, false => new.realpath }])
    end

    # `ReinstallTimed#reinstall`'s `checked`, pinned named formulae included,
    # which it gives `Upgrade.dependants`, and its `dependents`, which leave
    # out the named formulae, which `Timed::Command.after` upgrades.
    it "checks the outdated dependents of each named formula, pinned ones it refuses too, even when it reinstalls " \
       "none, and upgrades those not named, as `brew reinstall-timed` does" do
      named, other = %w[named other].map { |name| plain_formula(name) }
      allow(named).to receive(:pinned?).and_return(true)
      allow(Homebrew::Install).to receive(:perform_preinstall_checks_once)
      allow(Homebrew::Upgrade).to receive(:dependants) { |formulae, **| throw :checked, formulae.map(&:name) }
      # `Reinstall` is brew's command, not a typo of `ReinstallTimed`.
      cmd = Homebrew::Cmd::Reinstall.new(%w[--no-ask named]) # rubocop:disable Lint/NameTypo
      allow(cmd.args.named).to receive(:to_formulae_and_casks_and_unavailable).and_return([named])
      checked = catch(:checked) { cmd.run }
      dependents = Homebrew::Upgrade::Dependents.new(upgradeable: [named, other], pinned: [], skipped: [])
      upgraded = Homebrew::Upgrade.dependent_formula_installers(dependents, [named], flags: [])
      expect([checked, upgraded.map { |installer| installer.formula.name }]).to eq([%w[named], %w[other]])
    end

    # `Timed::Runner.run`'s `stops_at_failure`, which `ReinstallTimed#reinstall`
    # passes, and which `InstallTimed#run` and `UpgradeTimed#run` don't.
    it "stops at a failed build, where `brew install` and `brew upgrade` carry on" do
      foo, bar = %w[foo bar].map { |name| plain_formula(name) }
      attempted = { "reinstall" => [], "install" => [], "upgrade" => [] }
      attempt = lambda do |command, formula|
        attempted[command] << formula.name
        raise BuildError.new(nil, "make", [], {}) if formula == foo
      end
      allow(Homebrew::Install).to receive(:perform_preinstall_checks_once)
      allow(Homebrew::Install).to receive(:enqueue_formulae) { |installers, **| installers }
      allow(Homebrew::Reinstall).to receive(:reinstall_formula) do |context|
        attempt.call("reinstall", context.formula)
      end
      # `Reinstall` is brew's command, not a typo of `ReinstallTimed`.
      cmd = Homebrew::Cmd::Reinstall.new(%w[--formula --no-ask foo bar]) # rubocop:disable Lint/NameTypo
      allow(cmd.args.named).to receive(:to_formulae_and_casks_and_unavailable).and_return([foo, bar])
      begin
        cmd.run
      rescue BuildError
        # Brew's global handler reports it.
        nil
      end
      installers = [foo, bar].map { |formula| FormulaInstaller.new(formula) }
      allow(Homebrew::Install).to receive(:install_formula) do |installer, upgrade:|
        attempt.call(upgrade ? "upgrade" : "install", installer.formula)
      end
      Homebrew::Install.install_formulae(installers, cleanup: false)
      Homebrew::Upgrade.upgrade_formulae(installers, fetch: false, cleanup: false)
      expect(attempted).to eq("reinstall" => %w[foo], "install" => %w[foo bar], "upgrade" => %w[foo bar])
    end
  end

  # Brew's `brew install argv`, or this tap's with `timed`, given the
  # formulae `named`, with the developer tools and without brew's
  # preinstall checks.
  def install_command(argv, named, timed: false)
    allow(Timed::Command).to receive(:auto_update)
    allow(Homebrew::Install).to receive(:perform_preinstall_checks_once)
    allow(DevelopmentTools).to receive(:installed?).and_return(true)
    # Keeps the support tier a source build notes out of the run's exit.
    allow(Homebrew::Diagnostic).to receive(:support_tiers).and_return([])
    command = if timed
      Homebrew::Cmd::InstallTimed.new(argv)
    else
      # RuboCop's project index only sees this tap, so it takes brew's
      # `InstallCmd` for a typo of `InstallTimed`.
      Homebrew::Cmd::InstallCmd.new(argv) # rubocop:disable Lint/NameTypo
    end
    allow(command.args.named).to receive(:to_formulae_and_casks).and_return(named)
    command
  end

  # The options `command` gives each of `calls` (`[module, method]`) as it
  # runs, which stops at the last of them.
  def options_given(command, calls)
    given = {}
    calls.each do |owner, name|
      allow(owner).to receive(name).and_wrap_original do |original, *arguments, **options|
        given[name] = options
        throw :given if name == calls.last&.last
        original.call(*arguments, **options)
      end
    end
    catch(:given) { command.run }
    given
  end

  # What the block prints to stdout.
  def stdout_of(&block)
    printed = T.let(nil, T.nilable(String))
    expect(&block).to output(satisfy { |text| printed = text }).to_stdout
    printed
  end

  describe "`brew install`" do
    # `Timed::Command.auto_update`, which `InstallTimed#run` and
    # `UpgradeTimed#run` call, and `ReinstallTimed#run` doesn't.
    it "auto-updates first, as `brew upgrade` does, but `brew reinstall` doesn't" do
      script = <<~SH
        brew() { echo "brew $*"; }
        source "#{HOMEBREW_LIBRARY_PATH}/utils/auto-update.sh"
        setup-auto-update
        auto-update
      SH
      updates = %w[install upgrade reinstall].to_h do |command|
        env = { "PATH" => ENV.fetch("PATH"), "HOMEBREW_REPOSITORY" => mktmpdir.to_s, "HOMEBREW_COMMAND" => command }
        [command, Open3.capture2(env, "/bin/bash", "-c", script, unsetenv_others: true).first]
      end
      update = "brew update --auto-update\n"
      expect(updates).to eq("install" => update, "upgrade" => update, "reinstall" => "")
    end

    # `InstallTimed#run`, which installs the taps of the names it is given,
    # then loads them all as `brew install` does, before anything else.
    it "installs the taps of the names it is given, then loads every name before it installs anything" do
      steps = []
      allow_any_instance_of(Tap).to receive(:ensure_installed!) { |tap| steps << tap.name }
      command = install_command(%w[user/tap/foo bar], [])
      allow(command.args.named).to receive(:to_formulae_and_casks) { |**options| throw :loaded, steps << options }
      expect(catch(:loaded) { command.run }).to eq(["user/tap", { method: :bottle, warn: false }])
    end

    # `InstallTimed#run`, which asks as brew does, by
    # `Install.formulae_ask_prompt_needed?`, unless `--no-ask` or `--dry-run`,
    # and gives `Upgrade.dependants` the `ask:` brew gives it.
    it "asks by `Install.formulae_ask_prompt_needed?`, through `Install.ask_formulae`, unless `--no-ask` or " \
       "`--dry-run`" do
      foo = plain_formula("foo")
      checked = []
      allow(Homebrew::Upgrade).to receive(:dependants).and_wrap_original do |original, formulae, **options|
        checked << options.fetch(:ask)
        original.call(formulae, **options)
      end
      runs = { "needed" => [[], true], "not needed" => [[], false], "--no-ask" => [["--no-ask"], true],
               "--dry-run" => [["--dry-run"], true] }
      outcomes = runs.transform_values do |argv, needed|
        asked(install_command([*argv, "foo"], [foo]), [foo], needed:)
      end
      expect([outcomes, checked])
        .to eq([{ "needed" => "installation", "not needed" => nil, "--no-ask" => nil, "--dry-run" => nil },
                [true, true, false, false]])
    end

    # `build_from_source_formulae`, which says which formulae pour: in
    # `UpgradeTimed#installer`'s installers, and, through
    # `Timed::Command.installer_options`, in the installers, dependents
    # checks and plans of `InstallTimed#run`, `ReinstallTimed#installer` and
    # `#reinstall`, `UpgradeTimed#dependants` and
    # `Timed::Command.dependents_call`; and `Timed::Command::DEPENDENT_FLAGS`,
    # which leaves `--build-from-source` out of the dependency batches.
    it "builds every named formula from source with `--build-from-source`, `--HEAD` or `--build-bottle`" do
      stub_formula_loader(plain_formula("foo", tap: Tap.fetch("user", "tap")), "foo")
      from_source = [[], %w[--build-from-source], %w[--HEAD], %w[--build-bottle]].to_h do |flags|
        [flags, Timed::Command.builtin("install").parser.parse([*flags, "foo"]).build_from_source_formulae]
      end
      expect(from_source).to eq([] => [], %w[--build-from-source] => %w[user/tap/foo],
                                %w[--HEAD] => %w[user/tap/foo], %w[--build-bottle] => %w[user/tap/foo])
    end

    # `InstallTimed#run`, which stops where `brew install` does, before
    # `Install.install_formula?` rewrites any receipt.
    it "stops before it checks any formula without build tools for a source build, or with `--env`" do
      # `--HEAD` with each of the other two (which conflict), given reversed so
      # the error shows the order brew lists them in.
      flag_pairs = [%w[--HEAD --build-bottle], %w[--HEAD --build-from-source]]
      outcomes = [[], *flag_pairs.map(&:reverse), %w[--env=std]].to_h do |argv|
        command = install_command([*argv, "foo"], [plain_formula("foo")])
        allow(DevelopmentTools).to receive(:installed?).and_return(false)
        allow(Homebrew::Install).to receive(:install_formula?) { throw :checked, "checked" }
        outcome = catch(:checked) do
          command.run
        rescue BuildFlagsError, MethodDeprecatedError => e
          e.message
        end
        [argv, outcome]
      end
      raised = flag_pairs.to_h { |flags| [flags.reverse, BuildFlagsError.new(flags, bottled: false).message] }
      expect(outcomes)
        .to match([] => "checked", **raised, %w[--env=std] => a_string_including("`brew install --env` is disabled"))
    end

    # `InstallTimed#run`, which prints brew's plan with
    # `Install.ask_formulae(prompt: false)`, given the installers
    # `Install.formula_installers(dry_run: true)` makes.
    it "prints with `--dry-run` what `Install.ask_formulae` prints, given the installers it makes" do
      stub_formula_loader(plain_formula("bar"), "bar", call_original: true)
      foo = formula("foo") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/foo-1.0.tgz"
        depends_on "bar"
      end
      # A formula brew would migrate, which it says it would.
      allow(Migrator).to receive(:oldnames_needing_migration).and_return(["old-foo"])
      allow(Homebrew::Cleanup).to receive(:periodic_clean!)
      none = Homebrew::Upgrade::Dependents.new(upgradeable: [], pinned: [], skipped: [])
      brew = stdout_of { install_command(%w[--dry-run foo], [foo]).run }
      ours = stdout_of do
        installers = Homebrew::Install.formula_installers([foo], dry_run: true)
        Homebrew::Install.ask_formulae(installers, none, prompt: false)
      end
      expect([ours, %w[old-foo bar].all? { |name| brew.include?(name) }]).to eq([brew, true])
    end

    # `InstallTimed#run`'s `Install.select_formula_installers` call, which
    # leaves out a formula `FormulaInstaller#prelude`'s checks stop, as
    # `brew install --yes` does.
    it "leaves out a formula it can't install with an error and installs the rest, under `--yes`" do
      errors = { "cannot" => CannotInstallFormulaError.new("cannot"), "broken" => RuntimeError.new("broken") }
      installers = %w[cannot broken fine].map do |name|
        installer = FormulaInstaller.new(plain_formula(name))
        allow(installer).to receive_messages(prelude_fetch: nil, enqueue_fetch: nil)
        allow(installer).to receive(:prelude) do
          error = errors[name]
          raise error if error
        end
        installer
      end
      queue = Homebrew::DownloadQueue.new
      kept = Homebrew::Install.enqueue_formulae(installers, download_queue: queue)
      queue.shutdown
      expect([kept.map { |installer| installer.formula.name }, Homebrew.failed?]).to eq([%w[fine], true])
    end
  end

  describe "`Install.install_formula?`" do
    # `InstallTimed#run`'s `Install.install_formula?` call.
    it "is what `brew install` checks each named formula with, with the options `brew install-timed` gives it" do
      argv = %w[--force --skip-link --overwrite --as-dependency foo]
      given = [false, true].map do |timed|
        command = install_command(argv, [plain_formula("foo")], timed:)
        options_given(command, [[Homebrew::Install, :install_formula?]])
      end
      expect(given.last).to eq(given.first)
    end

    it "installs a missing formula, marks an installed one as installed on request, dropping keys brew doesn't " \
       "know, and stops at a HEAD-only formula without `head`" do
      missing = formula("missing") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/missing-2.0.tgz"
      end
      current = formula("current") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/current-2.0.tgz"
      end
      keg = HOMEBREW_CELLAR/"current/2.0"
      (keg/"bin").mkpath
      (keg/AbstractTab::FILENAME).write(JSON.generate("installed_on_request" => false, "build_times" => {}))
      [HOMEBREW_PREFIX/"opt", HOMEBREW_LINKED_KEGS].each do |dir|
        dir.mkpath
        FileUtils.ln_s keg, dir/"current"
      end
      head_only = formula("headonly") do
        T.bind(self, T.class_of(Formula))
        head "https://brew.sh/headonly.git"
      end
      stopped = begin
        Homebrew::Install.install_formula?(head_only)
      rescue SystemExit
        :stopped
      end
      expect([Homebrew::Install.install_formula?(missing), Homebrew::Install.install_formula?(current),
              JSON.parse((keg/AbstractTab::FILENAME).read).slice("installed_on_request", "build_times"), stopped])
        .to eq([true, false, { "installed_on_request" => true }, :stopped])
    end
  end

  describe "`FormulaInstaller`'s checks before it installs" do
    # The methods `FormulaInstaller` and brew's OS prepends to it define, but
    # predicates and `formula`, that the block's call on `installer` calls on
    # it itself, each once.
    def direct_calls(installer, &block)
      calls = []
      stack = []
      trace = TracePoint.new(:call, :return) do |point|
        next unless point.self.equal?(installer)
        next stack.pop if point.event == :return

        # Sorbet's runtime wraps a method with a signature in one that calls
        # it, so each call is one or two frames.
        # By the name called: an earlier `allow_any_instance_of` leaves the
        # method's body under an alias.
        calls << point.callee_id if stack.uniq.length == 1 && stack.last != point.callee_id
        stack << point.callee_id
      end
      trace.enable(&block)
      own = [*FormulaInstaller.ancestors.take_while { |ancestor| ancestor != FormulaInstaller }, FormulaInstaller]
      calls.uniq.select { |name| own.include?(FormulaInstaller.instance_method(name).owner) }
           .reject { |name| name.end_with?("?") || name == :formula }
    end

    it "are, in `prelude_fetch`, even with `metadata_only`, a warning for a deprecated formula, and for a " \
       "disabled one with `force`, which without it raises `CannotInstallFormulaError`" do
      deprecated = formula("deprecated") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/deprecated-1.0.tgz"
        deprecate! date: "2020-01-01", because: :unmaintained
      end
      disabled = formula("disabled") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/disabled-1.0.tgz"
        disable! date: "2020-01-01", because: :unmaintained
      end
      check = ->(checked, force) { FormulaInstaller.new(checked, force:).prelude_fetch(metadata_only: true) }
      message = ->(checked) { "#{checked.full_name} has been #{DeprecateDisable.message(checked)}" }
      aggregate_failures do
        expect { check.call(deprecated, false) }.to output("Warning: #{message.call(deprecated)}\n").to_stderr
        expect { check.call(disabled, true) }.to output("Warning: #{message.call(disabled)}\n").to_stderr
        expect { check.call(disabled, false) }.to raise_error(CannotInstallFormulaError, message.call(disabled))
      end
    end

    # `InstallTimed#run`'s `Install.prelude_fetch_formulae(metadata_only:
    # true)` call, which leaves out a forbidden formula and fetches the bottle
    # manifests of pours, but no bottles.
    it "queue, in `prelude_fetch`, after the forbidden checks, a pour's bottle manifest, and only without " \
       "`metadata_only` its bottle" do
      foo = formula("foo") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/foo-1.0.tgz"
        TimedBottleHelper.bottle(self)
      end
      queued = lambda do |metadata_only|
        queue = Homebrew::DownloadQueue.new
        kinds = []
        allow(queue).to receive(:enqueue) { |download, **| kinds << download.class }
        begin
          FormulaInstaller.new(foo, download_queue: queue).prelude_fetch(metadata_only:)
        rescue CannotInstallFormulaError
          kinds << CannotInstallFormulaError
        end
        queue.shutdown
        # Only these, as brew may queue other downloads too.
        kinds & [Resource::BottleManifest, Bottle, CannotInstallFormulaError]
      end
      outcomes = { "metadata only" => queued.call(true), "all" => queued.call(false) }
      ENV["HOMEBREW_FORBIDDEN_FORMULAE"] = "foo"
      outcomes["forbidden"] = queued.call(false)
      expect(outcomes).to match("metadata only" => [Resource::BottleManifest],
                                "all"           => contain_exactly(Resource::BottleManifest, Bottle),
                                "forbidden"     => [CannotInstallFormulaError])
    end

    # `InstallTimed#run`'s `Install.select_formula_installers` call, which
    # makes `FormulaInstaller#prelude`'s checks, in its own order, but not its
    # downloads, to leave out what brew would.
    it "are, in `prelude`, besides its downloads, reading the bottle manifest and checking dependencies, " \
       "licence, tap, formula and sanity" do
      # Where brew downloads the dependencies there, not later.
      ENV["HOMEBREW_DOWNLOAD_CONCURRENCY"] = "1"
      installer = FormulaInstaller.new(plain_formula("foo"))
      expect(direct_calls(installer) { installer.prelude })
        .to contain_exactly(:prelude_fetch, :determine_bottle_tab_attributes, :verify_deps_exist,
                            :forbidden_license_check, :forbidden_tap_check, :forbidden_formula_check,
                            :check_install_sanity, :install_fetch_deps)
    end

    # `InstallTimed#run`, which takes the dependencies brew installs from
    # `FormulaInstaller#expand_dependencies` once the bottle manifests are
    # read, as brew works them out again as it installs.
    it "works out the dependencies, in `compute_dependencies`, from the bottle manifest when pouring, and again, " \
       "uncached, as it installs" do
      installer = FormulaInstaller.new(plain_formula("foo"))
      steps = []
      allow(DevelopmentTools).to receive(:installed?).and_return(true)
      allow(installer).to receive_messages(pour_bottle?: true, lock: nil)
      allow(installer).to receive(:fetch_bottle_tab) { steps << :manifest }
      # Brew's first plan, then what it finds as it installs.
      expansions = [[], [Dependency.new("bar")]]
      allow(installer).to receive(:expand_dependencies) do
        steps << :expanded
        expansions.shift
      end
      installer.compute_dependencies
      allow(installer).to receive(:install_dependencies) { |deps| throw :installing, deps.map(&:name) }
      installing = catch(:installing) { installer.install }
      expect([steps.first(2), installing]).to eq([[:manifest, :expanded], %w[bar]])
    end

    # `InstallTimed#run`, which batches no dependencies with `--build-bottle`
    # or without the developer tools.
    it "check, before installing any dependency, that each has a bottle, with `--build-bottle` or a pour " \
       "without the developer tools, so `brew install-timed` batches none then" do
      stub_formula_loader(plain_formula("bar"), "bar", call_original: true)
      allow(Homebrew::Install).to receive(:perform_build_from_source_checks)
      runs = { "--build-bottle" => [true, false, true], "a pour without the tools" => [false, true, false],
               "a pour" => [false, true, true] }
      outcomes = runs.transform_values do |build_bottle, pour, tools|
        allow(DevelopmentTools).to receive(:installed?).and_return(tools)
        installer = FormulaInstaller.new(plain_formula("foo"), build_bottle:)
        allow(installer).to receive_messages(pour_bottle?: pour, lock: nil,
                                             compute_dependencies: [Dependency.new("bar")])
        allow(installer).to receive(:install_dependencies) { throw :installing, "installs" }
        catch(:installing) do
          installer.install
        rescue UnbottledError
          "unbottled"
        end
      end
      expect(outcomes).to eq("--build-bottle" => "unbottled", "a pour without the tools" => "unbottled",
                             "a pour" => "installs")
    end
  end

  describe "`FormulaInstaller#install_dependency`" do
    # A formula `bar` at 2.0, with the options `with-x` and `with-y`, whose
    # 1.0 is installed and linked, with the receipt `receipt`.
    def outdated_bar(receipt)
      installed_keg("bar", "1.0", receipt:)
      formula("bar") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/bar-2.0.tgz"
        option "with-x"
        option "with-y"
      end
    end

    # The installers `FormulaInstaller#install_dependency` makes for
    # `dependencies` (each a `Dependency` and its formula) of a formula
    # installed with `options`, which go no further.
    def dependency_installers(dependencies, **options)
      made = []
      allow_any_instance_of(FormulaInstaller).to receive(:prelude) { |installer| made << installer }
      allow_any_instance_of(FormulaInstaller).to receive_messages(install: nil, finish: nil)
      parent = FormulaInstaller.new(plain_formula("parent"), **options)
      dependencies.each { |dependency, formula| parent.install_dependency(dependency, formula) }
      made
    end

    # `InstallTimed#run`'s dependency batches: `brew install --as-dependency`
    # for a missing dependency, and `brew upgrade` for an outdated one, which
    # keeps whether it was installed on request, even with
    # `HOMEBREW_NO_INSTALL_UPGRADE`.
    it "upgrades an outdated dependency, keeping whether it was installed on request, and installs a missing one " \
       "as a dependency, even with `HOMEBREW_NO_INSTALL_UPGRADE`, which `brew upgrade` never reads" do
      ENV["HOMEBREW_NO_INSTALL_UPGRADE"] = "1"
      bar = outdated_bar("installed_on_request" => true)
      made = dependency_installers([[Dependency.new("bar"), bar], [Dependency.new("baz"), plain_formula("baz")]])
      # `UpgradeCmd` is brew's command, not a typo of `UpgradeTimed`.
      cmd = Homebrew::Cmd::UpgradeCmd.new(%w[bar]) # rubocop:disable Lint/NameTypo
      allow(Homebrew::Install).to receive(:perform_preinstall_checks_once)
      allow(Homebrew::Upgrade).to receive_messages(
        formula_installers: [instance_double(FormulaInstaller)],
        dependants:         Homebrew::Upgrade::Dependents.new(upgradeable: [], pinned: [], skipped: []),
      )
      upgraded = cmd.formulae_upgrade_context([bar], show_upgrade_summary: false)&.formulae_to_install
      expect([made.map { |installer| [installer.formula.name, installer.installed_on_request?] }, upgraded])
        .to eq([[["bar", true], ["baz", false]], [bar]])
    end

    # `InstallTimed#run`, which leaves to brew an outdated dependency
    # installed from another tap, or through an alias whose target has
    # changed, checking with `Formulary.resolve`, which loads a name as
    # `brew upgrade` does, and `UpgradeTimed#named_items`, which loads the
    # names it is given as `brew upgrade` does.
    it "is upgraded by `brew upgrade` as loaded through its installed keg" do
      # `UpgradeCmd` is brew's command, not a typo of `UpgradeTimed`.
      cmd = Homebrew::Cmd::UpgradeCmd.new(%w[bar]) # rubocop:disable Lint/NameTypo
      allow(cmd.args.named).to receive(:to_formulae_and_casks_and_unavailable) { |**options| throw :loaded, options }
      expect(catch(:loaded) { cmd.run }).to eq(method: :resolve)
    end

    # `InstallTimed#run`, which gives its dependency batches
    # `HOMEBREW_NO_INSTALL_CLEANUP`, as brew cleans up only the formulae it
    # is given.
    it "is cleaned up by neither `brew install` nor `brew upgrade` with `HOMEBREW_NO_INSTALL_CLEANUP`, as " \
       "`brew install-timed` runs its dependency batches" do
      foo = formula("foo") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/foo-2.0.tgz"
      end
      old = installed_keg("foo", "1.0", links: [])
      installed_keg("foo", "2.0")
      allow(Homebrew::Cleanup).to receive(:periodic_clean_due?).and_return(true)
      ENV["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
      Homebrew::Cleanup.install_formula_clean!(foo)
      Homebrew::Cleanup.install_clean!(formulae: [foo])
      Homebrew::Cleanup.periodic_clean!
      kept = old.exist?
      ENV.delete("HOMEBREW_NO_INSTALL_CLEANUP")
      Homebrew::Cleanup.install_formula_clean!(foo)
      expect([kept, old.exist?]).to eq([true, false])
    end

    # `InstallTimed#run`'s dependency batches, which get
    # `Timed::Command.dependent_flags` but `--force-bottle`, and none with
    # `--debug-symbols`, and its `all_installers`, which give a dependency
    # the options in its receipt, leaving one with options of its own to brew.
    it "gives the dependency's installer its receipt's options and the dependency's, and of the command's " \
       "options only these, which `brew install-timed` gives its dependency batches, or with `debug_symbols`, " \
       "batches none" do
      switches = [:build_bottle, :debug, :debug_symbols, :force, :force_bottle, :git, :ignore_deps, :interactive,
                  :keep_tmp, :only_deps, :overwrite, :quiet, :skip_link, :skip_post_install, :verbose]
      bar = outdated_bar("used_options" => ["--with-x"])
      options = switches.to_h { |switch| [switch, true] }
      made = dependency_installers([[Dependency.new("bar", ["with-y"]), bar]], **options)
      given = made.map do |installer|
        [installer.options.as_flags.sort, switches.select { |switch| installer.public_send(:"#{switch}?") }]
      end
      expect(given).to eq([[%w[--with-x --with-y], [:debug, :debug_symbols, :force, :keep_tmp, :quiet, :verbose]]])
    end

    # `Timed::Runner.run`'s `apart`, which `InstallTimed#run` and
    # `UpgradeTimed#run` pass, so no call has two formulae that need a
    # dependency that may fail.
    it "carries on, within one call, past a dependency it already tried for another formula, even if that " \
       "failed, so `brew install-timed` and `brew upgrade-timed` never give one call two formulae that need it" do
      bar = plain_formula("bar")
      built = []
      allow(DevelopmentTools).to receive(:installed?).and_return(true)
      allow(Homebrew::Install).to receive(:perform_build_from_source_checks)
      allow_any_instance_of(FormulaInstaller).to receive(:lock)
      allow_any_instance_of(FormulaInstaller).to receive(:build) do |installer|
        built << installer.formula.name
        raise BuildError.new(nil, "make", [], {})
      end
      first = FormulaInstaller.new(plain_formula("first"))
      second = FormulaInstaller.new(plain_formula("second"))
      failed = begin
        first.install_dependency(Dependency.new("bar"), bar)
      rescue BuildError
        "failed"
      end
      second.install_dependency(Dependency.new("bar"), bar)
      expect([failed, built]).to eq(["failed", %w[bar]])
    end

    it "can't be given `--debug-symbols` on its own by `brew install`, which needs `--build-from-source` for it" do
      expect { Timed::Command.builtin("install").parser.parse(%w[--debug-symbols foo]) }
        .to raise_error(Homebrew::CLI::OptionConstraintError,
                        /`--debug-symbols` cannot be passed without `--build-from-source`/)
    end
  end

  # `UpgradeTimed#installer`, which builds a bottle again for a keg built as
  # one, and `InstallTimed#run`, which leaves to brew an outdated dependency
  # built as a bottle, or unlinked where brew would link a new one, and
  # upgrades the rest with `brew upgrade`, which keeps whether it was
  # installed on request.
  describe "`brew upgrade`'s installer for a formula" do
    it "keeps whether the keg linked into `opt` was linked and installed on request, and builds a bottle again " \
       "if it was built as one, but takes one without such a keg as installed on request" do
      installed_keg("linked", "0.9", receipt: { "installed_on_request" => false, "built_as_bottle" => true })
      installed_keg("unlinked", "0.9", receipt: { "installed_on_request" => true }, links: [HOMEBREW_PREFIX/"opt"])
      formulae = %w[linked unlinked missing].map { |name| plain_formula(name) }
      made = Homebrew::Upgrade.formula_installers(formulae, flags: []).to_h do |installer|
        [installer.formula.name, [installer.link_keg, installer.installed_on_request?, installer.build_bottle?]]
      end
      expect(made).to eq("linked"  => [true, false, true], "unlinked" => [false, true, false],
                         "missing" => [true, true, false])
    end
  end

  describe "the order `brew install` works in" do
    # `InstallTimed#run`, which warns about `--ignore-dependencies` with
    # brew's text.
    it "warns about `--ignore-dependencies` as `brew install-timed` does" do
      warned = [false, true].map do |timed|
        command = install_command(%w[--ignore-dependencies foo], [], timed:)
        allow(command.args.named).to receive(:to_formulae_and_casks) { throw :loaded }
        printed = T.let(nil, T.nilable(String))
        expect { catch(:loaded) { command.run } }.to output(satisfy { |text| printed = text }).to_stderr
        printed
      end
      expect([warned.last, warned.first.to_s.include?("`--ignore-dependencies`")]).to eq([warned.first, true])
    end

    # `InstallTimed#run`, which reads the bottle manifests before it prints
    # its plan, so it prints and batches the dependencies brew works out from
    # them, and queues no download before it asks, leaving the downloads to
    # its batches.
    it "queues the bottle manifests and reads them before it prints and asks about its plan, then queues the " \
       "downloads and checks each formula with `prelude`" do
      steps = []
      command = install_command(%w[foo], [plain_formula("foo")])
      allow(Homebrew::Install).to receive(:prelude_fetch_formulae)
        .and_wrap_original do |original, installers, **options|
          steps << (options[:metadata_only] ? :queue_manifests : :queue_downloads)
          original.call(installers, **options)
        end
      allow(Homebrew::Install).to receive(:ask_formulae).and_wrap_original do |original, *arguments, **options|
        steps << :ask_formulae
        original.call(*arguments, **options)
      end
      allow_any_instance_of(Homebrew::DownloadQueue).to receive(:fetch).and_wrap_original do |original, **options|
        steps << :read_manifests if options[:only] == Resource::BottleManifest
        original.call(**options)
      end
      allow_any_instance_of(FormulaInstaller).to receive(:prelude) { throw :checked }
      catch(:checked) { command.run }
      expect(steps.uniq).to eq([:queue_manifests, :read_manifests, :ask_formulae, :queue_downloads])
    end

    it "stops a source build only without the developer tools, leaving the rest to each batch" do
      outcomes = [true, false].to_h do |developer_tools|
        [developer_tools, build_flags_error(["--build-from-source"], developer_tools:)]
      end
      expect(outcomes).to eq(true  => nil,
                             false => BuildFlagsError.new(["--build-from-source"], bottled: false).message)
    end

    it "stops `brew upgrade` and `brew reinstall` the same way, with the named formulae, before they do anything, " \
       "but `brew upgrade` not with only casks named" do
      allow(DevelopmentTools).to receive(:installed?).and_return(false)
      formulae = [true, false].map do |bottled|
        named = formula("timed-canary-#{bottled}") do
          T.bind(self, T.class_of(Formula))
          url "https://brew.sh/timed-canary-1.0.tgz"
        end
        allow(named).to receive(:bottled?).and_return(bottled)
        named
      end
      items = { "formulae" => formulae, "casks" => [Cask::Cask.new("timed-canary")] }
      # RuboCop's project index only sees this tap, so it takes brew's
      # `UpgradeCmd` and `Reinstall` for typos of `UpgradeTimed` and
      # `ReinstallTimed`.
      # rubocop:disable Lint/NameTypo
      commands = { "upgrade"   => ->(argv) { Homebrew::Cmd::UpgradeCmd.new(["--dry-run", *argv]) },
                   "reinstall" => ->(argv) { Homebrew::Cmd::Reinstall.new(argv) } }
      # rubocop:enable Lint/NameTypo
      outcomes = commands.keys.product(items.keys).to_h do |command, kind|
        run = commands.fetch(command).call(%w[--build-from-source timed-canary])
        allow(run.args.named).to receive(:to_formulae_and_casks_and_unavailable).and_return(items.fetch(kind))
        # Where `brew upgrade` goes on to the casks.
        allow(run).to receive(:upgrade_outdated_casks!) { throw :went_on, "went on" } if command == "upgrade"
        outcome = catch(:went_on) do
          run.run
          "done"
        rescue BuildFlagsError => e
          e.message
        end
        ["#{command} #{kind}", outcome]
      end
      error = BuildFlagsError.new(["--build-from-source"], bottled: false).message
      expect(outcomes).to eq("upgrade formulae"   => error, "upgrade casks"   => "went on",
                             "reinstall formulae" => error,
                             "reinstall casks"    => BuildFlagsError.new(["--build-from-source"]).message)
    end

    # `InstallTimed#run`'s calls of `Install.formula_installers`,
    # `Upgrade.dependants` and `Install.ask_formulae`, which add
    # `Timed::Command.installer_options`.
    it "gives its installers, dependents check and plan the options `brew install-timed` gives them" do
      calls = [[Homebrew::Install, :formula_installers], [Homebrew::Upgrade, :dependants],
               [Homebrew::Install, :ask_formulae]]
      keywords = [false, true].map do |timed|
        given = options_given(install_command(%w[foo], [plain_formula("foo")], timed:), calls)
        given.transform_values { |options| options.keys.sort - [:prompt] }
      end
      expect(keywords.last).to eq(keywords.first)
    end
  end

  describe "the order `brew upgrade` works in" do
    # `UpgradeTimed#installer`, which reads a pour's bottle manifest before
    # it works out the dependencies its plan prints and asks about.
    it "reads its installers' bottle manifests before it prints and asks about their dependencies" do
      # `UpgradeCmd` is brew's command, not a typo of `UpgradeTimed`.
      cmd = Homebrew::Cmd::UpgradeCmd.new(%w[foo]) # rubocop:disable Lint/NameTypo
      steps = []
      allow(cmd).to receive(:formula_outdated?).and_return(true)
      allow(Homebrew::Install).to receive(:perform_preinstall_checks_once)
      allow_any_instance_of(Homebrew::DownloadQueue).to receive(:fetch).and_wrap_original do |original, **options|
        steps << :read_manifests if options[:only] == Resource::BottleManifest
        original.call(**options)
      end
      allow_any_instance_of(FormulaInstaller).to receive(:determine_bottle_tab_attributes)
        .and_wrap_original do |original|
          steps << :read_bottle_attributes
          original.call
        end
      allow(Homebrew::Install).to receive(:formulae_ask_prompt_needed?) { throw :asking }
      catch(:asking) do
        cmd.upgrade_outdated_formulae!([plain_formula("foo")], dry_run: true, show_upgrade_summary: false)
      end
      expect(steps.uniq).to eq([:read_manifests, :read_bottle_attributes])
    end

    it "decides whether to ask only from the formulae that pass its dry-run, not one with an unsatisfied " \
       "requirement" do
      # `UpgradeCmd` is brew's command, not a typo of `UpgradeTimed`.
      # rubocop:disable Lint/NameTypo
      cmd = Homebrew::Cmd::UpgradeCmd.new(["--dry-run", "testball"])
      context = Homebrew::Cmd::UpgradeCmd::FormulaeUpgradeContext
      # rubocop:enable Lint/NameTypo
      formula = formula("testball") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/testball-0.2"
      end
      old_keg = HOMEBREW_CELLAR/"testball/0.1"
      old_keg.mkpath
      allow(formula).to receive_messages(optlinked?: true, opt_prefix: old_keg)
      installer = FormulaInstaller.new(formula)
      allow(installer).to receive(:compute_dependencies).and_raise(UnsatisfiedRequirements.new([]))
      allow(cmd).to receive(:formulae_upgrade_context).and_return(
        context.new(
          formulae_to_install: [formula],
          formulae_installer:  [installer],
          dependants:          Homebrew::Upgrade::Dependents.new(upgradeable: [], pinned: [], skipped: []),
        ),
      )
      expect(Homebrew::Install).to receive(:formulae_ask_prompt_needed?).with([], anything).and_return(false)
      expect { cmd.upgrade_outdated_formulae!([]) }.to output(/testball/).to_stderr
    end
  end

  describe "brew's check for dependents with broken linkage" do
    # What `Upgrade.upgrade_dependents` does once brew has installed `lib`,
    # from a tap, and given it the outdated dependents `filtered`, which its
    # bottle says the installed `lib` satisfies, and `kept`: the formulae it
    # upgrades, then each it reinstalls, and whether from source. Of the
    # installed dependents of `lib`, all broken but `fine`, `gone` has no
    # keg, `pinned` is pinned, `outdated` is outdated, `app` depends on
    # `base`, and `base` fails to build. Brew has also installed the core
    # formula `core`, whose installed dependent `core-dep` is broken.
    def after_install
      lib = plain_formula("lib", tap: Tap.fetch("user", "tap"))
      stub_formula_loader(lib)
      core = plain_formula("core", tap: CoreTap.instance)
      FormulaInstaller.installed << lib << core
      installed_keg("lib", "1.0")
      installed_keg("core-dep", "1.0")
      allow(core).to receive(:runtime_installed_formula_dependents).and_return([plain_formula("core-dep")])
      dependents = %w[app base fine gone outdated pinned zed].to_h { |name| [name, plain_formula(name)] }
      base = { "full_name" => "base", "version" => "1.0" }
      installed_keg("app", "1.0", receipt: { "homebrew_version" => "5.0.0", "runtime_dependencies" => [base] })
      %w[base fine outdated pinned zed].each { |name| installed_keg(name, "1.0") }
      allow(dependents.fetch("pinned")).to receive(:pinned?).and_return(true)
      allow(dependents.fetch("outdated")).to receive(:outdated?).and_return(true)
      allow(lib).to receive(:runtime_installed_formula_dependents).and_return(dependents.values)
      allow(LinkageChecker).to receive(:new) do |keg, **|
        instance_double(LinkageChecker, broken_library_linkage?: keg.name != "fine")
      end
      upgradeable = %w[filtered kept].map { |name| FormulaInstaller.new(plain_formula(name)) }
      allow(upgradeable.first).to receive(:bottle_tab_runtime_dependencies)
        .and_return(lib.full_name => { "version" => "1.0" })
      steps = []
      allow(Homebrew::Upgrade).to receive(:upgrade_formulae) do |installers, **|
        steps << [:upgraded, installers.map { |installer| installer.formula.name }]
        installers
      end
      allow(Homebrew::Install).to receive(:fetch_formulae) { |installers| installers }
      allow(Homebrew::Reinstall).to receive(:reinstall_formula) do |context|
        steps << [:reinstalled, context.formula.name, context.formula_installer.build_from_source?]
        raise BuildError.new(nil, "make", [], {}) if context.formula.name == "base"
      end
      dependents = Homebrew::Upgrade::Dependents.new(upgradeable: upgradeable.map(&:formula), pinned: [], skipped: [])
      Homebrew::Upgrade.upgrade_dependents(dependents, [lib], flags: [], prefetched_formula_installers: upgradeable)
      steps
    end

    # `Timed::Command.broken_dependents`, which copies the private
    # `Upgrade.check_broken_dependents`, and `.dependents_to_check`, which
    # `Timed::Command.linkage_call` gives it, and which, of the core pours,
    # checks only the dependents built from source, as brew checks none.
    it "finds them among the installed dependents, with a keg, of the non-core formulae it installed, by " \
       "`LinkageChecker`, as `Timed::Command.broken_dependents` does" do
      broken = after_install.filter_map { |step, name| name if step == :reinstalled }
      expect(broken.sort).to eq(%w[app base zed])
    end

    # `Timed::Command.depends_on`, which copies the private `Upgrade.depends_on`,
    # and which `Timed::Command.repairable` sorts by.
    it "orders them after those they depend on, otherwise by name, as `Timed::Command.depends_on` does" do
      expect(after_install.filter_map { |step, name| name if step == :reinstalled }).to eq(%w[base app zed])
    end

    # `Timed::Command.after`, which runs `Timed::Command.dependents_call`,
    # which leaves out the dependents the bottle filter does, then
    # `Timed::Command.linkage_call`, which reinstalls from source, carrying
    # on past a failed build, and leaves out pinned and outdated ones
    # (`Timed::Command.repairable`).
    it "checks those of the non-core formulae it installed after the bottle-filtered dependents, and reinstalls " \
       "them from source, dependencies first, unless outdated or pinned, carrying on past a failed build" do
      expect([after_install, Homebrew.failed?])
        .to eq([[[:upgraded, %w[kept]], [:reinstalled, "base", true], [:reinstalled, "app", true],
                 [:reinstalled, "zed", true]], true])
    end
  end

  # `InstallTimed#run`, which clears the support tiers noted in its process,
  # where brew notes them (e.g. for `--cc`), so its exit doesn't report what
  # each batch's `brew install` reports.
  it "reports the support tiers noted in the process as it exits, then forgets them, and `--cc` notes one",
     :aggregate_failures do
    tiers = Homebrew::Diagnostic.support_tiers
    saved = tiers.dup
    tiers.clear
    Homebrew::Install.check_cc_argv("gcc-9")
    noted = tiers.dup
    expect { Homebrew::Diagnostic.report_support_tier }.to output(/This is a Tier 3 configuration/).to_stderr
    exit_report = Open3.capture3(HOMEBREW_BREW_FILE.to_s, "ruby", "-e",
                                 'require "diagnostic"; Homebrew::Diagnostic.support_tiers << 3')[1]
    expect([exit_report.include?("This is a Tier 3 configuration"), noted, tiers]).to eq([true, [3], []])
  ensure
    tiers&.replace(saved || [])
  end

  # `Timed::Receipts.installed_since?`, which `Timed::Runner::REINSTALLED`
  # reads: a new receipt is a new file, and a failed reinstall leaves the old
  # one in place.
  it "writes each receipt as a new file, while a failed reinstall renames the old keg back, receipt and all" do
    receipt = installed_keg("foo", "1.0")/AbstractTab::FILENAME
    inode = receipt.stat.ino
    Tab.from_file(receipt.to_s).write
    rewritten = receipt.stat.ino != inode
    inode = receipt.stat.ino
    context = Homebrew::Reinstall.build_install_context(plain_formula("foo"), flags: [])
    allow(context.formula_installer).to receive(:install).and_raise(RuntimeError, "failed")
    begin
      Homebrew::Reinstall.reinstall_formula(context)
    rescue RuntimeError
      nil
    end
    expect([rewritten, receipt.stat.ino]).to eq([true, inode])
  end

  # `Timed::Receipts.installed_since?`, which reads the install time in the
  # receipt of a keg brew installed in the call.
  it "writes the install time into the receipt of every keg it builds or pours" do
    start = Time.now.to_i
    # Its source is never downloaded.
    built = formula("built") do
      T.bind(self, T.class_of(Formula))
      url "file:///dev/null"
      version "1.0"
    end
    # Where the test prefix is longer than the bottle's.
    ENV["HOMEBREW_NO_RELOCATE_BUILD_PREFIX"] = "1"
    poured = Formulary::FromBottleLoader.new(bottle_file.to_s).get_formula(:stable)
    FormulaInstaller.new(poured).pour
    times = [Tab.create(built).time, Tab.for_keg(Keg.new(poured.prefix)).time]
    expect(times.map { |time| time.to_i >= start }).to eq([true, true])
  end

  describe "the lines `Timed::Runner.parse` names formulae by" do
    # With a bottle, a resource and a patch, so every download brew names.
    let(:foo) do
      formula("foo", tap: Tap.fetch("user", "tap")) do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/foo-1.0.tgz"
        revision 1
        TimedBottleHelper.bottle(self)
        resource "res" do
          T.bind(self, Resource)
          url "https://brew.sh/res-1.0.tgz"
          sha256 "b" * 64
        end
        patch do
          T.bind(self, Resource::Patch)
          url "https://brew.sh/fix.patch"
          sha256 "c" * 64
        end
      end
    end

    def parsed(lines) = Timed::Runner.parse(lines.map { |line| ["#{line}\n", nil] }).keys

    # Fails a build step of `foo`, which prints `make: *** Error 1`, as
    # `Formula#system` does, and returns the error.
    def failed_build(foo)
      # Brew writes the host's configuration into the log after it prints the
      # log's end; that would ask for curl's version.
      allow(SystemConfig).to receive(:dump_verbose_config)
      foo.system "/bin/sh", "-c", "echo 'make: *** Error 1'; exit 1"
    rescue BuildError => e
      e
    end

    it "include the heading a tap formula's install starts with" do
      lines = []
      allow(foo).to receive(:ohai) { |title| lines << "==> #{title}" }
      foo.print_tap_action
      expect(parsed(lines)).to eq(%w[foo])
    end

    # `Timed::Runner::POURING` in `Parser#feed_line`, and so `Runner.run`'s
    # `begun`.
    it "include the bottle a formula pours, which is all an install with no dependencies to install names " \
       "before its summary" do
      installer = FormulaInstaller.new(foo)
      allow(installer).to receive_messages(compute_dependencies: [], lock: nil)
      # Stops the install where it extracts the bottle.
      allow_any_instance_of(Bottle).to receive(:stage) { throw :staging }
      lines = []
      allow($stdout).to receive(:puts) { |*printed| lines.concat(printed) }
      catch(:staging) { installer.install }
      expect(parsed(lines)).to eq(%w[foo])
    end

    # `Timed::Runner`'s `PROBLEM`, `LOG_START`, `Parser#log_file_lines` and
    # `BUILD_FAILED` (`Runner.stopped_at_build?`).
    it "include the log a failed build prints the end of, in a directory named after the formula, before brew " \
       "appends to its file" do
      header = "Last #{Homebrew::EnvConfig.fail_log_lines} lines from #{foo.logs}/01.sh.log:"
      # The end of the log is printed by another process.
      tail = satisfy("be read as a problem of foo's from the log's header to its last line") do |text|
        problems = Timed::Runner.parse(text.lines.map { |line| [line, nil] }).transform_values do |build|
          build["problems"]&.map { |problem| problem.lines(chomp: true).values_at(0, -1) }
        end
        problems == { "foo" => [[header, "make: *** Error 1"]] }
      end
      expect { failed_build(foo) }.to output(tail).to_stdout_from_any_process
    end

    # `Timed::Runner`'s `FETCH_FAILED` and `RESOURCE_FAILED` in
    # `Parser#feed_line`, and `UNNAMED_FETCH_FAILED` in `Runner.run`.
    it "name a failed download of a formula, its bottle or a resource after the formula, and of a patch or API " \
       "source only by file, which `Timed::Runner` relies on to tell a formula brew left out from one it never " \
       "got to" do
      # Brew downloads in parallel unless told not to, and only then prints
      # each failed download.
      ENV["HOMEBREW_DOWNLOAD_CONCURRENCY"] = "2"
      # Brew then names each download after its URL, as when it can't reach
      # the server.
      allow_any_instance_of(CurlDownloadStrategy).to receive(:curl_headers)
        .and_raise(ErrorDuringExecution.new(%w[curl], status: 6))
      allow_any_instance_of(Homebrew::RetryableDownload).to receive(:fetch).and_raise(RuntimeError, "offline")
      api_source = Homebrew::API::SourceDownload.new("https://brew.sh/foo.rb", Checksum.new("d" * 64), formula: foo)
      downloads = { "source" => foo.resource, "bottle" => foo.bottle, "resource" => foo.resources.first,
                    "patch" => foo.patchlist.first&.resource, "API source" => api_source }
      # By formula, the version read, if any, and how many failures are by
      # file only.
      read = downloads.transform_values do |download|
        queue = Homebrew::DownloadQueue.new
        queue.enqueue(download, stage: false) if download
        printed = StringIO.new
        allow($stderr).to receive(:puts) { |*lines| printed.puts(*lines) }
        begin
          queue.fetch
        ensure
          queue.shutdown
        end
        lines = printed.string.lines
        [Timed::Runner.parse(lines.map { |line| [line, nil] }).transform_values { |build| build["version"] },
         lines.grep(Timed::Runner::UNNAMED_FETCH_FAILED).length]
      end
      expect(read).to eq("source" => [{ "foo" => nil }, 0], "bottle" => [{ "foo" => "1.0_1" }, 0],
                         "resource" => [{ "foo" => nil }, 0], "patch" => [{}, 1], "API source" => [{}, 1])
    end

    it "include none from dependents brew rebuilds or upgrades after its heading, or a failed post-install",
       :aggregate_failures do
      # Brew prints a heading `DEPENDENTS` matches before it upgrades the
      # dependents of upgraded formulae, whether one or more, and another
      # before it checks for broken ones to rebuild: each before the work it
      # announces, which prints a marker here.
      markers = { upgrade_formulae: "<upgrading dependents>", check_broken_dependents: "<checking dependents>" }
      markers.each do |method, marker|
        allow(Homebrew::Upgrade).to receive(method) do
          # Into brew's output, which `output` captures below.
          puts marker # rubocop:disable RSpec/Output
          []
        end
      end
      run = lambda do |count|
        formulae = lambda do |prefix|
          Array.new(count) do |index|
            # Brew checks for broken dependents only of non-core formulae.
            formula("#{prefix}#{index}", tap: foo.tap) do
              T.bind(self, T.class_of(Formula))
              url "https://brew.sh/#{prefix}-1.0.tgz"
            end
          end
        end
        upgraded = formulae.call("up")
        dependents = formulae.call("dep")
        allow(FormulaInstaller).to receive(:installed).and_return(upgraded.to_set)
        deps = Homebrew::Upgrade::Dependents.new(upgradeable: dependents, pinned: [], skipped: [])
        installers = dependents.map { FormulaInstaller.new(it) }
        Homebrew::Upgrade.upgrade_dependents(deps, upgraded, flags: [], prefetched_formula_installers: installers)
      end
      [1, 2].each do |count|
        headings = satisfy("have each heading before its work for #{count} dependents") do |text|
          text.lines(chomp: true).filter_map do |line|
            Timed::Runner::DEPENDENTS.match?(line) ? :heading : markers.key(line)
          end == [:heading, :upgrade_formulae, :heading, :check_broken_dependents]
        end
        expect { run.call(count) }.to output(headings).to_stdout
      end
      # Brew's warning for a post-install that fails however it runs.
      installer = FormulaInstaller.new(foo)
      allow(installer).to receive(:post_install_formula_path).and_raise(RuntimeError)
      allow(installer).to receive(:puts)
      expect { installer.post_install }
        .to output(a_string_starting_with("#{Timed::Runner::POST_INSTALL_FAILED}\n")).to_stderr
    end

    # `Timed::Runner`'s `PROBLEM` and `BUILD_FAILED`
    # (`Runner.stopped_at_build?`).
    it "include the error ending a verbose build's failure" do
      allow(foo).to receive(:verbose?).and_return(true)
      # Brew's own checks then note no support tier for the run's exit, nor ask
      # GitHub for issues.
      allow(Homebrew::Diagnostic).to receive(:support_tiers).and_return([])
      ENV["HOMEBREW_NO_BUILD_ERROR_ISSUES"] = "1"
      # What it prints to both streams in one, as a batch reads them.
      output = StringIO.new
      [$stdout, $stderr].each { |stream| allow(stream).to receive(:puts) { |*lines| output.puts(*lines) } }
      failed_build(foo)&.dump(verbose: true)
      expect(parsed(output.string.lines(chomp: true))).to eq(%w[foo])
    end
  end

  it "follows a failed build's whole log with text `Timed::Runner.parse` keeps out of the formula's problems, " \
     "whatever the support tier, tap or provider, and with GitHub Actions annotations" do
    ENV["HOMEBREW_NO_BUILD_ERROR_ISSUES"] = "1"
    foo = formula("foo", tap: Tap.fetch("user", "tap")) do
      T.bind(self, T.class_of(Formula))
      url "https://brew.sh/foo-1.0.tgz"
    end
    allow(Homebrew::Diagnostic).to receive(:support_tiers).and_return([])
    # As on a Tier 1 host, which has somewhere to report issues.
    stub_const("OS::ISSUES_URL", "https://docs.brew.sh/Troubleshooting")
    # By whether it has its log file. With it, a warning of its own right
    # after a blank line, which only the file shows is part of the log;
    # without it, one not right after a blank line, so that brew's text must
    # end the log.
    header = "Last 15 lines from #{foo.logs}/01.make.log:"
    logs = { true  => [header, "2026-09-30 10:00:00 +0000", "make", "", "Warning: jobserver unavailable",
                       "make: *** Error 1"],
             false => [header, "2026-09-30 10:00:00 +0000", "", "make", "Warning: jobserver unavailable",
                       "make: *** Error 1"] }
    unsupported = OS::ThirdPartyHomebrew.new(tier: :unsupported)
    provider = OS::ThirdPartyHomebrew.new(issues_url: "https://example.com/issues")
    # Brew's own checks warn of the host's findings first, only those that
    # don't depend on this computer: a Tier 3 prefix, whose warning has a
    # blank line, and a third-party tool managing Homebrew, at its tier.
    checks = Homebrew::Diagnostic::Checks.new
    allow(Homebrew::Diagnostic::Checks).to receive(:new).and_return(checks)
    allow(checks).to receive(:build_error_checks).and_return(%w[check_homebrew_prefix check_for_third_party_homebrew])
    allow(BottleSpecification).to receive(:compatible_locations?).and_return(false)
    # The formula's tap, whether it was built with `--HEAD`, whether Homebrew
    # is in its default prefix and the third-party tool managing it, if any.
    cases = { "Tier 1, official tap" => [CoreTap.instance, false, true, nil], "Tier 1" => [foo.tap, false, true, nil],
              "Tier 3" => [foo.tap, false, false, nil], "unsupported" => [foo.tap, false, true, unsupported],
              "--HEAD" => [foo.tap, true, true, nil], "provider" => [foo.tap, false, true, provider] }
    file = foo.logs/"01.make.log"
    # Each with the log file as `Formula#system` leaves it, the log then a
    # blank line and the build's configuration, and without it; then each
    # again under GitHub Actions, where brew prints its warnings, such as the
    # host's findings, as annotations (never in its own specs).
    problems = [false, true].product(cases.keys, [true, false]).to_h do |annotated, name, with_file|
      if annotated
        ENV["GITHUB_ACTIONS"] = "true"
        ENV.delete("HOMEBREW_TESTS")
      end
      tap, head, default_prefix, third_party = cases.fetch(name)
      log = logs.fetch(with_file)
      if with_file
        file.dirname.mkpath
        file.write([*log.drop(1), "", "HOMEBREW_VERSION: 5.0.0", ""].join("\n"))
      else
        FileUtils.rm_f file
      end
      allow(Homebrew).to receive(:default_prefix?).and_return(default_prefix)
      allow(OS).to receive(:third_party_homebrew).and_return(third_party)
      allow(foo).to receive_messages(tap:, head?: head)
      error = BuildError.new(foo, "make", [], {})
      # What it prints to both streams in one, as a batch reads them.
      output = StringIO.new
      [error, $stderr].each { |stream| allow(stream).to receive(:puts) { |*lines| output.puts(*lines) } }
      error.dump
      parsed = Timed::Runner.parse([*log, *output.string.lines].map { |line| ["#{line.chomp}\n", nil] })
      file_note = ", with its log file" if with_file
      annotation_note = ", annotated" if annotated
      ["#{name}#{file_note}#{annotation_note}", parsed.dig("foo", "problems")]
    end
    expect(problems).to eq(problems.to_h do |key, _|
      [key, [logs.fetch(key.include?(", with its log file")).join("\n")]]
    end)
  end

  it "prints brew's warnings and errors under GitHub Actions as annotations, one line each, whose lines " \
     "`Timed::Runner` reads as those brew prints otherwise" do
    message = "foo 1.0 did not build: a::b\n100% done, not %0A\r\n\nend\n"
    printed = [false, true].to_h do |annotated|
      if annotated
        ENV["GITHUB_ACTIONS"] = "true"
        # Brew prints no annotations in its own specs.
        ENV.delete("HOMEBREW_TESTS")
      end
      output = StringIO.new
      allow($stderr).to receive(:puts) { |*lines| output.puts(*lines) }
      Utils::Output.opoo message
      Utils::Output.onoe message
      Utils::Output.ofail message
      [annotated, output.string.lines]
    end
    read = printed.transform_values { |lines| lines.flat_map { |line| Timed::Runner.plain_lines(line) } }
    expect([printed.fetch(true).map { |line| line[/\A::\w+::/] }, read.fetch(true)])
      .to eq([%w[::warning:: ::error:: ::error::], read.fetch(false)])
  end

  describe "`Tty`, which paints `brew build-times stats`, `histogram`, `runs` and `run`" do
    # It can be 0; `histogram` and `run` draw at least 40 columns whatever it is.
    it "gives the width of the terminal, which `histogram` and `run` fit, as a number of columns" do
      expect(Tty.width).to be_a(Integer)
    end

    it "has the colours and reset the table paints with, as escape sequences when colour is on" do
      ENV["HOMEBREW_COLOR"] = "1"
      codes = [:blue, :green, :yellow, :red, :cyan, :magenta, :italic, :bold, :underline].to_h do |colour|
        [colour, "#{Tty.public_send(colour)}x#{Tty.reset}"]
      end
      expect(codes).to eq(blue: "\e[34mx\e[0m", green: "\e[32mx\e[0m", yellow: "\e[33mx\e[0m", red: "\e[31mx\e[0m",
                          cyan: "\e[36mx\e[0m", magenta: "\e[35mx\e[0m", italic: "\e[3mx\e[0m",
                          bold: "\e[1mx\e[0m", underline: "\e[4mx\e[0m")
    end

    it "is in colour with `HOMEBREW_COLOR`, never with `HOMEBREW_NO_COLOR`, and not when not a terminal" do
      colour = lambda do |env|
        ENV.delete("HOMEBREW_COLOR")
        ENV.delete("HOMEBREW_NO_COLOR")
        env.each { |key, value| ENV[key] = value }
        Tty.color?
      end
      expect([colour.call({}), colour.call("HOMEBREW_COLOR" => "1"),
              colour.call("HOMEBREW_COLOR" => "1", "HOMEBREW_NO_COLOR" => "1")]).to eq([false, true, false])
    end

    it "strips the escape sequences it writes" do
      expect(Tty.strip_ansi("\e[31mred\e[0m")).to eq("red")
    end
  end

  describe "the summary `FormulaInstaller` prints for each formula it installs" do
    let(:installer) do
      formula = formula("foo") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/foo-1.0.tgz"
      end
      (formula.prefix/"bin").mkpath
      FileUtils.touch [formula.prefix/"bin/foo", formula.prefix/"README"]
      FormulaInstaller.new(formula)
    end

    def parsed_summary(build_time)
      allow(installer).to receive(:build_time).and_return(build_time)
      Timed::Runner.parse([[installer.summary, nil]]).fetch("foo").slice("version", "status", "build_seconds")
    end

    it "ends in `built in` and the build time as `pretty_duration` prints it, which `Timed::Runner.parse` reads" do
      expect(parsed_summary(5190.0)).to eq("version" => "1.0", "status" => "built", "build_seconds" => 5160.0)
    end

    it "has no build time for a pour" do
      expect(parsed_summary(nil)).to eq("version" => "1.0", "status" => "poured")
    end

    it "can be read without the install badge" do
      ENV["HOMEBREW_NO_EMOJI"] = "1"
      expect(parsed_summary(61.0)).to eq("version" => "1.0", "status" => "built", "build_seconds" => 61.0)
    end
  end
end

# rubocop:enable Sorbet/BlockMethodDefinition
