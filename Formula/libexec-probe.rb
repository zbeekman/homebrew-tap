class LibexecProbe < Formula
  desc "Throwaway probe for sandboxed post-install in CI"
  homepage "https://curl.se/docs/caextract.html"
  url "https://curl.se/ca/cacert-2026-11-05.pem"
  version "2026-11-05"
  sha256 "427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285"
  license "MPL-2.0"

  depends_on "ca-certificates"

  def install
    pkgshare.install "cacert-2026-11-05.pem"
  end

  post_install_steps do
    mkdir_p "libexec-probe", base: :var
  end

  test do
    assert_match "BEGIN CERTIFICATE", (pkgshare/"cacert-2026-11-05.pem").read
  end
end
