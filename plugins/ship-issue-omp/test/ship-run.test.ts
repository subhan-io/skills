import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";

const stateRoot = await mkdtemp(join(tmpdir(), "ship-issue-omp-test-"));
process.env.XDG_STATE_HOME = stateRoot;
// The ledger path is fixed at module load, so the isolated state root must be set first.
const { default: shipIssueOmp } = await import("../src/index.ts");

after(async () => {
  await rm(stateRoot, { recursive: true, force: true });
});

interface SchemaStub {
  describe(_description: string): SchemaStub;
  optional(): SchemaStub;
}

interface SessionEntry {
  type: "custom";
  customType: string;
  data: unknown;
}

interface ToolResult {
  content: Array<{ type: string; text: string }>;
  details: {
    state?: { stage: string; runId: string };
    ledgerPath: string;
  };
}

interface ToolDefinition {
  execute(id: string, params: Record<string, unknown>): Promise<ToolResult>;
}

interface CommandDefinition {
  handler(args: string): Promise<void>;
}

type SessionHandler = (
  event: unknown,
  context: { sessionManager: { getBranch(): readonly SessionEntry[] } },
) => Promise<void> | void;

function createHarness(initialEntries: readonly SessionEntry[] = []) {
  const entries = [...initialEntries];
  const handlers = new Map<string, SessionHandler>();
  const sentMessages: string[] = [];
  let tool: ToolDefinition | undefined;
  let command: CommandDefinition | undefined;

  const schema = (): SchemaStub => ({
    describe: () => schema(),
    optional: () => schema(),
  });

  const api = {
    zod: {
      string: schema,
      number: schema,
      boolean: schema,
      array: (_item: SchemaStub) => schema(),
      object: (_shape: Record<string, SchemaStub>) => schema(),
    },
    on(name: string, handler: SessionHandler) {
      handlers.set(name, handler);
    },
    registerCommand(name: string, definition: CommandDefinition) {
      assert.equal(name, "ship-issue-omp");
      command = definition;
    },
    registerTool(definition: ToolDefinition & { name: string }) {
      assert.equal(definition.name, "ship_run");
      tool = definition;
    },
    appendEntry(customType: string, data: unknown) {
      entries.push({ type: "custom", customType, data });
    },
    sendUserMessage(message: string) {
      sentMessages.push(message);
    },
  };

  shipIssueOmp(api as never);
  assert.ok(tool);
  assert.ok(command);

  return {
    entries,
    sentMessages,
    tool,
    command,
    async restore() {
      const handler = handlers.get("session_start");
      assert.ok(handler);
      await handler(undefined, { sessionManager: { getBranch: () => entries } });
    },
  };
}

test("ship_run enforces gates and persists a completed run", async () => {
  const harness = createHarness();
  await harness.restore();

  const started = await harness.tool.execute("1", {
    op: "start",
    task: "https://github.com/subhan-io/example/issues/42",
    repo: "subhan-io/example",
    tier: "standard",
    criteria: ["Behavior works", "Regression is covered"],
  });
  assert.equal(started.details.state?.stage, "criteria-approved");

  await assert.rejects(
    harness.tool.execute("2", {
      op: "approve_plan",
      planSummary: "Too large",
      chunks: ["one", "two", "three"],
    }),
    /plans over two chunks must finish with outcome=split/,
  );

  const planned = await harness.tool.execute("3", {
    op: "approve_plan",
    planSummary: "Implement and integrate",
    chunks: ["Implement behavior", "Integrate callers"],
  });
  assert.equal(planned.details.state?.stage, "plan-approved");

  await harness.tool.execute("4", {
    op: "record_chunk",
    index: 1,
    agentId: "ShipChunk1",
    status: "passed",
    summary: "Implemented behavior",
    verification: "targeted scenario passed",
  });

  await assert.rejects(
    harness.tool.execute("5", {
      op: "record_pr",
      prUrl: "https://github.com/subhan-io/example/pull/7",
      tests: "green",
    }),
    /every planned chunk must have a passing verification/,
  );

  await harness.tool.execute("6", {
    op: "record_chunk",
    index: 2,
    agentId: "ShipChunk2",
    status: "passed",
    summary: "Integrated callers",
    verification: "integration scenario passed",
  });
  await harness.tool.execute("7", {
    op: "record_pr",
    prUrl: "https://github.com/subhan-io/example/pull/7",
    tests: "local and CI green",
  });

  await assert.rejects(
    harness.tool.execute("8", {
      op: "finish",
      outcome: "pr-open",
      criteriaStatus: ["PASS Behavior works", "PASS Regression is covered"],
    }),
    /requires at least one recorded review round/,
  );

  await harness.tool.execute("9", {
    op: "record_review",
    index: 1,
    reviewOutcome: "settled",
    fixed: 1,
    rejected: 1,
    outstanding: 0,
    behaviorChanged: false,
  });
  const finished = await harness.tool.execute("10", {
    op: "finish",
    outcome: "pr-open",
    criteriaStatus: ["PASS Behavior works", "PASS Regression is covered"],
    openItems: [],
  });
  assert.equal(finished.details.state?.stage, "completed");

  const restored = createHarness(harness.entries);
  await restored.restore();
  const status = await restored.tool.execute("11", { op: "status" });
  assert.equal(status.details.state?.stage, "completed");
  assert.equal(status.details.state?.runId, started.details.state?.runId);

  const ledger = (await readFile(status.details.ledgerPath, "utf8"))
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line) as { event: string });
  assert.deepEqual(
    ledger.map((entry) => entry.event),
    [
      "run-start",
      "plan-approved",
      "chunk-recorded",
      "chunk-recorded",
      "pr-open",
      "review-recorded",
      "run-end",
    ],
  );
});

test("slash command routes arguments through the skill invocation", async () => {
  const harness = createHarness();
  await harness.command.handler("https://github.com/subhan-io/example/issues/42");
  assert.deepEqual(harness.sentMessages, [
    "/skill:ship-issue-omp https://github.com/subhan-io/example/issues/42",
  ]);
});
