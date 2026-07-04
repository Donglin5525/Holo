import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

test("deploy.sh uses production-safe rebuild and verification contract", async () => {
  const script = await readFile("deploy/deploy.sh", "utf8");

  assert.match(script, /DOCKER_BUILDKIT=0 docker compose build holo-backend/);
  assert.match(script, /docker compose up -d --force-recreate holo-backend/);
  assert.match(script, /PUBLIC_BASE_URL="\$\{PUBLIC_BASE_URL:-https:\/\/api\.holoapp\.cn\}"/);
  assert.match(script, /\$PUBLIC_BASE_URL\/v1\/health/);
  assert.match(script, /\$PUBLIC_BASE_URL\/v1\/prompts\/meta/);
  assert.doesNotMatch(script, /API 端点:\s+http:\/\/<ECS公网IP>/);
});
