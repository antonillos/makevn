Output docs/assets/makevn-install-brew.gif

Set Shell "bash"
Set FontSize 24
Set Width 1200
Set Height 720
Set TypingSpeed 35ms
Set Framerate 12
Set Theme { "name": "makevn", "black": "#17212b", "red": "#ef4444", "green": "#22c55e", "yellow": "#f59e0b", "blue": "#38bdf8", "magenta": "#c084fc", "cyan": "#2dd4bf", "white": "#e5e7eb", "brightBlack": "#64748b", "brightRed": "#f87171", "brightGreen": "#4ade80", "brightYellow": "#fbbf24", "brightBlue": "#7dd3fc", "brightMagenta": "#d8b4fe", "brightCyan": "#5eead4", "brightWhite": "#f8fafc", "background": "#0f172a", "foreground": "#e5e7eb", "selection": "#334155", "cursor": "#f8fafc" }

Hide
Type 'source "$MAKEVN_DEMO_ROOT/docs/demo/session.sh"'
Enter
Wait+Line@15m /^demo>$/
Show
Type "brew install antonillos/tap/makevn"
Enter
Wait+Line@15m /^demo>$/
Sleep 2s
Type "makevn --version"
Enter
Wait+Line@15m /^demo>$/
Sleep 2s
