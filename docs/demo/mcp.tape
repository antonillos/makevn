Output docs/assets/makevn-mcp.gif

Set Shell "bash"
Set FontSize 18
Set Width 1600
Set Height 1080
Set TypingSpeed 35ms
Set Framerate 12
Set Theme { "name": "makevn", "black": "#17212b", "red": "#ef4444", "green": "#22c55e", "yellow": "#f59e0b", "blue": "#38bdf8", "magenta": "#c084fc", "cyan": "#2dd4bf", "white": "#e5e7eb", "brightBlack": "#64748b", "brightRed": "#f87171", "brightGreen": "#4ade80", "brightYellow": "#fbbf24", "brightBlue": "#7dd3fc", "brightMagenta": "#d8b4fe", "brightCyan": "#5eead4", "brightWhite": "#f8fafc", "background": "#0f172a", "foreground": "#e5e7eb", "selection": "#334155", "cursor": "#f8fafc" }

Hide
Type 'export PATH="$MAKEVN_DEMO_PREFIX/bin:$PATH"; source "$MAKEVN_DEMO_ROOT/docs/demo/session.sh"'
Enter
Wait+Line@15m /^demo>$/
Type "docs/demo/setup-demo-repo.sh developer /tmp/makevn-mcp-demo >/dev/null"
Enter
Wait+Line@15m /^demo>$/
Type "cd /tmp/makevn-mcp-demo"
Enter
Wait+Line@15m /^demo>$/
Type "clear"
Enter
Wait+Line@15m /^demo>$/
Show
Type "clear"
Enter
Wait+Line@15m /^demo>$/
Type 'python3 "$MAKEVN_DEMO_ROOT/docs/demo/mcp_demo.py" "$PWD" doctor'
Enter
Wait+Line@15m /^demo>$/
Sleep 4s
Type "clear"
Enter
Wait+Line@15m /^demo>$/
Type 'python3 "$MAKEVN_DEMO_ROOT/docs/demo/mcp_demo.py" "$PWD" init'
Enter
Wait+Line@15m /^demo>$/
Sleep 4s
Type "clear"
Enter
Wait+Line@15m /^demo>$/
Type 'python3 "$MAKEVN_DEMO_ROOT/docs/demo/mcp_demo.py" "$PWD" composite_run'
Enter
Wait+Line@15m /^demo>$/
Sleep 4s
