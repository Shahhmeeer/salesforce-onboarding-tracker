// Builds data/demo-opportunities-close.csv (Id,StageName) from the Ids exported by
// `sf data export bulk` into data/demo-opportunities-ids.csv, so all 200 demo deals can be closed
// as won in one bulk update (spec 14.2). Both files hold org-specific Ids and are git-ignored.
//
// Usage: node scripts/build-close-csv.mjs
import { readFileSync, writeFileSync } from "node:fs";

const IDS_FILE = "data/demo-opportunities-ids.csv";
const CLOSE_FILE = "data/demo-opportunities-close.csv";
const WON_STAGE = "Closed Won";

const [header, ...rows] = readFileSync(IDS_FILE, "utf8")
  .split(/\r?\n/)
  .filter((line) => line.trim() !== "");
const idColumn = header
  .split(",")
  .findIndex((column) => column.replace(/"/g, "") === "Id");
if (idColumn === -1) {
  throw new Error(`${IDS_FILE} has no Id column`);
}

const ids = rows.map((row) => row.split(",")[idColumn].replace(/"/g, ""));
const lines = ["Id,StageName", ...ids.map((id) => `${id},${WON_STAGE}`)];
writeFileSync(CLOSE_FILE, lines.join("\n") + "\n");
console.log(`Wrote ${ids.length} rows to ${CLOSE_FILE}`);
