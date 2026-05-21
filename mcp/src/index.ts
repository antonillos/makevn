import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Tool,
} from "@modelcontextprotocol/sdk/types.js";
import { spawnSync, spawn } from "child_process";

const MAKEVN_BIN = process.env.MAKEVN_BIN_PATH || "makevn";
const BUILD_DATE = "__BUILD_DATE__";

interface ToolDefinition {
  tool: Tool;
  handler: (args: Record<string, unknown>) => { content: { type: "text"; text: string }[] };
}

const tools: ToolDefinition[] = [
  {
    tool: {
      name: "doctor",
      description: "Inspect a Java/Maven repository. Run this first to understand the repo setup before any other operation.",
      inputSchema: {
        type: "object",
        properties: {
          repo: {
            type: "string",
            description: "Path to the repository (defaults to current directory)",
          },
          compact: {
            type: "boolean",
            description: "Use compact output format suitable for agents",
          },
        },
      },
    },
    handler: (args) => runMakevn("doctor", args),
  },
  {
    tool: {
      name: "init",
      description: "Initialize makevn in a repository. Creates .makevn/ configuration directory. Run doctor first to check if already initialized.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          "dry-run": { type: "boolean", description: "Show what would be done without making changes" },
          force: { type: "boolean", description: "Force reinitialization even if already initialized" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("init", args),
  },
  {
    tool: {
      name: "make_install",
      description: "Install makevn Makefile integration in a repository.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          "dry-run": { type: "boolean", description: "Show what would be done without making changes" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("make", { ...args, _subcommand: "install" }),
  },
  {
    tool: {
      name: "make_uninstall",
      description: "Remove makevn Makefile integration from a repository.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          "dry-run": { type: "boolean", description: "Show what would be done without making changes" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("make", { ...args, _subcommand: "uninstall" }),
  },
  {
    tool: {
      name: "uninstall",
      description: "Remove makevn Makefile integration from a repository.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          "dry-run": { type: "boolean", description: "Show what would be done without making changes" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("uninstall", args),
  },
  {
    tool: {
      name: "profile_refresh",
      description: "Refresh makevn repository profile detection.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("profile", { ...args, _subcommand: "refresh" }),
  },
  {
    tool: {
      name: "test",
      description: "Run tests with optional test name filter and fast mode (skip recompilation).",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          name: { type: "string", description: "Test class name or comma-separated names (e.g. UserRepositoryTest or UserRepositoryTest,OrderRepositoryTest)" },
          fast: { type: "boolean", description: "Skip compilation when sources have not changed" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("test", args),
  },
  {
    tool: {
      name: "test_compile",
      description: "Compile test sources.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("test-compile", args),
  },
  {
    tool: {
      name: "compile_tests",
      description: "Compile test sources.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("compile-tests", args),
  },
  {
    tool: {
      name: "verify",
      description: "Run full combined verification (unit tests + integration tests).",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("verify", args),
  },
  {
    tool: {
      name: "verify_ut",
      description: "Run unit-test-only verification.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("verify-ut", args),
  },
  {
    tool: {
      name: "verify_it",
      description: "Run integration-test-only verification.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("verify-it", args),
  },
  {
    tool: {
      name: "verify_ut_coverage",
      description: "Run unit-test-only verification with coverage.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("verify-ut-coverage", args),
  },
  {
    tool: {
      name: "verify_it_coverage",
      description: "Run integration-test-only verification with coverage.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("verify-it-coverage", args),
  },
  {
    tool: {
      name: "verify_changes",
      description: "Verify only the changed production modules or modified tests. Use after making changes to get faster feedback.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("verify-changes", args),
  },
  {
    tool: {
      name: "compile",
      description: "Compile the Maven project source code.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("compile", args),
  },
  {
    tool: {
      name: "build",
      description: "Full Maven build (compile, test, package).",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("build", args),
  },
  {
    tool: {
      name: "coverage",
      description: "Check the latest JaCoCo aggregate coverage report against the repository threshold.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          threshold: { type: "number", description: "Coverage threshold percentage" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => {
      const cmdArgs = buildArgs("coverage", args);
      return runMakevnDirect(cmdArgs);
    },
  },
  {
    tool: {
      name: "coverage_changes",
      description: "Check incremental, per-changed-module, and overall JaCoCo coverage. Run after a coverage-producing command like verify.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          threshold: { type: "number", description: "Per-module coverage threshold percentage" },
          "overall-threshold": { type: "number", description: "Overall coverage threshold percentage" },
          verbose: { type: "boolean", description: "Verbose output" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => {
      const cmdArgs = buildArgs("coverage-changes", args);
      return runMakevnDirect(cmdArgs);
    },
  },
  {
    tool: {
      name: "clean",
      description: "Clean Maven build output.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("clean", args),
  },
  {
    tool: {
      name: "package",
      description: "Compile and package the project artifact without running tests.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("package", args),
  },
  {
    tool: {
      name: "validate",
      description: "Validate the Maven project model is correct and all necessary information is available.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("validate", args),
  },
  {
    tool: {
      name: "format",
      description: "Check or apply code formatting. Detects Spotless, fmt-maven-plugin, formatter-maven-plugin, Google Java Format.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          apply: { type: "boolean", description: "Apply formatting changes instead of just checking" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => {
      const cmdArgs = buildArgs("format", args);
      return runMakevnDirect(cmdArgs);
    },
  },
  {
    tool: {
      name: "exec",
      description: "Run an arbitrary Maven command or shell command in the repository context with proper JDK resolution.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          command: { type: "string", description: "The command to execute after -- separator, e.g. 'mvn -v' or 'mvn dependency:tree'" },
          context: { type: "string", description: "Execution context: 'code' (default) or 'karate'" },
          compact: { type: "boolean", description: "Use compact output" },
        },
        required: ["command"],
      },
    },
    handler: (args) => {
      const cmdArgs = buildArgs("exec", args);
      const command = args.command as string;
      if (command) {
        cmdArgs.push("--");
        cmdArgs.push(...command.split(/\s+/).filter(Boolean));
      }
      return runMakevnDirect(cmdArgs);
    },
  },
  {
    tool: {
      name: "jdk_current",
      description: "Show the currently resolved JDK version for the repository.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
        },
      },
    },
    handler: (args) => runMakevn("jdk", { ...args, _subcommand: "current" }),
  },
  {
    tool: {
      name: "jdk_list",
      description: "List JDK candidates detected for the repository.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
        },
      },
    },
    handler: (args) => runMakevn("jdk", { ...args, _subcommand: "list" }),
  },
  {
    tool: {
      name: "docker_up",
      description: "Start the repository's Docker compose services.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          tail: { type: "boolean", description: "Stream command output" },
        },
      },
    },
    handler: (args) => runMakevn("docker-up", args),
  },
  {
    tool: {
      name: "docker_down",
      description: "Stop the repository's Docker compose services.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          tail: { type: "boolean", description: "Stream command output" },
        },
      },
    },
    handler: (args) => runMakevn("docker-down", args),
  },
  {
    tool: {
      name: "docker_ps",
      description: "List running Docker containers for the repository's compose setup.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          tail: { type: "boolean", description: "Stream command output" },
        },
      },
    },
    handler: (args) => runMakevn("docker-ps", args),
  },
  {
    tool: {
      name: "docker_ps_required",
      description: "Check that required Docker compose services are running and healthy.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          compose: { type: "string", description: "Compose selection: boot or karate" },
          "wait-seconds": { type: "number", description: "Seconds to wait for required services" },
          tail: { type: "boolean", description: "Stream command output" },
        },
      },
    },
    handler: (args) => runMakevn("docker-ps-required", args),
  },
  {
    tool: {
      name: "docker_stats",
      description: "Show one-shot CPU and memory stats for all running Docker containers.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          tail: { type: "boolean", description: "Stream command output" },
        },
      },
    },
    handler: (args) => runMakevn("docker-stats", args),
  },
  {
    tool: {
      name: "karate_docker_up",
      description: "Start Docker compose services for Karate tests.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          tail: { type: "boolean", description: "Stream command output" },
        },
      },
    },
    handler: (args) => runMakevn("karate-docker-up", args),
  },
  {
    tool: {
      name: "karate_docker_down",
      description: "Stop Docker compose services for Karate tests.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          tail: { type: "boolean", description: "Stream command output" },
        },
      },
    },
    handler: (args) => runMakevn("karate-docker-down", args),
  },
  {
    tool: {
      name: "karate_test",
      description: "Run Karate tests, optionally filtered by tag.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          tag: { type: "string", description: "Karate tag filter" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("karate-test", args),
  },
  {
    tool: {
      name: "karate_all",
      description: "Run the complete Karate flow, optionally filtered by tag.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          tag: { type: "string", description: "Karate tag filter" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("karate-all", args),
  },
  {
    tool: {
      name: "run_app",
      description: "Run the repository application in the foreground.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
        },
      },
    },
    handler: (args) => runMakevn("run-app", args),
  },
  {
    tool: {
      name: "run_app_bg",
      description: "Run the repository application in the background.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
        },
      },
    },
    handler: (args) => runMakevn("run-app-bg", args),
  },
  {
    tool: {
      name: "stop_app",
      description: "Stop the background repository application.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
        },
      },
    },
    handler: (args) => runMakevn("stop-app", args),
  },
  {
    tool: {
      name: "run",
      description: "Run the repository application using makevn's default run command.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
        },
      },
    },
    handler: (args) => runMakevn("run", args),
  },
  {
    tool: {
      name: "pr_verify",
      description: "Run a local PR-style verification flow.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => runMakevn("pr-verify", args),
  },
  {
    tool: {
      name: "checkstyle",
      description: "Run Checkstyle code style checks.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          module: { type: "string", description: "Specific Maven module to check" },
          verbose: { type: "boolean", description: "Verbose output" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => {
      const cmdArgs = buildArgs("checkstyle", args);
      return runMakevnDirect(cmdArgs);
    },
  },
  {
    tool: {
      name: "mutation",
      description: "Run PIT mutation testing in background. Detects pitest-maven plugin automatically. Returns immediately with PID and log path. WARNING: Very slow (30+ min for large projects). Monitor the log file for progress.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
          module: { type: "string", description: "Specific Maven module to test" },
          verbose: { type: "boolean", description: "Show full Maven/PIT output (default: quiet)" },
          compact: { type: "boolean", description: "Use compact output" },
        },
      },
    },
    handler: (args) => {
      const cmdArgs = buildArgs("mutation", args);
      const repo = (args.repo as string) || "(repo root)";
      const child = spawn(MAKEVN_BIN, cmdArgs, {
        detached: true,
        env: { ...process.env, MAKEVN_AGENT_OUTPUT: "1", NO_COLOR: "1" },
        stdio: "ignore",
      });
      child.unref();
      return {
        content: [{
          type: "text",
          text: `mutation started (PID ${child.pid})\nlog: ${repo}/.makevn/logs/mutation.log`,
        }],
      };
    },
  },
];

