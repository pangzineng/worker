#!/usr/bin/env node
import getTasks from "./getTasks";
import { RunnerOptions } from "./interfaces";
import { run, runOnce } from "./index";
import * as yargs from "yargs";
import { POLL_INTERVAL, CONCURRENT_JOBS } from "./config";

const argv = yargs
  .option("connection", {
    description:
      "Database connection string, defaults to the 'DATABASE_URL' envvar",
    alias: "c",
  })
  .string("connection")
  .option("schema", {
    description:
      "Name of existing database schema, will create one call 'graphile_worker' if not provided",
    alias: "s",
  })
  .string("schema")
  .option("once", {
    description: "Run until there are no runnable jobs left, then exit",
    alias: "1",
    default: false,
  })
  .boolean("once")
  .option("watch", {
    description:
      "[EXPERIMENTAL] Watch task files for changes, automatically reloading the task code without restarting worker",
    alias: "w",
    default: false,
  })
  .boolean("watch")
  .option("jobs", {
    description: "number of jobs to run concurrently",
    alias: "j",
    default: CONCURRENT_JOBS,
  })
  .option("poll-interval", {
    description:
      "how long to wait between polling for jobs in milliseconds (for jobs scheduled in the future/retries)",
    default: POLL_INTERVAL,
  })
  .number("poll-interval").argv;

const isInteger = (n: number): boolean => {
  return isFinite(n) && Math.round(n) === n;
};

async function main() {
  const DATABASE_URL = argv.connection || process.env.DATABASE_URL || undefined;
  const ONCE = argv.once;
  const WATCH = argv.watch;

  if (WATCH && ONCE) {
    throw new Error("Cannot specify both --watch and --once");
  }

  if (!DATABASE_URL) {
    throw new Error(
      "Please use `--connection` flag or set `DATABASE_URL` envvar to indicate the PostgreSQL connection string."
    );
  }
  const watchedTasks = await getTasks(`${process.cwd()}/tasks`, WATCH);

  const options: RunnerOptions = {
    concurrency: isInteger(argv.jobs) ? argv.jobs : CONCURRENT_JOBS,
    pollInterval: isInteger(argv["poll-interval"])
      ? argv["poll-interval"]
      : POLL_INTERVAL,
    connectionString: DATABASE_URL,
    schemaName: argv.schema || '',
    taskList: watchedTasks.tasks,
  };

  if (ONCE) {
    await runOnce(options);
  } else {
    const { promise } = await run(options);
    // Continue forever(ish)
    await promise;
  }
}

main().catch(e => {
  console.error(e); // eslint-disable-line no-console
  process.exit(1);
});
