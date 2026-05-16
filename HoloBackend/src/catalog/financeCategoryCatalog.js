import { financeCategoryCatalog } from "./financeCategories.js";

export function getFinanceCategoryCatalog() {
  return financeCategoryCatalog;
}

export function flattenFinanceCategoryCatalog() {
  const rows = [];
  for (const type of ["expense", "income"]) {
    for (const parent of financeCategoryCatalog[type] ?? []) {
      for (const child of parent.children ?? []) {
        rows.push({
          type,
          primaryCategory: parent.name,
          subCategory: child.name,
          aliases: child.aliases ?? [],
          tags: child.tags ?? [],
        });
      }
    }
  }
  return rows;
}
