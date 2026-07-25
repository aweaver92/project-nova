import {
  ConversationMemory,
  ConversationTurn,
  Tool,
  ToolCallRequest,
  ToolCallResult,
} from "./types";

/** Defaults match Nova `FileConversationMemory` / `InMemoryConversationMemory`. */
const MAX_TURNS = 500;
const SUMMARY_TURNS = 48;

export class InMemoryConversationMemory implements ConversationMemory {
  private turns: ConversationTurn[] = [];

  async append(turn: ConversationTurn): Promise<void> {
    this.turns.push(turn);
    if (this.turns.length > MAX_TURNS) this.turns.splice(0, this.turns.length - MAX_TURNS);
  }

  async recent(limit: number): Promise<ConversationTurn[]> {
    return this.turns.slice(-limit);
  }

  async summary(): Promise<string> {
    return this.turns
      .slice(-SUMMARY_TURNS)
      .map((t) => `${t.role}: ${t.text}`)
      .join("\n");
  }

  async clear(): Promise<void> {
    this.turns = [];
  }
}

export class ToolRouter {
  private tools = new Map<string, Tool>();
  confirmationHandler?: (req: ToolCallRequest) => Promise<boolean>;

  constructor(tools: Tool[] = []) {
    for (const t of tools) this.tools.set(t.name, t);
  }

  register(tool: Tool): void {
    this.tools.set(tool.name, tool);
  }

  allowlist(): string[] {
    return [...this.tools.keys()].sort();
  }

  async dispatch(request: ToolCallRequest): Promise<ToolCallResult> {
    const tool = this.tools.get(request.name);
    if (!tool) {
      return { id: request.id, ok: false, payloadJSON: '{"error":"unknown_tool"}' };
    }
    if (tool.requiresConfirmation) {
      const allowed = this.confirmationHandler
        ? await this.confirmationHandler(request)
        : false;
      if (!allowed) {
        return { id: request.id, ok: false, payloadJSON: '{"error":"user_denied"}' };
      }
    }
    try {
      const payloadJSON = await tool.invoke(request.argumentsJSON);
      return { id: request.id, ok: true, payloadJSON };
    } catch (e) {
      return {
        id: request.id,
        ok: false,
        payloadJSON: JSON.stringify({ error: String(e) }),
      };
    }
  }
}

export const weatherTool: Tool = {
  name: "weather",
  description: "Get a short weather summary for a city.",
  requiresConfirmation: false,
  async invoke(argumentsJSON: string) {
    const { city } = JSON.parse(argumentsJSON) as { city: string };
    return JSON.stringify({
      city,
      summary: "Weather lookup stub — wire Open-Meteo/WeatherKit on iOS port",
    });
  },
};

export const remindersTool: Tool = {
  name: "reminders",
  description: "Create a local reminder (requires confirmation).",
  requiresConfirmation: true,
  async invoke(argumentsJSON: string) {
    const { title } = JSON.parse(argumentsJSON) as { title: string };
    return JSON.stringify({ ok: true, title });
  },
};
