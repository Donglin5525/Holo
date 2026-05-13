import "dotenv/config";
import { serve } from "@hono/node-server";

const port = Number(process.env.PORT ?? 8787);
const { createApp } = await import("./app.js");
const app = createApp();

serve(
  {
    fetch: app.fetch,
    port,
  },
  (info) => {
    console.log(`Holo AI Gateway listening on http://localhost:${info.port}`);
  },
);
