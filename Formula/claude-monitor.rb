class ClaudeMonitor < Formula
  include Language::Python::Virtualenv

  desc "macOS menu-bar app to monitor Claude CLI token usage and cost"
  homepage "https://github.com/karthik_seq/claude-monitor"
  license "MIT"

  head "https://github.com/karthik_seq/claude-monitor.git", branch: "main"

  depends_on "python@3.12"
  depends_on :macos

  # Pre-built universal2 wheels — no C compilation needed, installs in seconds
  resource "pyobjc-core" do
    url "https://files.pythonhosted.org/packages/24/be/4771f4fd786f0e1a2bd6d8931a72a5f3929b7bb1b28a1fe6ca8a08371c55/pyobjc_core-12.2-cp312-cp312-macosx_10_13_universal2.whl"
    sha256 "7677ed758a367bbbb5589d6f5276fb360a45c89168276c26162f61840b0fa03d"
  end

  resource "pyobjc-framework-Cocoa" do
    url "https://files.pythonhosted.org/packages/30/66/5a91f2eddfced4f26bc2df2bcebb7f5f10c5bf5666aff6fa00ded845af07/pyobjc_framework_cocoa-12.2-cp312-cp312-macosx_10_13_universal2.whl"
    sha256 "06cb92d97d1af9d1f459ae6cf1d1a7b824c12d3aff1b709885966acd6b7208c2"
  end

  resource "rumps" do
    url "https://files.pythonhosted.org/packages/b2/e2/2e6a47951290bd1a2831dcc50aec4b25d104c0cf00e8b7868cbd29cf3bfe/rumps-0.4.0.tar.gz"
    sha256 "17fb33c21b54b1e25db0d71d1d793dc19dc3c0b7d8c79dc6d833d0cffc8b1596"
  end

  def install
    venv = virtualenv_create(libexec, Formula["python@3.12"].opt_bin/"python3.12")
    pip = libexec/"bin/pip3"

    # Homebrew caches wheels with a hash prefix (e.g. "abc123--pyobjc_core-...whl").
    # pip rejects the non-standard filename, so copy to buildpath with the real name first.
    %w[pyobjc-core pyobjc-framework-Cocoa].each do |r|
      cached = resource(r).cached_download
      wheel  = buildpath/cached.basename.to_s.sub(/\A[0-9a-f]+-+/, "")
      cp cached, wheel
      system pip, "install", "--no-deps", "--no-index", wheel
    end
    # rumps is a pure-Python source tarball — stage normally
    venv.pip_install resource("rumps")

    # buildpath = root of the cloned git repo — always correct for --HEAD installs
    (libexec/"share/claude_monitor").install buildpath/"monitor_core.py",
                                              buildpath/"menubar.py",
                                              buildpath/"widget.py"

    # Wrapper script: launch the menu bar app in background
    (bin/"claude-monitor").write <<~EOS
      #!/bin/bash
      # Re-use an existing instance if already running
      if pgrep -f "claude_monitor/menubar.py" > /dev/null 2>&1; then
        echo "Claude Monitor is already running — look for ◆ in your menu bar."
        exit 0
      fi
      exec "#{libexec}/bin/python3.12" "#{libexec}/share/claude_monitor/menubar.py" "$@"
    EOS
  end

  def caveats
    <<~EOS
      Claude Monitor is a menu-bar app. Start it with:
        claude-monitor

      It will appear as ◆ in your menu bar.

      To start automatically at login:
        System Settings → General → Login Items → + → add claude-monitor
        (path: #{opt_bin}/claude-monitor)

      Usage data is read from: ~/.claude/projects/**/*.jsonl
    EOS
  end

  test do
    # Smoke-test: core module imports cleanly without a display
    system Formula["python@3.12"].opt_bin/"python3.12", "-c",
           "import sys; sys.path.insert(0,'#{libexec}/share/claude_monitor'); import monitor_core"
  end
end
