// Standalone worker process for background jobs.
//
// The API server also runs these jobs inline by default. When you scale to
// more than one API replica, set WORKER_DISABLED=true on the API app and run
// this worker as its own single-replica service — otherwise N API replicas
// means N schedulers fighting over the same work.

import dotenv from "dotenv";
dotenv.config();

import { validateProdEnv } from "./config/env";
import { startExpireStaleTasksJob, stopExpireStaleTasksJob } from "./jobs/expireStaleTasks";

validateProdEnv();

console.log("[worker] starting Callboard background worker");
startExpireStaleTasksJob();

function shutdown(signal: string): void {
  console.log(`[worker] received ${signal}, stopping jobs`);
  stopExpireStaleTasksJob();
  process.exit(0);
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
