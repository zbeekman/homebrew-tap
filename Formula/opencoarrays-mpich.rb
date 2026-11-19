class OpencoarraysMpich < Formula
  desc "Coarray Fortran ABI, API, and compiler wrapper built with MPICH"
  homepage "https://www.opencoarrays.org"
  url "https://github.com/sourceryinstitute/OpenCoarrays/archive/refs/tags/2.10.3.tar.gz"
  sha256 "f9f2fb6ac1fe92c1ea66976894b5cebe53812827b7d1238fed933e2845e8a022"
  license "BSD-3-Clause"
  head "https://github.com/sourceryinstitute/OpenCoarrays.git", branch: "main"

  depends_on "cmake" => :build
  depends_on "gcc"
  depends_on "mpich"

  conflicts_with "opencoarrays", because: "both install `caf` and `cafrun`"

  def install
    ENV["FC"] = formula_opt_bin("gcc")/"gfortran"
    mpich = Formula["mpich"]

    # Use `mpich` even if `open-mpi` is linked into HOMEBREW_PREFIX, and keep
    # FindMPI from picking HOMEBREW_PREFIX/lib over the `mpicc -show` paths.
    args = %W[
      -DMPI_C_COMPILER=#{mpich.opt_bin}/mpicc
      -DMPI_Fortran_COMPILER=#{mpich.opt_bin}/mpifort
      -DMPIEXEC_EXECUTABLE=#{mpich.opt_bin}/mpiexec
      -DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=OFF
    ]
    system "cmake", "-S", ".", "-B", "build", *args, *std_cmake_args
    system "cmake", "--build", "build"
    system "cmake", "--install", "build"

    # Replace the `mpich` Cellar path, which breaks on `mpich` version/revision bumps.
    # CMake FindMPI uses REALPATH so there isn't a clean way to handle during generation.
    inreplace [bin/"caf", lib/"cmake/opencoarrays/OpenCoarraysTargets.cmake"],
              mpich.prefix.realpath, mpich.opt_prefix
  end

  test do
    (testpath/"tally.f90").write <<~FORTRAN
      program main
        use iso_c_binding, only : c_int
        use iso_fortran_env, only : error_unit
        implicit none
        integer(c_int) :: tally
        tally = this_image() ! this image's contribution
        call co_sum(tally)
        verify: block
          integer(c_int) :: image
          if (tally/=sum([(image,image=1,num_images())])) then
             write(error_unit,'(a,i5)') "Incorrect tally on image ",this_image()
             error stop 2
          end if
        end block verify
        ! Wait for all images to pass the test
        sync all
        if (this_image()==1) write(*,*) "Test passed"
      end program
    FORTRAN
    system bin/"caf", "tally.f90", "-o", "tally"
    assert_match "Test passed", shell_output("#{bin}/cafrun -np 3 ./tally")
    assert_match formula_opt_lib("mpich").to_s, shell_output("#{bin}/caf --show")
  end
end
