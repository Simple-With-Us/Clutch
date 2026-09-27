import { expect, test } from "@playwright/test";

/**
 * Unauthenticated smoke checks for the Harness web UI server.
 *
 * The web UI is auth-walled: `/` answers 401 until the signed browser
 * cookie is minted (see `e2e/auth.setup.ts`).  That 401 still counts as
 * healthy — see `src/shared/http-up.ts`.
 */

test("server is up and auth-walled on /", async ({ request }) => {
  const response = await request.get("/");
  expect([401, 403]).toContain(response.status());
});