function buildArgs(command: string, args: Record<string, unknown>): string[] {
  const result: string[] = [];

  const repo = args.repo as string | undefined;
  if (repo) {
    result.push("--repo", repo);
  }

  result.push("--compact");

  result.push(command);

  const subcommand = args._subcommand as string | undefined;
  if (subcommand) {
    result.push(subcommand);
  }

  const flagArgs = ["name", "fast", "apply", "verbose", "threshold", "overall-threshold", "module", "context", "force", "dry-run", "tag", "tail", "compose", "wait-seconds"];
  for (const key of flagArgs) {
    const value = (args as Record<string, unknown>)[key];
    if (value !== undefined && value !== null) {
      if (typeof value === "boolean") {
        if (value) {
          result.push(`--${key}`);
        }
      } else {
        result.push(`--${key}`, String(value));
      }
    }
  }

  return result;
}

function runMakevn(command: string, args: Record<string, unknown>): { content: { type: "text"; text: string }[] } {
  const cmdArgs = buildArgs(command, args);
  return runMakevnDirect(cmdArgs);
}

function runMakevnDirect(cmdArgs: string[]): { content: { type: "text"; text: string }[] } {
  const result = spawnSync(MAKEVN_BIN, cmdArgs, {
    encoding: "utf-8",
    env: { ...process.env, NO_COLOR: "1" },
    maxBuffer: 10 * 1024 * 1024,
  });

  const stdout = result.stdout?.trim() || "";
  const stderr = result.stderr?.trim() || "";

  const parts: string[] = [];
  if (stdout) parts.push(stdout);
  if (stderr) parts.push(`stderr:\n${stderr}`);

  const output = parts.join("\n\n");

  if (result.status === 0) {
    return { content: [{ type: "text", text: output || "(completed successfully)" }] };
  }

  const signalInfo = result.signal ? ` (killed by signal ${result.signal})` : "";
  const errorMsg = `Exit code ${result.status}${signalInfo}:\n${output || "(no output)"}`;
  return { content: [{ type: "text", text: errorMsg }] };
}

const server = new Server(
  {
    name: "makevn-mcp",
    version: BUILD_DATE.startsWith("__BUILD") ? "0.1.0-dev" : BUILD_DATE,
  },
  {
    capabilities: {
      tools: {},
    },
  },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: tools.map((t) => t.tool),
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const toolName = request.params.name;
  const args = request.params.arguments as Record<string, unknown> || {};

  const toolDef = tools.find((t) => t.tool.name === toolName);
  if (!toolDef) {
    return {
      content: [{ type: "text", text: `Unknown tool: ${toolName}` }],
      isError: true,
    };
  }

  try {
    return toolDef.handler(args);
  } catch (error) {
    return {
      content: [{ type: "text", text: `Error executing ${toolName}: ${error}` }],
      isError: true,
    };
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((error) => {
  console.error("makevn-mcp server failed:", error);
  process.exit(1);
});
