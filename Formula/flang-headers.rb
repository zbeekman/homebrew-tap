# Homebrew's `flang` installed these headers until 23.1.0_1 enabled
# `LLVM_INSTALL_TOOLCHAIN_ONLY` (Homebrew/homebrew-core#301251). A PR may ask
# `flang` to ship them again; if it merges, remove this formula.
class FlangHeaders < Formula
  desc "C++ headers for LLVM Flang frontend plugins"
  homepage "https://flang.llvm.org/"
  url "https://github.com/llvm/llvm-project/releases/download/llvmorg-23.1.3/llvm-project-23.1.3.src.tar.xz"
  sha256 "c44186a7762ed28954be72e5ff6df9808e0779d4f1bf014ecc4e7e211d31ee34"
  license "Apache-2.0" => { with: "LLVM-exception" }
  revision 1

  livecheck do
    formula "flang"
  end

  depends_on "cmake" => [:build, :test]
  depends_on "ninja" => :build
  depends_on "flang"
  depends_on "llvm"

  uses_from_macos "python" => :build

  def install
    # Plugins resolve Flang symbols from the flang binary, so the headers must match it exactly.
    flang_version = Formula["flang"].any_installed_version&.version
    odie "flang-headers #{version} does not match flang #{flang_version}" if flang_version != version

    llvm = Formula["llvm"]
    system "cmake", "-S", "flang", "-B", "build", "-GNinja",
           "-DCLANG_DIR=#{llvm.opt_lib}/cmake/clang",
           "-DFLANG_INCLUDE_TESTS=OFF",
           "-DLLVM_DIR=#{llvm.opt_lib}/cmake/llvm",
           "-DMLIR_DIR=#{llvm.opt_lib}/cmake/mlir",
           *std_cmake_args
    # Generate the TableGen headers only; nothing is compiled.
    targets = Utils.safe_popen_read("ninja", "-C", "build", "-t", "targets", "all").scan(/^(\w+IncGen): phony$/)
    system "ninja", "-C", "build", *targets.flatten

    system "cmake", "--install", "build", "--component", "flang-headers"
    rm include/"flang/ISO_Fortran_binding.h" # `flang` already links it

    # Header-only stand-in so `find_package(Flang)` works. It ships no Flang libraries: a plugin
    # linking its own copy would duplicate MLIR singletons (llvm/llvm-project#219579).
    (lib/"cmake/flang").install "build/cmake/modules/CMakeFiles/FlangConfigVersion.cmake"
    (lib/"cmake/flang/FlangConfig.cmake").write <<~CMAKE
      set(FLANG_CMAKE_DIR "#{opt_lib}/cmake/flang")
      set(FLANG_EXPORTED_TARGETS "")
      set(FLANG_INCLUDE_DIRS "#{opt_include}")

      # Plugins use this target and resolve Flang symbols from the flang binary at load time.
      if(NOT TARGET Flang::Headers)
        add_library(Flang::Headers INTERFACE IMPORTED)
        set_target_properties(Flang::Headers PROPERTIES
          INTERFACE_INCLUDE_DIRECTORIES "${FLANG_INCLUDE_DIRS};#{llvm.opt_include}"
          INTERFACE_COMPILE_DEFINITIONS FLANG_LITTLE_ENDIAN=1)
        if(APPLE)
          set_property(TARGET Flang::Headers PROPERTY INTERFACE_LINK_OPTIONS "LINKER:-undefined,dynamic_lookup")
        endif()
      endif()
    CMAKE
  end

  test do
    (testpath/"plugin.cpp").write <<~CPP
      #include "flang/Frontend/FrontendActions.h"
      #include "flang/Frontend/FrontendPluginRegistry.h"
      #include "flang/Parser/parse-tree.h"
      #include "flang/Parser/parsing.h"

      using namespace Fortran::frontend;

      struct CountUnits : PluginParseTreeAction {
        void executeAction() override {
          llvm::outs() << "units: " << getParsing().parseTree()->v.size() << "\\n";
        }
      };

      static FrontendPluginRegistry::Add<CountUnits> X("count-units", "Count program units");
    CPP

    (testpath/"test.f90").write <<~FORTRAN
      module m
      end module m
      program p
      end program p
    FORTRAN

    (testpath/"CMakeLists.txt").write <<~CMAKE
      cmake_minimum_required(VERSION 3.20)
      project(plugin CXX)
      find_package(Flang #{version} REQUIRED CONFIG)
      add_library(plugin SHARED plugin.cpp)
      target_compile_features(plugin PRIVATE cxx_std_17)
      target_link_libraries(plugin PRIVATE Flang::Headers)
    CMAKE

    system "cmake", "-S", ".", "-B", "build", "-DCMAKE_CXX_COMPILER=#{formula_opt_bin("llvm")}/clang++",
           "-DCMAKE_PREFIX_PATH=#{opt_prefix}"
    system "cmake", "--build", "build"
    plugin = testpath/"build"/shared_library("libplugin")
    output = shell_output("#{formula_opt_bin("flang")}/flang -fc1 -load #{plugin} -plugin count-units test.f90")
    assert_equal "units: 2", output.strip
  end
end
