class ClaudeMonitor < Formula
  include Language::Python::Virtualenv

  desc "macOS menu-bar app to monitor Claude CLI token usage and cost"
  homepage "https://github.com/karthik_seq/claude-monitor"
  license "MIT"

  head "https://github.com/karthik_seq/claude-monitor.git", branch: "main"

  depends_on "python@3.12"
  depends_on :macos

  # pyobjc-core must be installed before pyobjc-framework-Cocoa and rumps
  resource "pyobjc-core" do
    url "https://files.pythonhosted.org/packages/2a/e8/a6cc12669211e7c9b29e8f26bf2159e67c7a73555dc229018abf46d8167a/pyobjc_core-12.2.tar.gz"
    sha256 "51d7de4cfa32f508c6a7aac31f131b12d5e196a8dcf588e6e8d7e6337224f66d"
  end

  resource "pyobjc-framework-Cocoa" do
    url "https://files.pythonhosted.org/packages/6d/cc/927169225e72bab9c9b44285656768fb75052a0bc85fdbca62740e1ca43c/pyobjc_framework_cocoa-12.2.tar.gz"
    sha256 "20b392e2b7241caad0538dfde12143343e5dfe48f72e7df660a7548e635903dc"
  end

  resource "rumps" do
    url "https://files.pythonhosted.org/packages/b2/e2/2e6a47951290bd1a2831dcc50aec4b25d104c0cf00e8b7868cbd29cf3bfe/rumps-0.4.0.tar.gz"
    sha256 "17fb33c21b54b1e25db0d71d1d793dc19dc3c0b7d8c79dc6d833d0cffc8b1596"
  end

  def install
    venv = virtualenv_create(libexec, Formula["python@3.12"].opt_bin/"python3.12")
    # Install in dependency order: pyobjc-core → pyobjc-framework-Cocoa → rumps
    %w[pyobjc-core pyobjc-framework-Cocoa rumps].each do |r|
      venv.pip_install resource(r)
    end

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
