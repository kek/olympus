// One request per process. Stdout is reserved for one bounded protocol reply.
import { run } from "./session.mjs";

let input = Buffer.alloc(0);
let started = false;
let timer;

process.stdin.on("end", () => process.exit(1)); // Port owner died or cancelled.
process.on("SIGTERM", () => process.exit(1));
process.stdout.on("error", () => process.exit(1));

process.stdin.on("data", async (chunk) => {
  if (started) return process.exit(1);
  if (input.length + chunk.length > 4_194_304) return process.exit(1);
  input = Buffer.concat([input, chunk]);
  const end = input.indexOf(10);
  if (end < 0) return;
  if (end !== input.length - 1) return process.exit(1);
  started = true;
  try {
    const envelope = JSON.parse(input.subarray(0, end).toString("utf8"));
    const timeout = envelope.request?.timeout_ms;
    if (!Number.isInteger(timeout) || timeout < 1 || timeout > 120_000) return process.exit(1);
    timer = setTimeout(() => process.exit(1), timeout);
    const reply = await run(envelope);
    clearTimeout(timer);
    process.stdout.write(JSON.stringify(reply) + "\n", () => process.exit(0));
  } catch {
    process.exit(1);
  }
});
