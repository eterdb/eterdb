// Generate a Postgres schema + data load from the InvenTree demo dataset
// (inventree_data.json, the upstream Django dumpdata fixture). We don't run
// Django: for the core inventory models we derive a table from each model's
// scalar fields (FKs land as their integer ids) and load the REAL demo records.
// Realistic schema + realistic volume, which is what the EterDB e2e needs.
//
//   node test/inventree/gen-sql.mjs <inventree_data.json>  > load.sql
import fs from "node:fs";

const MODELS = [
  "part.partcategory", "part.part",
  "stock.stocklocation", "stock.stockitem", "stock.stockitemtracking",
  "company.company", "company.supplierpart",
  "order.purchaseorder", "order.purchaseorderlineitem",
  "order.salesorder", "order.salesorderlineitem",
];

const data = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const byModel = new Map();
for (const r of data) {
  if (!MODELS.includes(r.model)) continue;
  if (!byModel.has(r.model)) byModel.set(r.model, []);
  byModel.get(r.model).push(r);
}

const ident = (s) => '"' + String(s).replace(/"/g, '""') + '"';
const tableName = (m) => "public." + ident(m.replace(/\./g, "_"));
const isScalar = (v) => v === null || typeof v !== "object"; // skip M2M / nested

function inferType(vals) {
  let str = false, num = false, int = false, bool = false;
  for (const v of vals) {
    if (v === null || v === undefined) continue;
    const t = typeof v;
    if (t === "string") str = true;
    else if (t === "boolean") bool = true;
    else if (t === "number") (Number.isInteger(v) ? (int = true) : (num = true));
  }
  if (str) return "text";       // Django serializes Decimals/dates as strings
  if (num) return "numeric";
  if (int) return "bigint";
  if (bool) return "boolean";
  return "text";
}

function literal(v, type) {
  if (v === null || v === undefined || typeof v === "object") return "NULL";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return String(v);
  return "'" + String(v).replace(/'/g, "''") + "'";
}

let out = "BEGIN;\n";
for (const m of MODELS) {
  const rows = byModel.get(m) || [];
  if (!rows.length) continue;
  const keys = new Set();
  for (const r of rows) for (const k of Object.keys(r.fields)) if (isScalar(r.fields[k])) keys.add(k);
  const cols = [...keys];
  const types = Object.fromEntries(cols.map((c) => [c, inferType(rows.map((r) => r.fields[c]))]));

  out += `\nDROP TABLE IF EXISTS ${tableName(m)} CASCADE;\n`;
  out += `CREATE TABLE ${tableName(m)} (\n  id bigint PRIMARY KEY`;
  for (const c of cols) out += `,\n  ${ident(c)} ${types[c]}`;
  out += `\n);\n`;

  const collist = ["id", ...cols].map(ident).join(", ");
  const BATCH = 200;
  for (let i = 0; i < rows.length; i += BATCH) {
    const chunk = rows.slice(i, i + BATCH);
    out += `INSERT INTO ${tableName(m)} (${collist}) VALUES\n`;
    out += chunk.map((r) => {
      const vals = [String(r.pk)];
      for (const c of cols) vals.push(literal(r.fields[c], types[c]));
      return "  (" + vals.join(",") + ")";
    }).join(",\n") + ";\n";
  }
}
out += "COMMIT;\n";
process.stdout.write(out);
