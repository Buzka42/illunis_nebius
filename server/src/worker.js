// Cloudflare entry (wrangler.jsonc "main"). Only this file imports the runtime
// module "cloudflare:workers", so src/index.js and the tests run under plain node.
import { DurableObject } from "cloudflare:workers";
import worker from "./index.js";
import { DeviceQuotaCounter } from "./quota-store.js";
import { AssistantState } from "./assistants/store.js";

// Binding QUOTA_DO, one object per device id. Counters in this.ctx.storage.
export class QuotaCounter extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.counter = new DeviceQuotaCounter(ctx.storage);
  }
  // RPC from DurableObjectQuotaStore. Returns the count after this hit.
  async hit(key, day) {
    return this.counter.hit(key, day);
  }
}

// Binding ASSISTANT_DO, one object per device id: the Hermes inbox (with its nonce log) and pending
// actions awaiting the spoken yes. Body in src/assistants/store.js.
export class AssistantInbox extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.state = new AssistantState(ctx.storage);
  }
  async push(item, nowS) {
    return this.state.push(item, nowS);
  }
  async take(limit) {
    return this.state.take(limit);
  }
  async propose(actionId, action, hash, nowS) {
    return this.state.propose(actionId, action, hash, nowS);
  }
  async claim(actionId, nowS) {
    return this.state.claim(actionId, nowS);
  }
}

export default worker;
