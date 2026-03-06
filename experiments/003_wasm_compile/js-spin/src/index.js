import { AutoRouter } from "itty-router";

const router = AutoRouter();

router.get("/", () =>
  new Response(
    JSON.stringify({
      message: "Hello World",
      timestamp: Date.now() / 1000.0,
    }),
    { headers: { "content-type": "application/json" } }
  )
);

addEventListener("fetch", (event) => {
  event.respondWith(router.fetch(event.request));
});
