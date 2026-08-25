import { appendFile, mkdir } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const ENTRY_TYPE = "io.subhan.ship-issue-omp.state";
const LEDGER_PATH = join(
  process.env.XDG_STATE_HOME ?? join(homedir(), ".local", "state"),
  "ship-issue-omp",
  "ledger.jsonl",
);

const TIERS = ["light", "standard", "deep"] as const;
const STAGES = [
  "criteria-approved",
  "plan-approved",
  "implementing",
  "pr-open",
  "reviewing",
  "completed",
  "stopped",
  "split",
] as const;

type Tier = (typeof TIERS)[number];
type Stage = (typeof STAGES)[number];
type ChunkStatus = "passed" | "failed";
type FinishOutcome = "pr-open" | "stopped" | "split";

interface PlanState {
  summary: string;
  chunks: string[];
}

interface ChunkRecord {
  index: number;
  agentId?: string;
  status: ChunkStatus;
  summary: string;
  verification: string;
  updatedAt: string;
}

interface ReviewRecord {
  round: number;
  outcome: string;
  fixed: number;
  rejected: number;
  outstanding: number;
  behaviorChanged: boolean;
  updatedAt: string;
}

interface ShipRunState {
  version: 1;
  runId: string;
  task: string;
  repo: string;
  tier: Tier;
  criteria: string[];
  stage: Stage;
  startedAt: string;
  updatedAt: string;
  plan?: PlanState;
  chunks: ChunkRecord[];
  reviews: ReviewRecord[];
  prUrl?: string;
  tests?: string;
  outcome?: FinishOutcome;
  criteriaStatus?: string[];
  children?: string[];
  openItems?: string[];
}

interface BranchEntry {
  type?: string;
  customType?: string;
  data?: unknown;
}

interface SessionContextLike {
  sessionManager: {
    getBranch(): readonly BranchEntry[];
  };
}

function isTier(value: string): value is Tier {
  return (TIERS as readonly string[]).includes(value);
}

function isState(value: unknown): value is ShipRunState {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<ShipRunState>;
  return (
    candidate.version === 1 &&
    typeof candidate.runId === "string" &&
    typeof candidate.stage === "string" &&
    (STAGES as readonly string[]).includes(candidate.stage)
  );
}

function required(value: string | undefined, field: string): string {
  const normalized = value?.trim();
  if (!normalized) throw new Error(`ship_run: ${field} is required for this operation`);
  return normalized;
}

function requiredList(value: string[] | undefined, field: string): string[] {
  const normalized = value?.map((item) => item.trim()).filter(Boolean) ?? [];
  if (normalized.length === 0) {
    throw new Error(`ship_run: ${field} must contain at least one non-empty item`);
  }
  return normalized;
}

function renderState(state: ShipRunState | undefined): string {
  if (!state) return "No ship-issue-omp run is active in this session.";

  const lines = [
    `Run: ${state.runId}`,
    `Task: ${state.task}`,
    `Repository: ${state.repo}`,
    `Tier: ${state.tier}`,
    `Stage: ${state.stage}`,
    `Criteria: ${state.criteria.length}`,
    `Chunks: ${state.chunks.filter((chunk) => chunk.status === "passed").length}/${state.plan?.chunks.length ?? 0} passed`,
    `Reviews: ${state.reviews.length}`,
  ];
  if (state.prUrl) lines.push(`PR: ${state.prUrl}`);
  if (state.outcome) lines.push(`Outcome: ${state.outcome}`);
  lines.push(`Ledger: ${LEDGER_PATH}`);
  return lines.join("\n");
}

