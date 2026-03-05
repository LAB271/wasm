import { ResponseBuilder } from "@fermyon/spin-sdk";

export const handleRequest = async function (_request) {
  return new ResponseBuilder()
    .status(200)
    .header("content-type", "application/json")
    .body(
      JSON.stringify({
        message: "Hello World",
        timestamp: Date.now() / 1000.0,
      })
    )
    .build();
};
