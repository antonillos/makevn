import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Tool,
} from "@modelcontextprotocol/sdk/types.js";
import { spawnSync } from "child_process";

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
      name: "docker_ps",
      description: "List running Docker containers for the repository's compose setup.",
      inputSchema: {
        type: "object",
        properties: {
          repo: { type: "string", description: "Path to the repository" },
        },
      },
    },
    handler: (args) => runMakevn("docker-ps", args),
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
];

function buildArgs(command: string, args: Record<string, unknown>): string[] {
  const result: string[] = [];

  const repo = args.repo as string | undefined;
  if (repo) {
    result.push("--repo", repo);
  }

  if (args.compact) {
    result.push("--compact");
  }

  result.push(command);

  const subcommand = args._subcommand as string | undefined;
  if (subcommand) {
    result.push(subcommand);
  }

  const flagArgs = ["name", "fast", "apply", "verbose", "threshold", "overall-threshold", "module", "context", "force", "dry-run"];
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
