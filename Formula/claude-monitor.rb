class ClaudeMonitor < Formula
  include Language::Python::Virtualenv

  desc "macOS menu-bar app to monitor Claude CLI token usage and cost"
  homepage "https://github.com/karthik_seq/claude-monitor"
  license "MIT"
  version "1.3.0"

  # Minimal version-marker tarball committed to the tap repo — stable hash guaranteed.
  # Actual Python sources are installed from tap's sources/ directory below.
  url "https://raw.githubusercontent.com/karthik_seq/homebrew-tap/main/dist/claude-monitor-version-1.3.0.tar.gz"
  sha256 "a77bd23fb403032ec5b9dbf5cb3c21ccf7ab93a71296161ac7aebb5e76dae357"

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
    python = Formula["python@3.12"].opt_bin/"python3.12"
    venv = virtualenv_create(libexec, python)

    %w[pyobjc-core pyobjc-framework-Cocoa].each do |r|
      cached = resource(r).cached_download
      wheel  = buildpath/cached.basename.to_s.sub(/\A[0-9a-f]+-+/, "")
      cp cached, wheel
      system python, "-m", "pip", "--python=#{libexec}/bin/python", "install", "--no-deps", "--no-index", wheel
    end
    venv.pip_install resource("rumps")

    # Install Python sources from the tap's sources/ directory (avoids GitHub CDN instability)
    src = Pathname.new(__dir__).parent/"sources"
    (libexec/"share/claude_monitor").install src/"monitor_core.py",
                                              src/"menubar.py",
                                              src/"widget.py"

    (bin/"claude-monitor").write <<~EOS
      #!/bin/bash
      if pgrep -f "claude_monitor/menubar.py" > /dev/null 2>&1; then
        echo "Claude Monitor is already running — look for ◆ in your menu bar."
        exit 0
      fi
      nohup "#{libexec}/bin/python3.12" "#{libexec}/share/claude_monitor/menubar.py" "$@" \
        > /tmp/claude_monitor.log 2>&1 &
      disown
      echo "Claude Monitor started — look for ◆ in your menu bar."
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
    system Formula["python@3.12"].opt_bin/"python3.12", "-c",
           "import sys; sys.path.insert(0,'#{libexec}/share/claude_monitor'); import monitor_core"
  end
end