export default function shipIssueOmp(pi: ExtensionAPI) {
  const z = pi.zod;
  let state: ShipRunState | undefined;

  const restore = (ctx: SessionContextLike) => {
    state = undefined;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom" && entry.customType === ENTRY_TYPE && isState(entry.data)) {
        state = entry.data;
      }
    }
  };

  const persist = async (event: string, next: ShipRunState) => {
    await mkdir(dirname(LEDGER_PATH), { recursive: true });
    await appendFile(
      LEDGER_PATH,
      `${JSON.stringify({ event, at: next.updatedAt, ...next })}\n`,
      "utf8",
    );
    pi.appendEntry(ENTRY_TYPE, next);
    state = next;
  };

  pi.on("session_start", async (_event, ctx) => restore(ctx));
  pi.on("session_branch", async (_event, ctx) => restore(ctx));
  pi.on("session_tree", async (_event, ctx) => restore(ctx));

  pi.registerCommand("ship-issue-omp", {
    description: "Ship one GitHub issue or adhoc task with the native OMP workflow",
    handler: async (args) => {
      const task = args.trim();
      pi.sendUserMessage(`/skill:ship-issue-omp${task ? ` ${task}` : ""}`);
    },
  });

  pi.registerTool({
    name: "ship_run",
    label: "Ship Run",
    description:
      "Persist and validate the state of an active ship-issue-omp run. Use status for inspection and the other operations only at their named workflow gates.",
    loadMode: "discoverable",
    approval: "write",
    strict: true,
    parameters: z.object({
      op: z.string().describe(
        "Operation: start, approve_plan, record_chunk, record_pr, record_review, finish, or status",
      ),
      task: z.string().optional().describe("Issue URL/number or adhoc task summary"),
      repo: z.string().optional().describe("Repository as owner/name"),
      tier: z.string().optional().describe("Planning tier: light, standard, or deep"),
      criteria: z.array(z.string()).optional().describe("Human-approved acceptance criteria"),
      planSummary: z.string().optional().describe("Human-approved plan summary"),
      chunks: z.array(z.string()).optional().describe("One or two independently verifiable chunks"),
      index: z.number().optional().describe("One-based chunk index or review round"),
      agentId: z.string().optional().describe("OMP task agent id for a chunk"),
      status: z.string().optional().describe("Chunk status: passed or failed"),
      summary: z.string().optional().describe("Chunk or operation summary"),
      verification: z.string().optional().describe("Observed verification result"),
      prUrl: z.string().optional().describe("Created pull request URL"),
      tests: z.string().optional().describe("Full test and CI status"),
      reviewOutcome: z.string().optional().describe("Review result, including settled, silent, or failed"),
      fixed: z.number().optional().describe("Review findings fixed"),
      rejected: z.number().optional().describe("Review findings rejected with evidence"),
      outstanding: z.number().optional().describe("Review findings still open"),
      behaviorChanged: z.boolean().optional().describe("Whether review fixes changed behavior"),
      outcome: z.string().optional().describe("Finish outcome: pr-open, stopped, or split"),
      criteriaStatus: z.array(z.string()).optional().describe("One final status entry per criterion"),
      children: z.array(z.string()).optional().describe("Created child issue URLs or numbers for a split"),
      openItems: z.array(z.string()).optional().describe("Items left open at handoff or stop"),
    }),
    async execute(_id, params) {
      const op = params.op.trim();
      const now = new Date().toISOString();

      if (op === "status") {
        return {
          content: [{ type: "text", text: renderState(state) }],
          details: { state, ledgerPath: LEDGER_PATH },
        };
      }

      if (op === "start") {
        if (state && !["completed", "stopped", "split"].includes(state.stage)) {
          throw new Error(`ship_run: run ${state.runId} is still active at stage ${state.stage}`);
        }
        const tier = required(params.tier, "tier");
        if (!isTier(tier)) throw new Error(`ship_run: unknown tier ${tier}`);
        const next: ShipRunState = {
          version: 1,
          runId: randomUUID(),
          task: required(params.task, "task"),
          repo: required(params.repo, "repo"),
          tier,
          criteria: requiredList(params.criteria, "criteria"),
          stage: "criteria-approved",
          startedAt: now,
          updatedAt: now,
          chunks: [],
          reviews: [],
        };
        await persist("run-start", next);
        return {
          content: [{ type: "text", text: `Started ship run.\n${renderState(next)}` }],
          details: { state: next, ledgerPath: LEDGER_PATH },
        };
      }

      if (!state) throw new Error("ship_run: start a run before recording workflow state");
      if (["completed", "stopped", "split"].includes(state.stage)) {
        throw new Error(`ship_run: run ${state.runId} is terminal at stage ${state.stage}`);
      }

      if (op === "approve_plan") {
        if (state.stage !== "criteria-approved") {
          throw new Error(`ship_run: plan approval requires criteria-approved, found ${state.stage}`);
        }
        const chunks = requiredList(params.chunks, "chunks");
        if (chunks.length > 2) {
          throw new Error("ship_run: plans over two chunks must finish with outcome=split");
        }
        const next: ShipRunState = {
          ...state,
          stage: "plan-approved",
          updatedAt: now,
          plan: { summary: required(params.planSummary, "planSummary"), chunks },
        };
        await persist("plan-approved", next);
        return {
          content: [{ type: "text", text: `Recorded approved plan.\n${renderState(next)}` }],
          details: { state: next, ledgerPath: LEDGER_PATH },
        };
      }

      if (op === "record_chunk") {
        if (!state.plan || !["plan-approved", "implementing"].includes(state.stage)) {
          throw new Error(`ship_run: chunk recording requires an approved plan, found ${state.stage}`);
        }
        const index = Math.trunc(params.index ?? 0);
        if (index < 1 || index > state.plan.chunks.length) {
          throw new Error(`ship_run: chunk index must be between 1 and ${state.plan.chunks.length}`);
        }
        const status = required(params.status, "status");
        if (status !== "passed" && status !== "failed") {
          throw new Error(`ship_run: unknown chunk status ${status}`);
        }
        const record: ChunkRecord = {
          index,
          agentId: params.agentId?.trim() || undefined,
          status,
          summary: required(params.summary, "summary"),
          verification: required(params.verification, "verification"),
          updatedAt: now,
        };
        const chunks = [...state.chunks.filter((chunk) => chunk.index !== index), record].sort(
          (left, right) => left.index - right.index,
        );
        const next: ShipRunState = { ...state, stage: "implementing", updatedAt: now, chunks };
        await persist("chunk-recorded", next);
        return {
          content: [{ type: "text", text: `Recorded chunk ${index} as ${status}.\n${renderState(next)}` }],
          details: { state: next, ledgerPath: LEDGER_PATH },
        };
      }

      if (op === "record_pr") {
        if (!state.plan || !["plan-approved", "implementing"].includes(state.stage)) {
          throw new Error(`ship_run: PR recording requires implementation, found ${state.stage}`);
        }
        const passed = new Set(
          state.chunks.filter((chunk) => chunk.status === "passed").map((chunk) => chunk.index),
        );
        if (state.plan.chunks.some((_chunk, index) => !passed.has(index + 1))) {
          throw new Error("ship_run: every planned chunk must have a passing verification before PR creation");
        }
        const next: ShipRunState = {
          ...state,
          stage: "pr-open",
          updatedAt: now,
          prUrl: required(params.prUrl, "prUrl"),
          tests: required(params.tests, "tests"),
        };
        await persist("pr-open", next);
        return {
          content: [{ type: "text", text: `Recorded pull request.\n${renderState(next)}` }],
          details: { state: next, ledgerPath: LEDGER_PATH },
        };
      }

      if (op === "record_review") {
        if (!["pr-open", "reviewing"].includes(state.stage)) {
          throw new Error(`ship_run: review recording requires an open PR, found ${state.stage}`);
        }
        const round = Math.trunc(params.index ?? 0);
        if (round < 1 || round > 2) throw new Error("ship_run: review round must be 1 or 2");
        if (state.reviews.some((review) => review.round === round)) {
          throw new Error(`ship_run: review round ${round} is already recorded`);
        }
        if (round === 2 && !state.reviews.some((review) => review.round === 1)) {
          throw new Error("ship_run: review round 1 must be recorded before round 2");
        }
        const review: ReviewRecord = {
          round,
          outcome: required(params.reviewOutcome, "reviewOutcome"),
          fixed: Math.max(0, Math.trunc(params.fixed ?? 0)),
          rejected: Math.max(0, Math.trunc(params.rejected ?? 0)),
          outstanding: Math.max(0, Math.trunc(params.outstanding ?? 0)),
          behaviorChanged: params.behaviorChanged ?? false,
          updatedAt: now,
        };
        const next: ShipRunState = {
          ...state,
          stage: "reviewing",
          updatedAt: now,
          reviews: [...state.reviews, review],
        };
        await persist("review-recorded", next);
        return {
          content: [{ type: "text", text: `Recorded review round ${round}.\n${renderState(next)}` }],
          details: { state: next, ledgerPath: LEDGER_PATH },
        };
      }

      if (op === "finish") {
        const outcome = required(params.outcome, "outcome");
        if (outcome !== "pr-open" && outcome !== "stopped" && outcome !== "split") {
          throw new Error(`ship_run: unknown finish outcome ${outcome}`);
        }

        if (outcome === "pr-open") {
          if (!["pr-open", "reviewing"].includes(state.stage) || !state.prUrl) {
            throw new Error("ship_run: pr-open finish requires a recorded pull request");
          }
          if (state.reviews.length === 0) {
            throw new Error("ship_run: pr-open finish requires at least one recorded review round");
          }
          const criteriaStatus = requiredList(params.criteriaStatus, "criteriaStatus");
          if (criteriaStatus.length !== state.criteria.length) {
            throw new Error("ship_run: criteriaStatus must contain one entry per approved criterion");
          }
          const next: ShipRunState = {
            ...state,
            stage: "completed",
            updatedAt: now,
            outcome,
            criteriaStatus,
            openItems: params.openItems?.map((item) => item.trim()).filter(Boolean) ?? [],
          };
          await persist("run-end", next);
          return {
            content: [{ type: "text", text: `Completed ship run.\n${renderState(next)}` }],
            details: { state: next, ledgerPath: LEDGER_PATH },
          };
        }

        if (outcome === "split") {
          if (state.stage !== "criteria-approved") {
            throw new Error(`ship_run: split finish requires criteria-approved, found ${state.stage}`);
          }
          const children = requiredList(params.children, "children");
          if (children.length < 2) throw new Error("ship_run: split outcome requires at least two child issues");
          const next: ShipRunState = {
            ...state,
            stage: "split",
            updatedAt: now,
            outcome,
            children,
            openItems: params.openItems?.map((item) => item.trim()).filter(Boolean) ?? [],
          };
          await persist("run-end", next);
          return {
            content: [{ type: "text", text: `Split ship run into ${children.length} child issues.\n${renderState(next)}` }],
            details: { state: next, ledgerPath: LEDGER_PATH },
          };
        }

        const next: ShipRunState = {
          ...state,
          stage: "stopped",
          updatedAt: now,
          outcome,
          openItems: requiredList(params.openItems, "openItems"),
        };
        await persist("run-end", next);
        return {
          content: [{ type: "text", text: `Stopped ship run.\n${renderState(next)}` }],
          details: { state: next, ledgerPath: LEDGER_PATH },
        };
      }

      throw new Error(`ship_run: unknown operation ${op}`);
    },
  });
}
