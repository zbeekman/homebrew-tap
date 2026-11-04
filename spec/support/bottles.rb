# typed: true
# frozen_string_literal: true

# Bottled formulae whose bottle manifests are never downloaded, and bottle
# files, for specs that `include` this.
module TimedBottleHelper
  extend T::Helpers

  requires_ancestor { RSpec::Mocks::ExampleMethods }
  requires_ancestor { Test::Helper::MkTmpDir }

  # Gives `klass`, a formula class being defined, a bottle for this computer.
  sig { params(klass: T.class_of(Formula)).void }
  def self.bottle(klass)
    klass.bottle do
      T.bind(self, BottleSpecification)
      sha256 cellar: :any, Utils::Bottles.tag.to_sym => "a" * 64
    end
  end

  # Stops brew downloading the manifest of `formula`'s bottle, which it reads
  # the bottle's tab from: there is no manifest to queue, and fetching the tab
  # does nothing. The tab is empty or, given `bottle_deps`, like brew's, empty
  # until the tab is fetched, then lists them with the version each needs.
  sig { params(formula: Formula, bottle_deps: T.nilable(T::Hash[String, String])).void }
  def stub_bottle_manifest(formula, bottle_deps: nil)
    allow(formula.bottle).to receive(:github_packages_manifest_resource).and_return(nil)
    fetches = []
    allow(formula.bottle).to receive(:fetch_tab) { fetches << :fetched }
    return if bottle_deps.nil?

    runtime_dependencies = bottle_deps.map do |dep, version|
      { "full_name" => dep, "version" => version, "revision" => 0 }
    end
    allow(formula.bottle).to receive(:tab_attributes) do
      fetches.empty? ? {} : { "runtime_dependencies" => runtime_dependencies }
    end
  end

  # A bottle file of a formula `foo` at 2.0 for this computer, under the name
  # brew gives it, in a new directory.
  sig { returns(Pathname) }
  def bottle_file
    dir = mktmpdir
    keg = dir/"foo/2.0"
    (keg/".brew").mkpath
    (keg/".brew/foo.rb").write("class Foo < Formula\n  url \"https://brew.sh/foo-2.0.tgz\"\nend\n")
    FileUtils.cp Pathname.new(__FILE__).dirname.parent/"fixtures/receipts/built.json", keg/"INSTALL_RECEIPT.json"
    bottle = dir/"foo--2.0.#{Utils::Bottles.tag}.bottle.tar.gz"
    Kernel.system("tar", "-czf", bottle.to_s, "-C", dir.to_s, "foo/2.0", exception: true)
    bottle.realpath
  end

  # Lets brew, loading a bottle file of `formula`, look up where `formula`
  # would be (`Formulary.path`) when its loader is stubbed for its name.
  sig { params(formula: Formula).void }
  def stub_formula_path(formula)
    allow(Formulary).to receive(:path).and_call_original
    allow(Formulary).to receive(:path).with(formula.full_name).and_return(formula.path)
  end
end
