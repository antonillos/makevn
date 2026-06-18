Output docs/assets/makevn-install-asdf.gif

Set Shell "zsh"
Set FontSize 22
Set Width 1200
Set Height 720
Set TypingSpeed 25ms
Set Framerate 12
Set Theme { "name": "makevn", "black": "#17212b", "red": "#ef4444", "green": "#22c55e", "yellow": "#f59e0b", "blue": "#38bdf8", "magenta": "#c084fc", "cyan": "#2dd4bf", "white": "#e5e7eb", "brightBlack": "#64748b", "brightRed": "#f87171", "brightGreen": "#4ade80", "brightYellow": "#fbbf24", "brightBlue": "#7dd3fc", "brightMagenta": "#d8b4fe", "brightCyan": "#5eead4", "brightWhite": "#f8fafc", "background": "#0f172a", "foreground": "#e5e7eb", "selection": "#334155", "cursor": "#f8fafc" }

Hide
Type "rm -rf /tmp/makevn-asdf-demo"
Enter
Type "mkdir -p /tmp/makevn-asdf-demo/project"
Enter
Type "export ASDF_DATA_DIR=/tmp/makevn-asdf-demo/data"
Enter
Type "export PATH=$ASDF_DATA_DIR/shims:$PATH"
Enter
Type "cd /tmp/makevn-asdf-demo/project"
Enter
Type "clear"
Enter
Show
Type "asdf plugin add makevn https://github.com/antonillos/asdf-makevn.git"
Enter
Sleep 8s
Type "MAKEVN_VERSION=$(asdf latest makevn | sed -n '$p')"
Enter
Sleep 5s
Type "asdf install makevn $MAKEVN_VERSION"
Enter
Sleep 20s
Type "asdf set -u makevn $MAKEVN_VERSION"
Enter
Sleep 3s
Type "asdf reshim makevn $MAKEVN_VERSION"
Enter
Sleep 3s
Type "makevn --version"
Enter
Sleep 4s
