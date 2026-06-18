Output docs/assets/makevn-opencode.gif

Set Shell "zsh"
Set FontSize 22
Set Width 1200
Set Height 720
Set TypingSpeed 28ms
Set Framerate 15
Set PlaybackSpeed 1.05
Set Theme { "name": "makevn", "black": "#17212b", "red": "#ef4444", "green": "#22c55e", "yellow": "#f59e0b", "blue": "#38bdf8", "magenta": "#c084fc", "cyan": "#2dd4bf", "white": "#e5e7eb", "brightBlack": "#64748b", "brightRed": "#f87171", "brightGreen": "#4ade80", "brightYellow": "#fbbf24", "brightBlue": "#7dd3fc", "brightMagenta": "#d8b4fe", "brightCyan": "#5eead4", "brightWhite": "#f8fafc", "background": "#0f172a", "foreground": "#e5e7eb", "selection": "#334155", "cursor": "#f8fafc" }

Hide
Type "docs/demo/setup-cathode-demo.sh ../cathode /tmp/makevn-opencode-demo >/dev/null"
Enter
Type "cd /tmp/makevn-opencode-demo/cataloger-cli"
Enter
Type "clear"
Enter
Show
Type "opencode run -m openai/gpt-5.4 'clean compile and package the project'"
Enter
Sleep 60s
